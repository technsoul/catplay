//! The app's single playback engine (libmpv). One instance is shared by the
//! Live TV preview and the full-screen player, so switching between them
//! never restarts the stream.

pub mod mpv;
pub mod render;

use crate::db::{Db, Group, Task};
use crate::model::{MediaItem, Playable};
use crate::repo::{self, ItemQuery};
use crate::settings::Settings;
use mpv::Mpv;
use parking_lot::Mutex;
use std::ffi::CStr;
use std::sync::Arc;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Phase {
    Idle,
    Loading,
    Playing,
    Reconnecting,
    Error,
}

/// Observed mpv properties (reply ids for `observe_property`).
const P_TIME: u64 = 1;
const P_DURATION: u64 = 2;
const P_PAUSE: u64 = 3;
const P_CACHE_WAIT: u64 = 4;
const P_VOLUME: u64 = 5;
const P_MUTE: u64 = 6;

#[derive(Default)]
struct Shared {
    position: f64,
    duration: f64,
    paused: bool,
    buffering: bool,
    volume: f64,
    muted: bool,
    /// Last mpv error line, used to explain a failed open.
    last_error: String,
    events: Vec<PlayerEvent>,
}

enum PlayerEvent {
    Loaded,
    Ended,
    Failed(String),
}

#[derive(Debug, Clone)]
pub struct Track {
    pub id: i64,
    pub kind: String,
    pub label: String,
    pub selected: bool,
}

/// What `open` needs from the database before starting.
struct Prepared {
    playable: Playable,
    user_agent: Option<String>,
    zap: Option<(ItemQuery, i64)>,
}

pub struct Player {
    pub mpv: Option<Arc<Mpv>>,
    /// Why libmpv is unavailable.
    pub unavailable: Option<String>,
    shared: Arc<Mutex<Shared>>,
    db: Db,
    pub playable: Option<Playable>,
    pub phase: Phase,
    pub error: Option<String>,
    pub attempt: usize,
    zap: Option<(ItemQuery, i64)>,
    pending: Option<Task<Prepared>>,
    pending_zap: Option<ZapTask>,
    retry_at: Option<Instant>,
    save_at: Option<Instant>,
    last_pos: Option<f64>,
    progress: f64,
    ignore_until: Instant,
    stable_since: Option<Instant>,
    ever_played: bool,
    default_user_agent: String,
    /// Set when the volume changed and should be saved in settings.
    pub volume_dirty: bool,
    /// `source|key` of the live channel last opened, for settings.
    pub last_live: Option<String>,
}

