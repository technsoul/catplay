//! Channel logos and posters: downloaded on worker threads, cached on disk,
//! shrunk to display size and kept as a bounded set of GPU textures.

use eframe::egui::{self, ColorImage, TextureHandle, TextureOptions};
use parking_lot::{Condvar, Mutex};
use std::collections::{HashMap, HashSet};
use std::io::Read;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

/// Longest side images are scaled down to.
const MAX_SIDE: u32 = 360;
/// Textures kept before the least recently used ones are dropped.
const MAX_TEXTURES: usize = 700;
/// Requests beyond this are forgotten (they were scrolled past).
const MAX_QUEUE: usize = 300;

enum Slot {
    Loading,
    Ready(TextureHandle),
    Failed,
}

struct Queue {
    /// Newest last: what is on screen now loads first.
    stack: Vec<String>,
    queued: HashSet<String>,
    /// Being downloaded right now.
    busy: HashSet<String>,
}

pub struct Images {
    slots: HashMap<String, (Slot, u64)>,
    queue: Arc<(Mutex<Queue>, Condvar)>,
    done: Arc<Mutex<Vec<(String, Option<ColorImage>)>>>,
    frame: u64,
}

impl Images {
    pub fn new(cache_dir: PathBuf) -> Self {
        let queue = Arc::new((Mutex::new(Queue { stack: vec![], queued: HashSet::new(), busy: HashSet::new() }), Condvar::new()));
        let done: Arc<Mutex<Vec<(String, Option<ColorImage>)>>> = Arc::default();
        for i in 0..6 {
            let (queue, done, dir) = (queue.clone(), done.clone(), cache_dir.clone());
            std::thread::Builder::new()
                .name(format!("images-{i}"))
                .spawn(move || {
                    loop {
                        let url = {
                            let (lock, cv) = &*queue;
                            let mut q = lock.lock();
                            while q.stack.is_empty() {
                                cv.wait(&mut q);
                            }
                            let url = q.stack.pop().unwrap_or_default();
                            q.queued.remove(&url);
                            q.busy.insert(url.clone());
                            url
                        };
                        let img = load(&dir, &url);
                        done.lock().push((url.clone(), img));
                        queue.0.lock().busy.remove(&url);
                        crate::ui::repaint();
                    }
                })
                .expect("spawn image worker");
        }
        Self { slots: HashMap::new(), queue, done, frame: 0 }
    }

    /// Uploads finished images; call once per frame.
    pub fn begin_frame(&mut self, ctx: &egui::Context) {
        self.frame += 1;
        let done = std::mem::take(&mut *self.done.lock());
        for (url, img) in done {
            let slot = match img {
                Some(img) => Slot::Ready(ctx.load_texture(&url, img, TextureOptions::LINEAR)),
                None => Slot::Failed,
            };
            self.slots.insert(url, (slot, self.frame));
        }
        if self.slots.len() > MAX_TEXTURES {
            let mut ages: Vec<(u64, String)> =
                self.slots.iter().filter(|(_, (s, _))| !matches!(s, Slot::Loading)).map(|(k, (_, f))| (*f, k.clone())).collect();
            ages.sort_unstable();
            for (_, k) in ages.into_iter().take(self.slots.len() - MAX_TEXTURES * 3 / 4) {
                self.slots.remove(&k);
            }
        }
    }

    /// The texture for `url`, starting a download if needed.
    pub fn get(&mut self, url: &str) -> Option<TextureHandle> {
        if url.is_empty() {
            return None;
        }
        let frame = self.frame;
        if let Some((slot, used)) = self.slots.get_mut(url) {
            *used = frame;
            return match slot {
                Slot::Ready(t) => Some(t.clone()),
                Slot::Loading => {
                    self.requeue(url);
                    None
                }
                Slot::Failed => None,
            };
        }
        self.slots.insert(url.to_string(), (Slot::Loading, frame));
        self.requeue(url);
        None
    }

    fn requeue(&self, url: &str) {
        let (lock, cv) = &*self.queue;
        let mut q = lock.lock();
        if q.busy.contains(url) {
            return;
        }
        if q.queued.contains(url) {
            // Already waiting; move it to the front.
            if let Some(i) = q.stack.iter().position(|u| u == url) {
                let u = q.stack.remove(i);
                q.stack.push(u);
            }
            return;
        }
        q.queued.insert(url.to_string());
        q.stack.push(url.to_string());
        if q.stack.len() > MAX_QUEUE {
            let excess = q.stack.len() - MAX_QUEUE;
            let drop: Vec<String> = q.stack.drain(..excess).collect();
            for u in drop {
                q.queued.remove(&u);
            }
        }
        cv.notify_one();
    }
}

fn cache_path(dir: &std::path::Path, url: &str) -> PathBuf {
    dir.join(sha1_smol::Sha1::from(url).digest().to_string())
}

fn load(dir: &std::path::Path, url: &str) -> Option<ColorImage> {
    let path = cache_path(dir, url);
    let bytes = match std::fs::read(&path) {
        Ok(b) => b,
        Err(_) => {
            let b = fetch(url)?;
            let _ = std::fs::write(&path, &b);
            b
        }
    };
    let img = image::load_from_memory(&bytes).ok()?;
    let img = if img.width() > MAX_SIDE || img.height() > MAX_SIDE { img.thumbnail(MAX_SIDE, MAX_SIDE) } else { img };
    let rgba = img.to_rgba8();
    Some(ColorImage::from_rgba_unmultiplied([rgba.width() as usize, rgba.height() as usize], rgba.as_raw()))
}

fn fetch(url: &str) -> Option<Vec<u8>> {
    if crate::http::is_local_path(url) {
        return std::fs::read(url.strip_prefix("file://").unwrap_or(url)).ok();
    }
    let resp = crate::http::shared()
        .get(url)
        .config()
        .timeout_global(Some(Duration::from_secs(20)))
        .build()
        .call()
        .ok()?;
    let mut out = Vec::new();
    resp.into_body().into_with_config().limit(8 * 1024 * 1024).reader().read_to_end(&mut out).ok()?;
    Some(out)
}
