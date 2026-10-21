//! Movies and episodes saved to disk for offline playback.
//!
//! One file downloads at a time (most providers allow a single connection,
//! and a second one would cut off whatever is playing). Partial files resume
//! with HTTP Range requests. The list is saved to `downloads.json` in the
//! same format as the Flutter app, so existing downloads carry over.

use crate::model::{Episode, ItemKind, MediaItem};
use parking_lot::{Condvar, Mutex};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use std::fs::{self, File, OpenOptions};
use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicBool, Ordering};
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Status {
    Queued,
    Downloading,
    Paused,
    Done,
    Failed,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Download {
    pub source_id: i64,
    pub key: String,
    #[serde(with = "kind_index")]
    pub kind: ItemKind,
    pub title: String,
    pub subtitle: Option<String>,
    pub logo: Option<String>,
    pub url: String,
    #[serde(default)]
    pub headers: BTreeMap<String, String>,
    pub path: String,
    pub status: Status,
    #[serde(default)]
    pub received: u64,
    pub total: Option<u64>,
    pub error: Option<String>,
    /// Unix milliseconds.
    pub created_at: i64,
    /// Bytes per second while downloading.
    #[serde(skip)]
    pub speed: f64,
}

mod kind_index {
    use crate::model::ItemKind;
    use serde::{Deserialize, Deserializer, Serializer};

    pub fn serialize<S: Serializer>(k: &ItemKind, s: S) -> Result<S::Ok, S::Error> {
        s.serialize_i64(k.index())
    }

    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<ItemKind, D::Error> {
        Ok(ItemKind::from_i64(i64::deserialize(d)?))
    }
}

impl Download {
    pub fn id(&self) -> String {
        format!("{}|{}", self.source_id, self.key)
    }

    pub fn is_active(&self) -> bool {
        matches!(self.status, Status::Queued | Status::Downloading)
    }

    pub fn fraction(&self) -> Option<f32> {
        self.total.filter(|t| *t > 0).map(|t| (self.received as f32 / t as f32).clamp(0.0, 1.0))
    }
}

/// Whether `url` is a single file that can be saved (not an HLS playlist).
pub fn is_downloadable(url: Option<&str>) -> bool {
    let Some(url) = url else { return false };
    if crate::http::is_local_path(url) {
        return false;
    }
    let path = url.split(['?', '#']).next().unwrap_or(url).to_lowercase();
    !path.ends_with(".m3u8") && !path.ends_with(".m3u")
}

pub fn episode_title(e: &Episode) -> String {
    format!("S{:02}E{:02} · {}", e.season, e.number, e.title)
}

pub fn format_bytes(bytes: f64) -> String {
    let units = ["B", "KB", "MB", "GB", "TB"];
    let (mut v, mut i) = (bytes, 0);
    while v >= 1024.0 && i < units.len() - 1 {
        v /= 1024.0;
        i += 1;
    }
    if i < 2 { format!("{v:.0} {}", units[i]) } else { format!("{v:.1} {}", units[i]) }
}

/// A file or folder name without characters that are not allowed on disk.
fn safe_name(name: &str) -> String {
    let cleaned: String = name.chars().map(|c| if "<>:\"/\\|?*".contains(c) || c.is_control() { ' ' } else { c }).collect();
    let mut s = cleaned.split_whitespace().collect::<Vec<_>>().join(" ");
    while s.ends_with(['.', ' ']) {
        s.pop();
    }
    if s.is_empty() {
        return "Untitled".into();
    }
    if s.chars().count() > 120 {
        s = s.chars().take(120).collect::<String>().trim().to_string();
    }
    s
}

fn extension(url: &str) -> String {
    let path = url.split(['?', '#']).next().unwrap_or(url);
    let file = path.rsplit('/').next().unwrap_or("");
    match file.rsplit_once('.') {
        Some((_, ext)) if (2..=4).contains(&ext.len()) && ext.chars().all(|c| c.is_ascii_alphanumeric()) => ext.to_lowercase(),
        _ => "mp4".into(),
    }
}

fn now_ms() -> i64 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_or(0, |d| d.as_millis() as i64)
}

struct State {
    list: Vec<Download>,
    /// Set to stop the running download (pause or delete).
    stop: Option<(String, Arc<AtomicBool>)>,
    dirty: bool,
}

