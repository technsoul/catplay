//! Every SQL query. Functions take a connection and run on a database worker
//! (see [`crate::db::Db::read`] / [`crate::db::Db::write`]).

use crate::db::{self, open_epg};
use crate::model::*;
use crate::settings::Settings;
use rusqlite::types::Value;
use rusqlite::{Connection, OptionalExtension, Row, params, params_from_iter};
use std::collections::HashMap;
use std::path::Path;

pub fn now_secs() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_or(0, |d| d.as_secs() as i64)
}

// ---- settings ----------------------------------------------------------------

pub fn load_settings(c: &Connection) -> rusqlite::Result<Settings> {
    let v: Option<String> =
        c.query_row("SELECT value FROM settings WHERE key='app'", [], |r| r.get(0)).optional()?;
    Ok(Settings::decode(v.as_deref()))
}

pub fn save_settings(c: &Connection, s: &Settings) -> rusqlite::Result<()> {
    c.execute(
        "INSERT INTO settings (key, value) VALUES ('app', ?1) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
        [s.encode()],
    )?;
    Ok(())
}

// ---- sources -----------------------------------------------------------------

fn source_row(r: &Row) -> rusqlite::Result<Source> {
    Ok(Source {
        id: r.get("id")?,
        name: r.get("name")?,
        kind: SourceType::parse(&r.get::<_, String>("type")?),
        url: r.get("url")?,
        username: r.get("username")?,
        epg_url: r.get("epg_url")?,
        user_agent: r.get("user_agent")?,
        last_refresh: r.get("last_refresh")?,
        last_epg: r.get("last_epg")?,
        status: r.get("status")?,
        error: r.get("error")?,
        live_count: r.get("live_count")?,
        movie_count: r.get("movie_count")?,
        series_count: r.get("series_count")?,
        expires_at: r.get("expires_at")?,
        max_connections: r.get("max_connections")?,
    })
}

pub fn sources(c: &Connection) -> rusqlite::Result<Vec<Source>> {
    c.prepare_cached("SELECT * FROM sources ORDER BY id")?.query_map([], source_row)?.collect()
}

pub fn source(c: &Connection, id: i64) -> rusqlite::Result<Option<Source>> {
    c.query_row("SELECT * FROM sources WHERE id=?1", [id], source_row).optional()
}

fn blank(s: Option<&str>) -> Option<String> {
    s.map(str::trim).filter(|s| !s.is_empty()).map(String::from)
}

/// Fields the user edits on a playlist.
#[derive(Debug, Clone, Default)]
pub struct SourceForm {
    pub name: String,
    pub url: String,
    pub username: Option<String>,
    pub epg_url: Option<String>,
    pub user_agent: Option<String>,
}

pub fn add_source(c: &Connection, kind: SourceType, f: &SourceForm) -> rusqlite::Result<i64> {
    c.execute(
        "INSERT INTO sources (name, type, url, username, epg_url, user_agent, created_at) VALUES (?1,?2,?3,?4,?5,?6,?7)",
        params![
            f.name.trim(),
            kind.id(),
            f.url.trim(),
            blank(f.username.as_deref()),
            blank(f.epg_url.as_deref()),
            blank(f.user_agent.as_deref()),
            now_secs()
        ],
    )?;
    Ok(c.last_insert_rowid())
}

pub fn update_source(c: &Connection, id: i64, f: &SourceForm) -> rusqlite::Result<()> {
    c.execute(
        "UPDATE sources SET name=?1, url=?2, username=?3, epg_url=?4, user_agent=?5 WHERE id=?6",
        params![
            f.name.trim(),
            f.url.trim(),
            blank(f.username.as_deref()),
            blank(f.epg_url.as_deref()),
            blank(f.user_agent.as_deref()),
            id
        ],
    )?;
    Ok(())
}

pub fn delete_source(c: &Connection, id: i64) -> rusqlite::Result<()> {
    // External-content FTS: remove the rows from the index first.
    c.execute(
        "INSERT INTO items_fts(items_fts, rowid, name) SELECT 'delete', id, name FROM items WHERE source_id=?1",
        [id],
    )?;
    c.execute("DELETE FROM sources WHERE id=?1", [id])?;
    Ok(())
}

// ---- categories ----------------------------------------------------------------