impl Player {
    pub fn new(db: Db, settings: &Settings) -> Self {
        let shared: Arc<Mutex<Shared>> = Arc::new(Mutex::new(Shared { volume: settings.volume, ..Default::default() }));
        let cache = settings.cache_seconds.to_string();
        let ua = if settings.user_agent.is_empty() { crate::http::DEFAULT_USER_AGENT.to_string() } else { settings.user_agent.clone() };
        let hwdec = if settings.hardware_decoding { "auto-safe" } else { "no" };
        let volume = format!("{}", settings.volume);
        let options: Vec<(&str, &str)> = vec![
            ("vo", "libmpv"),
            // mpv's on-disk shader binaries can come back broken (black video)
            // after a driver change; GPU drivers keep their own cache anyway.
            ("gpu-shader-cache", "no"),
            // Light rendering: bilinear scaling and no dithering or debanding
            // keep the GPU (and the laptop) cool. It also avoids the two-pass
            // scalers, which rendered black frames on some OpenGL drivers.
            ("scale", "bilinear"),
            ("dscale", "bilinear"),
            ("cscale", "bilinear"),
            ("dither-depth", "no"),
            ("correct-downscaling", "no"),
            ("linear-downscaling", "no"),
            ("sigmoid-upscaling", "no"),
            ("deband", "no"),
            ("load-scripts", "no"),
            ("hwdec", hwdec),
            ("idle", "yes"),
            ("keep-open", "no"),
            ("config", "no"),
            ("terminal", "no"),
            ("input-default-bindings", "no"),
            ("input-vo-keyboard", "no"),
            ("osc", "no"),
            ("ytdl", "no"),
            ("title", "CAT"),
            ("audio-client-name", "CAT"),
            ("network-timeout", "20"),
            ("cache", "yes"),
            ("cache-secs", &cache),
            ("demuxer-readahead-secs", &cache),
            ("demuxer-max-bytes", "96MiB"),
            ("demuxer-max-back-bytes", "32MiB"),
            ("hls-bitrate", "max"),
            ("user-agent", &ua),
            ("volume", &volume),
            ("volume-max", "100"),
        ];
        // No `stream-lavf-o=reconnect=…`: FFmpeg's own reconnect loops stall
        // channel changes over TLS. Dropped streams are reopened with backoff.
        // CAT_MPV_OPTS="key=value,key=value" adds mpv options for diagnosis.
        let extra = std::env::var("CAT_MPV_OPTS").unwrap_or_default();
        let mut options = options;
        options.extend(extra.split(',').filter_map(|kv| kv.split_once('=')));
        let (mpv, unavailable) = match Mpv::new(&options) {
            Ok(m) => (Some(Arc::new(m)), None),
            Err(e) => {
                log::error!("{e}");
                (None, Some(e))
            }
        };
        if let Some(m) = &mpv {
            m.observe(P_TIME, "time-pos", mpv::FORMAT_DOUBLE);
            m.observe(P_DURATION, "duration", mpv::FORMAT_DOUBLE);
            m.observe(P_PAUSE, "pause", mpv::FORMAT_FLAG);
            m.observe(P_CACHE_WAIT, "paused-for-cache", mpv::FORMAT_FLAG);
            m.observe(P_VOLUME, "volume", mpv::FORMAT_DOUBLE);
            m.observe(P_MUTE, "mute", mpv::FORMAT_FLAG);
            // CAT_MPV_LOG=v (or debug) gives verbose mpv logs for diagnosing streams.
            let level = mpv::cstr(&std::env::var("CAT_MPV_LOG").unwrap_or_else(|_| "warn".into()));
            unsafe { (m.api.request_log_messages)(m.handle, level.as_ptr()) };
            spawn_event_loop(m.clone(), shared.clone());
        }
        Self {
            mpv,
            unavailable,
            shared,
            db,
            playable: None,
            phase: Phase::Idle,
            error: None,
            attempt: 0,
            zap: None,
            pending: None,
            pending_zap: None,
            retry_at: None,
            save_at: None,
            last_pos: None,
            progress: 0.0,
            ignore_until: Instant::now(),
            stable_since: None,
            ever_played: false,
            default_user_agent: ua,
            volume_dirty: false,
            last_live: None,
        }
    }

    pub fn position(&self) -> f64 {
        self.shared.lock().position
    }

    pub fn duration(&self) -> f64 {
        self.shared.lock().duration
    }

    pub fn paused(&self) -> bool {
        self.shared.lock().paused
    }

    pub fn buffering(&self) -> bool {
        self.shared.lock().buffering
    }

    pub fn volume(&self) -> f64 {
        self.shared.lock().volume
    }

    pub fn muted(&self) -> bool {
        self.shared.lock().muted
    }

    pub fn is_live(&self) -> bool {
        self.playable.as_ref().is_some_and(Playable::is_live)
    }

    pub fn zap_index(&self) -> Option<i64> {
        self.zap.as_ref().map(|z| z.1)
    }

    pub fn can_zap(&self) -> bool {
        self.zap.is_some()
    }

    /// Opens a list item; `zap` is the list it came from and its index, so
    /// channel up/down can move through it.
    pub fn open_item(&mut self, item: &MediaItem, subtitle: Option<String>, zap: Option<(ItemQuery, i64)>) {
        let Some(url) = item.url.clone() else { return };
        let playable = Playable {
            source_id: item.source_id,
            key: item.key.clone(),
            kind: item.kind,
            title: item.name.clone(),
            subtitle,
            url,
            logo: item.logo.clone(),
            headers: item.headers.clone(),
            epg_id: item.epg_id.clone(),
            catchup_days: item.catchup_days,
            resume_ms: None,
        };
        self.open(playable, zap);
    }

    pub fn open(&mut self, p: Playable, zap: Option<(ItemQuery, i64)>) {
        self.save_progress();
        self.retry_at = None;
        self.save_at = None;
        let zap = zap.or_else(|| if p.is_live() { self.zap.clone() } else { None });
        self.playable = Some(p.clone());
        self.phase = Phase::Loading;
        self.error = None;
        self.attempt = 0;
        self.zap = zap.clone();
        self.pending = Some(self.db.read(move |c| {
            let source = repo::source(c, p.source_id)?;
            let mut playable = p;
            if !playable.is_live() && playable.resume_ms.is_none() {
                playable.resume_ms = repo::resume_position(c, playable.source_id, &playable.key)?;
            }
            Ok(Prepared { user_agent: source.and_then(|s| s.user_agent).filter(|s| !s.is_empty()), playable, zap })
        }));
    }