/// The download queue. Cheap to clone.
#[derive(Clone)]
pub struct Downloads {
    state: Arc<(Mutex<State>, Condvar)>,
    pub dir: PathBuf,
    index: PathBuf,
}

impl Downloads {
    /// Loads the saved list and starts the download thread. `user_agent`
    /// returns the user agent for a playlist.
    pub fn new(dir: PathBuf, index: PathBuf, user_agent: impl Fn(i64) -> Option<String> + Send + 'static) -> Self {
        let mut list: Vec<Download> = fs::read_to_string(&index)
            .ok()
            .and_then(|s| serde_json::from_str(&s).map_err(|e| log::warn!("downloads.json: {e}")).ok())
            .unwrap_or_default();
        // Interrupted by the last exit: pick up where they left off.
        for d in &mut list {
            if d.status == Status::Downloading {
                d.status = Status::Queued;
            }
        }
        let me = Self { state: Arc::new((Mutex::new(State { list, stop: None, dirty: false }), Condvar::new())), dir, index };
        let worker = me.clone();
        std::thread::Builder::new()
            .name("downloads".into())
            .spawn(move || worker.run(user_agent))
            .expect("spawn download thread");
        me
    }

    pub fn list(&self) -> Vec<Download> {
        self.state.0.lock().list.clone()
    }

    pub fn active_count(&self) -> usize {
        self.state.0.lock().list.iter().filter(|d| d.is_active()).count()
    }

    pub fn find(&self, source_id: i64, key: &str) -> Option<Download> {
        self.state.0.lock().list.iter().find(|d| d.source_id == source_id && d.key == key).cloned()
    }

    /// The saved file for an item, if it finished and still exists.
    pub fn local_path(&self, source_id: i64, key: &str) -> Option<String> {
        self.find(source_id, key).filter(|d| d.status == Status::Done && Path::new(&d.path).exists()).map(|d| d.path)
    }

    pub fn add_item(&self, item: &MediaItem) {
        if let Some(url) = &item.url {
            self.add(item.source_id, &item.key, item.kind, &item.name, None, item.logo.clone(), url, item.headers.clone(), None);
        }
    }

    pub fn add_episode(&self, series: &MediaItem, e: &Episode, cover: Option<String>) {
        let logo = e.image.clone().or(cover).or_else(|| series.logo.clone());
        self.add(
            series.source_id,
            &format!("ep:{}", e.id),
            ItemKind::Series,
            &episode_title(e),
            Some(series.name.clone()),
            logo,
            &e.url,
            BTreeMap::new(),
            Some(&series.name),
        );
    }

    /// Queues a download; a paused or failed one is resumed instead.
    #[allow(clippy::too_many_arguments)]
    fn add(
        &self,
        source_id: i64,
        key: &str,
        kind: ItemKind,
        title: &str,
        subtitle: Option<String>,
        logo: Option<String>,
        url: &str,
        headers: BTreeMap<String, String>,
        folder: Option<&str>,
    ) {
        let id = format!("{source_id}|{key}");
        let mut s = self.state.0.lock();
        if let Some(d) = s.list.iter_mut().find(|d| d.id() == id) {
            if matches!(d.status, Status::Paused | Status::Failed) {
                d.status = Status::Queued;
                d.error = None;
            }
        } else {
            let dir = match folder {
                Some(f) => self.dir.join(safe_name(f)),
                None => self.dir.clone(),
            };
            let path = unique_path(&s.list, &dir.join(format!("{}.{}", safe_name(title), extension(url))));
            s.list.push(Download {
                source_id,
                key: key.to_string(),
                kind,
                title: title.to_string(),
                subtitle,
                logo,
                url: url.to_string(),
                headers,
                path: path.display().to_string(),
                status: Status::Queued,
                received: 0,
                total: None,
                error: None,
                created_at: now_ms(),
                speed: 0.0,
            });
        }
        s.dirty = true;
        self.state.1.notify_all();
    }

    pub fn pause(&self, id: &str) {
        let mut s = self.state.0.lock();
        stop_running(&mut s, id);
        if let Some(d) = s.list.iter_mut().find(|d| d.id() == id && d.is_active()) {
            d.status = Status::Paused;
            d.speed = 0.0;
        }
        s.dirty = true;
        self.state.1.notify_all();
    }

