//! Loading database results into pages without blocking the UI.

use crate::db::{Db, Task};
use crate::model::MediaItem;
use crate::repo::{self, ItemQuery};
use std::collections::HashMap;

/// A value loaded in the background for a key. While a new key loads, the
/// previous value stays visible, so lists do not flicker.
pub struct Cached<K, T> {
    key: Option<K>,
    value: Option<T>,
    pending: Option<(K, Task<T>)>,
    pub error: Option<String>,
}

impl<K, T> Default for Cached<K, T> {
    fn default() -> Self {
        Self { key: None, value: None, pending: None, error: None }
    }
}

impl<K: PartialEq + Clone, T> Cached<K, T> {
    /// Returns the value for `key` (or the previous one while it loads).
    pub fn get(&mut self, key: &K, load: impl FnOnce() -> Task<T>) -> Option<&T> {
        let current = self.key.as_ref() == Some(key);
        let loading = self.pending.as_ref().is_some_and(|(k, _)| k == key);
        if !current && !loading {
            self.pending = Some((key.clone(), load()));
        }
        if let Some((k, t)) = &self.pending
            && let Some(r) = t.take()
        {
            match r {
                Ok(v) => {
                    self.value = Some(v);
                    self.error = None;
                }
                Err(e) => self.error = Some(e),
            }
            self.key = Some(k.clone());
            self.pending = None;
        }
        self.value.as_ref()
    }

    pub fn is_loading(&self) -> bool {
        self.pending.is_some()
    }

}

const PAGE: i64 = 100;

/// A list of items read page by page as it scrolls (lists can hold 100k).
#[derive(Default)]
pub struct Paged {
    key: Option<(ItemQuery, u64)>,
    pub total: Option<i64>,
    count_task: Option<Task<i64>>,
    pages: HashMap<i64, Vec<MediaItem>>,
    loading: HashMap<i64, Task<Vec<MediaItem>>>,
}

impl Paged {
    /// Resets when the query or the data version changes.
    pub fn sync(&mut self, db: &Db, q: &ItemQuery, version: u64) {
        let key = (q.clone(), version);
        if self.key.as_ref() != Some(&key) {
            let changed_query = self.key.as_ref().is_none_or(|(old, _)| old != q);
            self.key = Some(key);
            let q2 = q.clone();
            self.count_task = Some(db.read(move |c| repo::count_items(c, &q2)));
            self.loading.clear();
            if changed_query {
                self.pages.clear();
                self.total = None;
            } else {
                // Same list, new data (e.g. a favorite toggled): reload the
                // visible pages but keep showing the old rows meanwhile.
                let pages: Vec<i64> = self.pages.keys().copied().collect();
                for p in pages {
                    self.load_page(db, p);
                }
            }
        }
        if let Some(t) = &self.count_task
            && let Some(r) = t.take()
        {
            self.total = Some(r.unwrap_or(0));
            self.count_task = None;
        }
        let done: Vec<i64> = self.loading.iter().filter(|(_, t)| t.is_done()).map(|(p, _)| *p).collect();
        for p in done {
            if let Some(Ok(rows)) = self.loading.remove(&p).and_then(|t| t.take()) {
                self.pages.insert(p, rows);
            }
        }
    }

    fn load_page(&mut self, db: &Db, page: i64) {
        let Some((q, _)) = &self.key else { return };
        let q = q.clone();
        self.loading.insert(page, db.read(move |c| repo::items(c, &q, page * PAGE, PAGE)));
    }

    /// The item at `index`, loading its page if needed.
    pub fn get(&mut self, db: &Db, index: i64) -> Option<&MediaItem> {
        let page = index / PAGE;
        if !self.pages.contains_key(&page) && !self.loading.contains_key(&page) {
            self.load_page(db, page);
        }
        self.pages.get(&page)?.get((index % PAGE) as usize)
    }

    pub fn len(&self) -> i64 {
        self.total.unwrap_or(0)
    }

    pub fn query(&self) -> Option<&ItemQuery> {
        self.key.as_ref().map(|(q, _)| q)
    }

    /// Drops pages far from the visible range to bound memory.
    pub fn trim(&mut self, first_visible: i64) {
        let keep = first_visible / PAGE;
        self.pages.retain(|p, _| (p - keep).abs() <= 5);
    }
}