    fn start(&mut self, prep: Prepared) {
        let Some(m) = &self.mpv else {
            self.phase = Phase::Error;
            self.error = self.unavailable.clone();
            return;
        };
        let p = &prep.playable;
        let mut headers = p.headers.clone();
        let ua = headers.remove("User-Agent").or(prep.user_agent).unwrap_or_else(|| self.default_user_agent.clone());
        m.set("user-agent", &ua);
        let fields: Vec<String> = headers.iter().map(|(k, v)| format!("{k}: {}", v.replace(',', "\\,"))).collect();
        m.set("http-header-fields", &fields.join(","));
        let start = match p.resume_ms {
            Some(ms) => format!("{}", ms as f64 / 1000.0),
            None => "none".into(),
        };
        m.set("start", &start);
        {
            let mut s = self.shared.lock();
            s.last_error.clear();
            s.position = 0.0;
            s.duration = 0.0;
        }
        // Position updates from the previous stream can still arrive; only
        // progress measured within this open counts.
        self.last_pos = None;
        self.progress = 0.0;
        self.ignore_until = Instant::now() + Duration::from_millis(700);
        self.stable_since = None;
        m.command(&["loadfile", &p.url, "replace"]);
        m.set_flag("pause", false);
        if p.is_live() {
            let pp = p.clone();
            self.last_live = Some(format!("{}|{}", p.source_id, p.key));
            self.db.write(&[Group::History], move |c| repo::save_progress(c, &pp, 0, 0));
        } else {
            self.save_at = Some(Instant::now() + Duration::from_secs(10));
        }
        self.zap = prep.zap;
    }

    /// Re-opens the current stream without touching history or settings.
    fn reopen(&mut self) {
        let Some(p) = self.playable.clone() else { return };
        let Some(m) = &self.mpv else { return };
        self.shared.lock().last_error.clear();
        self.last_pos = None;
        self.progress = 0.0;
        self.ignore_until = Instant::now() + Duration::from_millis(700);
        m.command(&["loadfile", &p.url, "replace"]);
    }

    pub fn retry(&mut self) {
        if self.playable.is_some() {
            self.phase = Phase::Loading;
            self.attempt = 0;
            self.error = None;
            self.reopen();
        }
    }

    /// Channel up/down within the list the channel came from.
    pub fn zap(&mut self, delta: i64) {
        let Some((q, idx)) = self.zap.clone() else { return };
        let task = self.db.read(move |c| repo::item_at(c, &q, idx + delta).map(|r| (r, q)));
        // Resolved in `tick`.
        self.pending_zap = Some(task);
    }

    pub fn toggle_pause(&self) {
        if let Some(m) = &self.mpv {
            m.command(&["cycle", "pause"]);
        }
    }

    pub fn seek_relative(&self, secs: f64) {
        if let Some(m) = &self.mpv {
            m.command(&["seek", &format!("{secs}"), "relative"]);
        }
    }

    pub fn seek_to(&self, secs: f64) {
        if let Some(m) = &self.mpv {
            m.command(&["seek", &format!("{secs}"), "absolute"]);
        }
    }

    pub fn set_volume(&mut self, v: f64) {
        if let Some(m) = &self.mpv {
            let v = v.clamp(0.0, 100.0);
            m.set_f64("volume", v);
            self.shared.lock().volume = v;
            self.volume_dirty = true;
        }
    }

    pub fn toggle_mute(&self) {
        if let Some(m) = &self.mpv {
            m.command(&["cycle", "mute"]);
        }
    }

    pub fn tracks(&self) -> Vec<Track> {
        let Some(m) = &self.mpv else { return vec![] };
        let n = m.get_i64("track-list/count").unwrap_or(0);
        (0..n)
            .filter_map(|i| {
                let f = |k: &str| m.get_string(&format!("track-list/{i}/{k}"));
                let kind = f("type")?;
                let id = m.get_i64(&format!("track-list/{i}/id"))?;
                let label = match (f("title"), f("lang")) {
                    (Some(t), Some(l)) => format!("{t} ({l})"),
                    (Some(t), None) => t,
                    (None, Some(l)) => l,
                    (None, None) => format!("Track {id}"),
                };
                Some(Track { id, kind, label, selected: m.get_flag(&format!("track-list/{i}/selected")).unwrap_or(false) })
            })
            .collect()
    }

    /// Selects an audio (`aid`) or subtitle (`sid`) track; None turns
    /// subtitles off.
    pub fn select_track(&self, prop: &str, id: Option<i64>) {
        if let Some(m) = &self.mpv {
            m.set(prop, &id.map_or("no".into(), |i| i.to_string()));
        }
    }