pub fn categories(c: &Connection, source_id: i64, kind: ItemKind) -> rusqlite::Result<Vec<Category>> {
    c.prepare_cached("SELECT id, name, item_count FROM categories WHERE source_id=?1 AND kind=?2 ORDER BY sort")?
        .query_map(params![source_id, kind.index()], |r| {
            Ok(Category { id: r.get(0)?, name: r.get(1)?, item_count: r.get(2)? })
        })?
        .collect()
}

// ---- items -----------------------------------------------------------------------

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum ItemSort {
    #[default]
    Playlist,
    Name,
    Added,
    Rating,
}

impl ItemSort {
    pub const ALL: [ItemSort; 4] = [Self::Playlist, Self::Name, Self::Added, Self::Rating];

    pub fn label(self) -> &'static str {
        match self {
            Self::Playlist => "Playlist order",
            Self::Name => "Name",
            Self::Added => "Recently added",
            Self::Rating => "Rating",
        }
    }

    fn order(self) -> &'static str {
        match self {
            Self::Playlist => "i.sort",
            Self::Name => "i.name COLLATE NOCASE",
            Self::Added => "i.added_at DESC NULLS LAST, i.sort",
            Self::Rating => "i.rating DESC NULLS LAST, i.sort",
        }
    }
}

/// Which items a list shows.
#[derive(Debug, Clone, PartialEq)]
pub struct ItemQuery {
    pub kind: ItemKind,
    pub source_id: Option<i64>,
    /// None = all categories.
    pub category_id: Option<i64>,
    pub favorites_only: bool,
    pub sort: ItemSort,
    /// Name filter; every word is a prefix match.
    pub text: String,
}

impl ItemQuery {
    pub fn new(kind: ItemKind, source_id: i64) -> Self {
        Self {
            kind,
            source_id: Some(source_id),
            category_id: None,
            favorites_only: false,
            sort: ItemSort::Playlist,
            text: String::new(),
        }
    }
}

const ITEM_COLS: &str = "i.id, i.source_id, i.kind, i.category_id, i.key, i.name, i.logo, i.url, \
    i.epg_id, i.num, i.ext_id, i.container, i.rating, i.year, i.catchup_days, i.headers";

fn item_row(r: &Row) -> rusqlite::Result<MediaItem> {
    Ok(MediaItem {
        id: r.get(0)?,
        source_id: r.get(1)?,
        kind: ItemKind::from_i64(r.get(2)?),
        category_id: r.get(3)?,
        key: r.get(4)?,
        name: r.get(5)?,
        logo: r.get(6)?,
        url: r.get(7)?,
        epg_id: r.get(8)?,
        number: r.get(9)?,
        ext_id: r.get(10)?,
        container: r.get(11)?,
        rating: r.get(12)?,
        year: r.get(13)?,
        catchup_days: r.get(14)?,
        headers: decode_headers(r.get::<_, Option<String>>(15)?.as_deref()),
        favorite: r.get::<_, Option<i64>>(16)?.unwrap_or(0) == 1,
    })
}

/// FTS5 query where each word is a prefix match; None when there are no words.
pub fn fts_match(text: &str) -> Option<String> {
    let tokens: Vec<String> = text
        .to_lowercase()
        .split(|ch: char| !ch.is_alphanumeric())
        .filter(|t| !t.is_empty())
        .map(|t| format!("\"{}\"*", t.replace('"', "")))
        .collect();
    (!tokens.is_empty()).then(|| tokens.join(" "))
}

fn where_clause(q: &ItemQuery) -> (String, Vec<Value>) {
    let mut w = vec!["i.kind=?".to_string()];
    let mut p: Vec<Value> = vec![q.kind.index().into()];
    if let Some(s) = q.source_id {
        w.push("i.source_id=?".into());
        p.push(s.into());
    }
    if let Some(cat) = q.category_id {
        w.push("i.category_id=?".into());
        p.push(cat.into());
    }
    if q.favorites_only {
        w.push("f.key IS NOT NULL".into());
    }
    if let Some(m) = fts_match(&q.text) {
        w.push("i.id IN (SELECT rowid FROM items_fts WHERE items_fts MATCH ?)".into());
        p.push(m.into());
    }
    (w.join(" AND "), p)
}

pub fn count_items(c: &Connection, q: &ItemQuery) -> rusqlite::Result<i64> {
    let (w, p) = where_clause(q);
    let join = if q.favorites_only { "JOIN favorites f ON f.source_id=i.source_id AND f.key=i.key" } else { "" };
    c.prepare_cached(&format!("SELECT COUNT(*) FROM items i {join} WHERE {w}"))?
        .query_row(params_from_iter(p), |r| r.get(0))
}