    pub fn resume(&self, id: &str) {
        let mut s = self.state.0.lock();
        if let Some(d) = s.list.iter_mut().find(|d| d.id() == id && matches!(d.status, Status::Paused | Status::Failed)) {
            d.status = Status::Queued;
            d.error = None;
        }
        s.dirty = true;
        self.state.1.notify_all();
    }

    /// Removes the download and deletes its file (finished or partial).
    pub fn remove(&self, id: &str) {
        let removed = {
            let mut s = self.state.0.lock();
            stop_running(&mut s, id);
            let pos = s.list.iter().position(|d| d.id() == id);
            s.dirty = true;
            self.state.1.notify_all();
            pos.map(|i| s.list.remove(i))
        };
        if let Some(d) = removed {
            // The download thread may still hold the file for a moment.
            std::thread::spawn(move || {
                for _ in 0..20 {
                    let a = fs::remove_file(&d.path);
                    let b = fs::remove_file(format!("{}.part", d.path));
                    if a.is_ok() || b.is_ok() || !Path::new(&d.path).exists() && !Path::new(&format!("{}.part", d.path)).exists() {
                        break;
                    }
                    std::thread::sleep(Duration::from_millis(200));
                }
            });
        }
    }

    fn save(&self, list: &[Download]) {
        if let Some(p) = self.index.parent() {
            let _ = fs::create_dir_all(p);
        }
        if let Ok(json) = serde_json::to_string(list) {
            let tmp = self.index.with_extension("json.tmp");
            if fs::write(&tmp, json).is_ok() {
                let _ = fs::rename(&tmp, &self.index);
            }
        }
    }

    fn update(&self, id: &str, f: impl FnOnce(&mut Download)) {
        let mut s = self.state.0.lock();
        if let Some(d) = s.list.iter_mut().find(|d| d.id() == id) {
            f(d);
        }
        s.dirty = true;
        crate::ui::repaint();
    }

    /// The download thread: saves the list when it changes and runs queued
    /// downloads one at a time.
    fn run(&self, user_agent: impl Fn(i64) -> Option<String>) {
        loop {
            let (next, to_save) = {
                let mut s = self.state.0.lock();
                loop {
                    let to_save = std::mem::take(&mut s.dirty).then(|| s.list.clone());
                    let next = s.list.iter_mut().find(|d| d.status == Status::Queued).map(|d| {
                        d.status = Status::Downloading;
                        d.clone()
                    });
                    if let Some(d) = &next {
                        let stop = Arc::new(AtomicBool::new(false));
                        s.stop = Some((d.id(), stop.clone()));
                        break (Some((d.clone(), stop)), to_save);
                    }
                    if to_save.is_some() {
                        break (None, to_save);
                    }
                    self.state.1.wait_for(&mut s, Duration::from_secs(5));
                }
            };
            if let Some(list) = to_save {
                self.save(&list);
                crate::ui::repaint();
            }
            let Some((d, stop)) = next else { continue };
            let id = d.id();
            let ua = user_agent(d.source_id);
            let result = self.fetch(&d, ua.as_deref(), &stop);
            let stopped = stop.load(Ordering::Relaxed);
            {
                let mut s = self.state.0.lock();
                if s.stop.as_ref().is_some_and(|(i, _)| *i == id) {
                    s.stop = None;
                }
            }
            match result {
                Ok(()) => {
                    log::info!("downloaded {} -> {}", d.title, d.path);
                    self.update(&id, |x| {
                        x.status = Status::Done;
                        x.speed = 0.0;
                        x.total = Some(x.received);
                    });
                }
                Err(e) if !stopped => {
                    log::warn!("download {} failed: {e}", d.title);
                    let part = fs::metadata(format!("{}.part", d.path)).map(|m| m.len()).unwrap_or(0);
                    self.update(&id, |x| {
                        x.status = Status::Failed;
                        x.speed = 0.0;
                        x.received = part;
                        x.error = Some(e);
                    });
                }
                Err(_) => {}
            }
        }
    }