    pub fn video_size(&self) -> Option<(f64, f64)> {
        let m = self.mpv.as_ref()?;
        let w = m.get_i64("dwidth")?;
        let h = m.get_i64("dheight")?;
        (w > 0 && h > 0).then_some((w as f64, h as f64))
    }

    fn save_progress(&self) -> Option<Task<()>> {
        let p = self.playable.clone()?;
        if p.is_live() || self.phase == Phase::Idle {
            return None;
        }
        let (pos, dur) = {
            let s = self.shared.lock();
            (s.position, s.duration)
        };
        if pos < 5.0 {
            return None;
        }
        Some(self.db.write(&[Group::History], move |c| repo::save_progress(c, &p, (pos * 1000.0) as i64, (dur * 1000.0) as i64)))
    }

    pub fn stop(&mut self) {
        self.save_progress();
        self.pending = None;
        self.pending_zap = None;
        self.retry_at = None;
        self.save_at = None;
        self.zap = None;
        self.playable = None;
        self.phase = Phase::Idle;
        self.error = None;
        if let Some(m) = &self.mpv {
            m.command(&["stop"]);
        }
    }

    /// Advances timers and applies mpv events; call every frame.
    pub fn tick(&mut self) {
        if let Some(t) = &self.pending
            && let Some(r) = t.take()
        {
            self.pending = None;
            match r {
                Ok(prep) if Some(&prep.playable.key) == self.playable.as_ref().map(|p| &p.key) => self.start(prep),
                Ok(_) => {}
                Err(e) => {
                    self.phase = Phase::Error;
                    self.error = Some(e);
                }
            }
        }
        if let Some(t) = &self.pending_zap
            && let Some(r) = t.take()
        {
            self.pending_zap = None;
            if let Ok((Some((item, idx)), q)) = r {
                self.open_item(&item, None, Some((q, idx)));
            }
        }

        let (events, pos, buffering) = {
            let mut s = self.shared.lock();
            (std::mem::take(&mut s.events), s.position, s.buffering)
        };
        for e in events {
            match e {
                PlayerEvent::Loaded => {}
                PlayerEvent::Ended => {
                    if self.is_live() {
                        self.on_error("Stream ended".into());
                    } else if self.phase != Phase::Error {
                        // Finished: forget the resume point.
                        if let Some(p) = &self.playable {
                            let (sid, key) = (p.source_id, p.key.clone());
                            self.db.write(&[Group::History], move |c| repo::remove_history(c, sid, &key));
                        }
                        self.playable = None;
                        self.phase = Phase::Idle;
                        self.save_at = None;
                    }
                }
                PlayerEvent::Failed(msg) => self.on_error(msg),
            }
        }

        if self.playable.is_some() && Instant::now() >= self.ignore_until {
            if let Some(last) = self.last_pos {
                let delta = pos - last;
                // Small forward steps are playback; big jumps are seeks.
                if delta > 0.0 && delta < 3.0 {
                    self.progress += delta;
                    let since = *self.stable_since.get_or_insert_with(Instant::now);
                    if self.attempt > 0 && since.elapsed() > Duration::from_secs(30) {
                        self.attempt = 0;
                    }
                    if self.progress > 1.0 {
                        self.ever_played = true;
                    }
                    if self.phase != Phase::Playing && !buffering && self.progress > 0.3 {
                        self.phase = Phase::Playing;
                    }
                }
            }
            self.last_pos = Some(pos);
        }

        let now = Instant::now();
        if self.retry_at.is_some_and(|t| now >= t) {
            self.retry_at = None;
            self.reopen();
        }
        if self.save_at.is_some_and(|t| now >= t) {
            self.save_progress();
            self.save_at = Some(now + Duration::from_secs(10));
        }
        if let Some(t) = self.retry_at {
            crate::ui::repaint_after(t.saturating_duration_since(now));
        }
    }

    fn on_error(&mut self, error: String) {
        let Some(p) = &self.playable else { return };
        log::info!("player error: {error}");
        self.stable_since = None;
        // Live streams drop often: retry with backoff. A stream that never
        // started (offline, 404) only gets two quick tries.
        let max = if self.ever_played { 6 } else { 2 };
        if p.is_live() && self.attempt < max {
            self.attempt += 1;
            let delay = [1, 2, 3, 5, 8, 10][self.attempt - 1];
            self.phase = Phase::Reconnecting;
            self.retry_at = Some(Instant::now() + Duration::from_secs(delay));
            return;
        }
        self.phase = Phase::Error;
        self.error = Some(friendly(&error));
    }