pub fn items(c: &Connection, q: &ItemQuery, offset: i64, limit: i64) -> rusqlite::Result<Vec<MediaItem>> {
    let (w, mut p) = where_clause(q);
    let join = if q.favorites_only { "JOIN" } else { "LEFT JOIN" };
    p.push(limit.into());
    p.push(offset.into());
    c.prepare_cached(&format!(
        "SELECT {ITEM_COLS}, (f.key IS NOT NULL) fav FROM items i \
         {join} favorites f ON f.source_id=i.source_id AND f.key=i.key \
         WHERE {w} ORDER BY {} LIMIT ? OFFSET ?",
        q.sort.order()
    ))?
    .query_map(params_from_iter(p), item_row)?
    .collect()
}

pub fn item_by_key(c: &Connection, source_id: i64, key: &str) -> rusqlite::Result<Option<MediaItem>> {
    c.query_row(
        &format!(
            "SELECT {ITEM_COLS}, (f.key IS NOT NULL) fav FROM items i \
             LEFT JOIN favorites f ON f.source_id=i.source_id AND f.key=i.key \
             WHERE i.source_id=?1 AND i.key=?2 LIMIT 1"
        ),
        params![source_id, key],
        item_row,
    )
    .optional()
}

/// Item at `index` of a list, wrapping around (channel zapping). Returns the
/// item and its wrapped index.
pub fn item_at(c: &Connection, q: &ItemQuery, index: i64) -> rusqlite::Result<Option<(MediaItem, i64)>> {
    let total = count_items(c, q)?;
    if total == 0 {
        return Ok(None);
    }
    let i = index.rem_euclid(total);
    Ok(items(c, q, i, 1)?.into_iter().next().map(|it| (it, i)))
}

/// Full-text search; every word is a prefix match.
pub fn search(c: &Connection, text: &str, kind: Option<ItemKind>, source_id: Option<i64>, limit: i64) -> rusqlite::Result<Vec<MediaItem>> {
    let Some(m) = fts_match(text) else { return Ok(vec![]) };
    let mut w = vec!["items_fts MATCH ?".to_string()];
    let mut p: Vec<Value> = vec![m.into()];
    if let Some(k) = kind {
        w.push("i.kind=?".into());
        p.push(k.index().into());
    }
    if let Some(s) = source_id {
        w.push("i.source_id=?".into());
        p.push(s.into());
    }
    p.push(limit.into());
    c.prepare_cached(&format!(
        "SELECT {ITEM_COLS}, (f.key IS NOT NULL) fav FROM items_fts \
         JOIN items i ON i.id = items_fts.rowid \
         LEFT JOIN favorites f ON f.source_id=i.source_id AND f.key=i.key \
         WHERE {} ORDER BY rank LIMIT ?",
        w.join(" AND ")
    ))?
    .query_map(params_from_iter(p), item_row)?
    .collect()
}

// ---- favorites -----------------------------------------------------------------

/// Returns whether the item is now a favorite.
pub fn toggle_favorite(c: &Connection, source_id: i64, key: &str, kind: ItemKind) -> rusqlite::Result<bool> {
    let removed = c.execute("DELETE FROM favorites WHERE source_id=?1 AND key=?2", params![source_id, key])?;
    if removed > 0 {
        return Ok(false);
    }
    c.execute(
        "INSERT INTO favorites (source_id, key, kind, added_at) VALUES (?1,?2,?3,?4)",
        params![source_id, key, kind.index(), now_secs()],
    )?;
    Ok(true)
}

// ---- history -------------------------------------------------------------------

pub fn save_progress(c: &Connection, p: &Playable, position_ms: i64, duration_ms: i64) -> rusqlite::Result<()> {
    let name = match &p.subtitle {
        Some(s) => format!("{s} · {}", p.title),
        None => p.title.clone(),
    };
    c.execute(
        "INSERT INTO history (source_id, key, kind, name, logo, url, position_ms, duration_ms, updated_at) \
         VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9) \
         ON CONFLICT(source_id, key) DO UPDATE SET position_ms=excluded.position_ms, \
         duration_ms=excluded.duration_ms, updated_at=excluded.updated_at, url=excluded.url, \
         name=excluded.name, logo=excluded.logo",
        params![p.source_id, p.key, p.kind.index(), name, p.logo, p.url, position_ms, duration_ms, now_secs()],
    )?;
    Ok(())
}