    fn fetch(&self, d: &Download, user_agent: Option<&str>, stop: &AtomicBool) -> Result<(), String> {
        let id = d.id();
        let part = PathBuf::from(format!("{}.part", d.path));
        if let Some(dir) = part.parent() {
            fs::create_dir_all(dir).map_err(|e| format!("Could not create {}: {e}", dir.display()))?;
        }
        let mut start = fs::metadata(&part).map(|m| m.len()).unwrap_or(0);
        let agent: ureq::Agent = ureq::Agent::config_builder()
            .timeout_connect(Some(Duration::from_secs(30)))
            .timeout_recv_response(Some(Duration::from_secs(60)))
            .timeout_recv_body(Some(Duration::from_secs(60)))
            .http_status_as_error(false)
            .user_agent(user_agent.filter(|u| !u.is_empty()).unwrap_or(crate::http::DEFAULT_USER_AGENT))
            .build()
            .into();
        let mut req = agent.get(&d.url).header("Accept-Encoding", "identity");
        for (k, v) in &d.headers {
            req = req.header(k.as_str(), v.as_str());
        }
        if start > 0 {
            req = req.header("Range", format!("bytes={start}-"));
        }
        let resp = req.call().map_err(|e| crate::http::friendly(&e, &d.url))?;
        let code = resp.status().as_u16();
        if code == 416 && start > 0 {
            // Nothing left to fetch: the partial file is already complete.
            self.update(&id, |x| x.received = start);
        } else {
            if code >= 400 {
                return Err(format!("Server returned HTTP {code}"));
            }
            if start > 0 && code != 206 {
                start = 0; // The server ignored the range: start over.
            }
            let len = resp.headers().get("content-length").and_then(|v| v.to_str().ok()?.parse::<u64>().ok());
            let total = len.map(|l| start + l);
            let mut file = if start > 0 {
                OpenOptions::new().append(true).open(&part)
            } else {
                File::create(&part)
            }
            .map_err(|e| format!("Could not write the file: {e}"))?;
            let mut body = resp.into_body().into_with_config().limit(u64::MAX).reader();
            let mut buf = vec![0u8; 256 * 1024];
            let (mut received, mut last_bytes, mut last) = (start, start, Instant::now());
            self.update(&id, |x| {
                x.received = received;
                x.total = total;
            });
            loop {
                if stop.load(Ordering::Relaxed) {
                    return Err("stopped".into());
                }
                let n = body.read(&mut buf).map_err(|e| format!("Network error: {e}"))?;
                if n == 0 {
                    break;
                }
                file.write_all(&buf[..n]).map_err(|e| format!("Could not write the file: {e}"))?;
                received += n as u64;
                let elapsed = last.elapsed();
                if elapsed >= Duration::from_millis(500) {
                    let speed = (received - last_bytes) as f64 / elapsed.as_secs_f64();
                    (last_bytes, last) = (received, Instant::now());
                    self.update(&id, |x| {
                        x.received = received;
                        x.speed = speed;
                    });
                }
            }
            file.flush().map_err(|e| format!("Could not write the file: {e}"))?;
            if total.is_some_and(|t| received < t) {
                return Err("Connection dropped before the file finished".into());
            }
            self.update(&id, |x| x.received = received);
        }
        let _ = fs::remove_file(&d.path);
        fs::rename(&part, &d.path).map_err(|e| format!("Could not save the file: {e}"))
    }
}

fn stop_running(s: &mut State, id: &str) {
    if let Some((running, flag)) = &s.stop
        && running == id
    {
        flag.store(true, Ordering::Relaxed);
    }
}