    /// Saves the position (waiting briefly so it lands before exit) and lets
    /// mpv shut down.
    pub fn shutdown(&mut self) {
        if let Some(t) = self.save_progress() {
            let until = Instant::now() + Duration::from_secs(2);
            while !t.is_done() && Instant::now() < until {
                std::thread::sleep(Duration::from_millis(10));
            }
        }
        self.playable = None;
        if let Some(m) = self.mpv.take() {
            m.command(&["quit"]);
        }
    }
}

fn friendly(e: &str) -> String {
    let l = e.to_lowercase();
    if l.contains("403") || l.contains("forbidden") {
        "Access denied by the server (403). Your subscription may have expired or reached its connection limit.".into()
    } else if l.contains("404") {
        "Stream not found (404). The channel may be offline.".into()
    } else if l.contains("401") {
        "Unauthorized (401). Check your login.".into()
    } else if l.contains("timed out") || l.contains("timeout") {
        "The stream timed out.".into()
    } else if l.contains("failed to open") || l.contains("loading failed") || l.contains("unrecognized file format") {
        "Could not open the stream. It may be offline.".into()
    } else {
        e.to_string()
    }
}

fn spawn_event_loop(m: Arc<Mpv>, shared: Arc<Mutex<Shared>>) {
    std::thread::Builder::new()
        .name("mpv-events".into())
        .spawn(move || {
            loop {
                let ev = unsafe { &*(m.api.wait_event)(m.handle, -1.0) };
                let mut s = shared.lock();
                match ev.event_id {
                    mpv::EVENT_SHUTDOWN => break,
                    mpv::EVENT_NONE => continue,
                    mpv::EVENT_PROPERTY_CHANGE => {
                        let p = unsafe { &*(ev.data as *const mpv::EventProperty) };
                        let f64v = || (p.format == mpv::FORMAT_DOUBLE && !p.data.is_null()).then(|| unsafe { *(p.data as *const f64) });
                        let flag = || (p.format == mpv::FORMAT_FLAG && !p.data.is_null()).then(|| unsafe { *(p.data as *const i32) } != 0);
                        match ev.reply_userdata {
                            P_TIME => s.position = f64v().unwrap_or(0.0),
                            P_DURATION => s.duration = f64v().unwrap_or(0.0),
                            P_PAUSE => s.paused = flag().unwrap_or(false),
                            P_CACHE_WAIT => s.buffering = flag().unwrap_or(false),
                            P_VOLUME => s.volume = f64v().unwrap_or(s.volume),
                            P_MUTE => s.muted = flag().unwrap_or(false),
                            _ => {}
                        }
                        // Position ticks are frequent; the video's own redraws
                        // already repaint while playing.
                        if ev.reply_userdata == P_TIME {
                            continue;
                        }
                    }
                    mpv::EVENT_LOG_MESSAGE => {
                        let l = unsafe { &*(ev.data as *const mpv::EventLogMessage) };
                        let text = unsafe { CStr::from_ptr(l.text) }.to_string_lossy().trim().to_string();
                        let prefix = unsafe { CStr::from_ptr(l.prefix) }.to_string_lossy();
                        let level = unsafe { CStr::from_ptr(l.level) }.to_string_lossy();
                        log::info!("mpv [{prefix}] {level}: {text}");
                        if level == "error" || level == "fatal" || text.contains("HTTP error") {
                            s.last_error = text;
                        }
                        continue;
                    }
                    mpv::EVENT_FILE_LOADED => {
                        log::info!("mpv: file loaded");
                        s.events.push(PlayerEvent::Loaded)
                    }
                    mpv::EVENT_END_FILE => {
                        let e = unsafe { &*(ev.data as *const mpv::EventEndFile) };
                        log::info!("mpv: end file, reason {} error {}", e.reason, e.error);
                        match e.reason {
                            mpv::END_FILE_ERROR => {
                                let msg = if s.last_error.is_empty() { mpv::error_string(e.error) } else { s.last_error.clone() };
                                s.events.push(PlayerEvent::Failed(msg));
                            }
                            mpv::END_FILE_EOF => s.events.push(PlayerEvent::Ended),
                            _ => {}
                        }
                    }
                    _ => continue,
                }
                drop(s);
                crate::ui::repaint();
            }
        })
        .expect("spawn mpv event thread");
}

// Zap lookups resolve in `tick`.
type ZapTask = Task<(Option<(MediaItem, i64)>, ItemQuery)>;