/// Where to resume, unless it is near the start or past the credits.
pub fn resume_position(c: &Connection, source_id: i64, key: &str) -> rusqlite::Result<Option<i64>> {
    let r: Option<(i64, i64)> = c
        .query_row(
            "SELECT position_ms, duration_ms FROM history WHERE source_id=?1 AND key=?2",
            params![source_id, key],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )
        .optional()?;
    Ok(r.and_then(|(pos, dur)| {
        (pos >= 30_000 && !(dur > 0 && pos as f64 > dur as f64 * 0.95)).then_some(pos)
    }))
}

fn history_row(r: &Row) -> rusqlite::Result<HistoryEntry> {
    Ok(HistoryEntry {
        source_id: r.get("source_id")?,
        key: r.get("key")?,
        kind: ItemKind::from_i64(r.get("kind")?),
        name: r.get("name")?,
        logo: r.get("logo")?,
        url: r.get("url")?,
        position_ms: r.get("position_ms")?,
        duration_ms: r.get("duration_ms")?,
    })
}

pub fn continue_watching(c: &Connection, limit: i64) -> rusqlite::Result<Vec<HistoryEntry>> {
    c.prepare_cached(
        "SELECT * FROM history WHERE kind<>0 AND position_ms > 30000 \
         AND (duration_ms = 0 OR position_ms < duration_ms * 0.95) \
         ORDER BY updated_at DESC LIMIT ?1",
    )?
    .query_map([limit], history_row)?
    .collect()
}

pub fn recent_channels(c: &Connection, limit: i64) -> rusqlite::Result<Vec<HistoryEntry>> {
    c.prepare_cached("SELECT * FROM history WHERE kind=0 ORDER BY updated_at DESC LIMIT ?1")?
        .query_map([limit], history_row)?
        .collect()
}

pub fn remove_history(c: &Connection, source_id: i64, key: &str) -> rusqlite::Result<()> {
    c.execute("DELETE FROM history WHERE source_id=?1 AND key=?2", params![source_id, key])?;
    Ok(())
}

pub fn clear_history(c: &Connection) -> rusqlite::Result<()> {
    c.execute("DELETE FROM history", [])?;
    Ok(())
}

// ---- TV guide ------------------------------------------------------------------

/// The guide file of a source, if it has one.
fn epg_file(c: &Connection, epg_dir: &Path, source_id: i64) -> rusqlite::Result<Option<std::path::PathBuf>> {
    let gen_: Option<i64> =
        c.query_row("SELECT epg_gen FROM sources WHERE id=?1", [source_id], |r| r.get(0)).optional()?;
    Ok(gen_
        .filter(|g| *g > 0)
        .map(|g| epg_dir.join(db::epg_file_name(source_id, g)))
        .filter(|p| p.exists()))
}

/// Programmes overlapping [from, to) for many channels, grouped by channel.
pub fn guide_range(
    c: &Connection,
    epg_dir: &Path,
    source_id: i64,
    epg_ids: &[String],
    from: i64,
    to: i64,
    max_per_channel: Option<usize>,
) -> rusqlite::Result<HashMap<String, Vec<Programme>>> {
    let mut out: HashMap<String, Vec<Programme>> = HashMap::new();
    let mut ids: Vec<&String> = epg_ids.iter().collect();
    ids.sort();
    ids.dedup();
    if ids.is_empty() {
        return Ok(out);
    }
    let Some(file) = epg_file(c, epg_dir, source_id)? else { return Ok(out) };
    let g = open_epg(&file)?;
    for chunk in ids.chunks(400) {
        let marks = vec!["?"; chunk.len()].join(",");
        let mut p: Vec<Value> = chunk.iter().map(|s| Value::from((*s).clone())).collect();
        // `start > from - 1 day` lets the (channel, start) index bound the scan.
        p.extend([Value::from(from - 86_400), Value::from(to), Value::from(from)]);
        let mut st = g.prepare(&format!(
            "SELECT channel, start, stop, title, descr, category FROM programmes \
             WHERE channel IN ({marks}) AND start > ? AND start < ? AND stop > ? ORDER BY channel, start"
        ))?;
        let rows = st.query_map(params_from_iter(p), |r| {
            Ok(Programme {
                channel: r.get(0)?,
                start: r.get(1)?,
                stop: r.get(2)?,
                title: r.get(3)?,
                description: r.get(4)?,
                category: r.get(5)?,
            })
        })?;
        for p in rows {
            let p = p?;
            let list = out.entry(p.channel.clone()).or_default();
            if max_per_channel.is_none_or(|m| list.len() < m) {
                list.push(p);
            }
        }
    }
    Ok(out)
}