/// `path`, or `path (2)`, `path (3)`… if taken by another download or file.
fn unique_path(list: &[Download], path: &Path) -> PathBuf {
    let taken = |p: &Path| list.iter().any(|d| Path::new(&d.path) == p) || p.exists();
    if !taken(path) {
        return path.to_path_buf();
    }
    let stem = path.file_stem().map(|s| s.to_string_lossy().into_owned()).unwrap_or_default();
    let ext = path.extension().map(|e| format!(".{}", e.to_string_lossy())).unwrap_or_default();
    (2..)
        .map(|n| path.with_file_name(format!("{stem} ({n}){ext}")))
        .find(|p| !taken(p))
        .unwrap_or_else(|| path.to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{BufRead, BufReader};
    use std::net::TcpListener;

    #[test]
    fn names_and_urls() {
        assert_eq!(safe_name("A: B/C?  "), "A B C");
        assert_eq!(safe_name("..."), "Untitled");
        assert_eq!(extension("http://h/movie/u/p/1.mkv?token=1"), "mkv");
        assert_eq!(extension("http://h/play?id=3"), "mp4");
        assert!(is_downloadable(Some("http://h/movie/1.mp4")));
        assert!(!is_downloadable(Some("http://h/live/1.m3u8?x")));
        assert!(!is_downloadable(Some("/local/file.mkv")));
        assert_eq!(format_bytes(1536.0 * 1024.0), "1.5 MB");
    }

    #[test]
    fn reads_flutter_index() {
        let json = r#"[{"sourceId":1,"key":"x:5","kind":1,"title":"Film","subtitle":null,"logo":null,
            "url":"http://h/movie/u/p/5.mp4","headers":{},"path":"/tmp/Film.mp4","status":"done",
            "received":10,"total":10,"error":null,"createdAt":1700000000000}]"#;
        let list: Vec<Download> = serde_json::from_str(json).unwrap();
        assert_eq!(list[0].kind, ItemKind::Movie);
        assert_eq!(list[0].status, Status::Done);
        let back = serde_json::to_string(&list).unwrap();
        assert!(back.contains("\"sourceId\":1") && back.contains("\"status\":\"done\"") && back.contains("\"kind\":1"));
    }

    /// Serves `body`, honouring `Range: bytes=N-`.
    fn serve(body: Vec<u8>, requests: usize) -> String {
        let l = TcpListener::bind("127.0.0.1:0").unwrap();
        let addr = l.local_addr().unwrap();
        std::thread::spawn(move || {
            for stream in l.incoming().take(requests) {
                let mut s = stream.unwrap();
                let mut r = BufReader::new(s.try_clone().unwrap());
                let mut start = 0usize;
                loop {
                    let mut line = String::new();
                    r.read_line(&mut line).unwrap();
                    if line.trim().is_empty() {
                        break;
                    }
                    if let Some(v) = line.to_lowercase().strip_prefix("range: bytes=") {
                        start = v.trim().trim_end_matches('-').parse().unwrap();
                    }
                }
                let part = &body[start..];
                let status = if start > 0 { "206 Partial Content" } else { "200 OK" };
                let _ = write!(s, "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", part.len());
                let _ = s.write_all(part);
            }
        });
        format!("http://{addr}/movie/u/p/7.mkv")
    }

    #[test]
    fn downloads_and_resumes_partial_files() {
        let dir = std::env::temp_dir().join(format!("catplay-dl-{}", std::process::id()));
        let _ = fs::remove_dir_all(&dir);
        let body: Vec<u8> = (0..300_000u32).map(|i| (i % 251) as u8).collect();
        let url = serve(body.clone(), 1);
        let dl = Downloads::new(dir.join("files"), dir.join("downloads.json"), |_| None);
        let item = MediaItem {
            id: 1,
            source_id: 1,
            kind: ItemKind::Movie,
            key: "x:7".into(),
            name: "My: Film".into(),
            category_id: None,
            logo: None,
            url: Some(url),
            epg_id: None,
            number: None,
            ext_id: None,
            container: None,
            rating: None,
            year: None,
            catchup_days: None,
            headers: Default::default(),
            favorite: false,
        };
        // Pretend half of it was downloaded before.
        let target = dir.join("files").join("My Film.mkv");
        fs::create_dir_all(target.parent().unwrap()).unwrap();
        fs::write(format!("{}.part", target.display()), &body[..100_000]).unwrap();
        dl.add_item(&item);
        let until = Instant::now() + Duration::from_secs(10);
        while dl.local_path(1, "x:7").is_none() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(dl.local_path(1, "x:7").as_deref(), Some(target.to_str().unwrap()), "{:?}", dl.list());
        assert_eq!(fs::read(&target).unwrap(), body);
        // The list was saved.
        std::thread::sleep(Duration::from_millis(100));
        assert!(fs::read_to_string(dir.join("downloads.json")).unwrap().contains("\"status\":\"done\""));
        dl.remove(&format!("1|x:7"));
        std::thread::sleep(Duration::from_millis(300));
        assert!(!target.exists());
        let _ = fs::remove_dir_all(&dir);
    }
}