/// Current and next programme per channel.
pub fn now_next(c: &Connection, epg_dir: &Path, source_id: i64, epg_ids: &[String], now: i64) -> rusqlite::Result<HashMap<String, Vec<Programme>>> {
    guide_range(c, epg_dir, source_id, epg_ids, now, now + 8 * 3600, Some(2))
}

/// Deletes guide files that are no longer current (old generations,
/// interrupted imports, removed playlists).
pub fn cleanup_epg_files(c: &Connection, epg_dir: &Path) -> rusqlite::Result<()> {
    let gens: HashMap<i64, i64> = c
        .prepare("SELECT id, epg_gen FROM sources")?
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?)))?
        .collect::<rusqlite::Result<_>>()?;
    let Ok(dir) = std::fs::read_dir(epg_dir) else { return Ok(()) };
    for e in dir.flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        let Some((sid, g)) = db::parse_epg_file_name(&name) else { continue };
        if gens.get(&sid) != Some(&g) {
            // May still be open by an import; retried next time.
            let _ = std::fs::remove_file(e.path());
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn db() -> Connection {
        let c = Connection::open_in_memory().unwrap();
        db::migrate(&c).unwrap();
        let id = add_source(&c, SourceType::M3uUrl, &SourceForm { name: "A".into(), url: "http://x".into(), ..Default::default() }).unwrap();
        for (i, name) in ["BBC One HD", "BBC Two", "CNN", "قناة الجزيرة"].iter().enumerate() {
            c.execute(
                "INSERT INTO items (source_id,kind,key,name,sort,url) VALUES (?1,0,?2,?3,?4,'u')",
                params![id, format!("k{i}"), name, i as i64],
            )
            .unwrap();
        }
        c.execute_batch("INSERT INTO items_fts(items_fts) VALUES('rebuild');").unwrap();
        c
    }

    #[test]
    fn fts_query_is_prefix_per_word() {
        assert_eq!(fts_match("bbc  On").as_deref(), Some("\"bbc\"* \"on\"*"));
        assert_eq!(fts_match(" - "), None);
    }

    #[test]
    fn lists_search_and_favorites() {
        let c = db();
        let mut q = ItemQuery::new(ItemKind::Live, 1);
        assert_eq!(count_items(&c, &q).unwrap(), 4);
        assert_eq!(search(&c, "الجز", None, None, 10).unwrap()[0].name, "قناة الجزيرة");
        q.text = "bbc".into();
        assert_eq!(items(&c, &q, 0, 10).unwrap().len(), 2);
        assert_eq!(search(&c, "cn", None, None, 10).unwrap()[0].name, "CNN");

        assert!(toggle_favorite(&c, 1, "k2", ItemKind::Live).unwrap());
        let favs = ItemQuery { favorites_only: true, ..ItemQuery::new(ItemKind::Live, 1) };
        let list = items(&c, &favs, 0, 10).unwrap();
        assert_eq!(list.len(), 1);
        assert!(list[0].favorite);
        assert!(!toggle_favorite(&c, 1, "k2", ItemKind::Live).unwrap());

        let all = ItemQuery::new(ItemKind::Live, 1);
        assert_eq!(item_at(&c, &all, -1).unwrap().unwrap().1, 3);
    }

    #[test]
    fn resume_rules() {
        let c = db();
        let p = Playable {
            source_id: 1,
            key: "m".into(),
            kind: ItemKind::Movie,
            title: "Film".into(),
            subtitle: None,
            url: "u".into(),
            logo: None,
            headers: Default::default(),
            epg_id: None,
            catchup_days: None,
            resume_ms: None,
        };
        save_progress(&c, &p, 10_000, 100_000).unwrap();
        assert_eq!(resume_position(&c, 1, "m").unwrap(), None);
        save_progress(&c, &p, 50_000, 100_000).unwrap();
        assert_eq!(resume_position(&c, 1, "m").unwrap(), Some(50_000));
        assert_eq!(continue_watching(&c, 10).unwrap().len(), 1);
        save_progress(&c, &p, 99_000, 100_000).unwrap();
        assert_eq!(resume_position(&c, 1, "m").unwrap(), None);
    }
}
