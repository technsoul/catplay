//! Playlist and TV guide imports. Imports run one at a time on a background
//! thread (they are CPU and disk heavy and share the database write lock);
//! the UI reads their progress from [`Importer::statuses`].

use crate::db::{self, Db, Group};
use crate::http;
use crate::model::{ItemKind, SourceType};
use crate::parse::m3u::M3uParser;
use crate::parse::xmltv::{XmltvParser, XmltvProgramme, normalize_channel_name};
use crate::parse::xtream::{Xtream, f64_of, int_of, str_of};
use crate::repo::{self, now_secs};
use crate::secrets;
use crate::settings::Settings;
use crossbeam_channel::{Sender, unbounded};
use parking_lot::Mutex;
use rusqlite::{Connection, params};
use serde_json::{Map, Value};
use std::collections::{BTreeMap, HashMap};
use std::io::{BufRead, BufReader, Read};
use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Scope {
    Playlist,
    Epg,
    All,
}

#[derive(Debug, Clone)]
pub struct Status {
    pub message: String,
    pub fraction: Option<f32>,
    pub running: bool,
    pub error: Option<String>,
    pub finished_at: Option<Instant>,
}

impl Status {
    pub fn active(&self) -> bool {
        self.finished_at.is_none()
    }
}

struct Job {
    source_id: i64,
    scope: Scope,
    settings: Settings,
}

#[derive(Clone)]
pub struct Importer {
    statuses: Arc<Mutex<HashMap<i64, Status>>>,
    jobs: Sender<Job>,
}

impl Importer {
    pub fn new(db: Db, temp_dir: PathBuf) -> Self {
        let statuses: Arc<Mutex<HashMap<i64, Status>>> = Arc::default();
        let (jobs, rx) = unbounded::<Job>();
        let st = statuses.clone();
        std::thread::Builder::new()
            .name("import".into())
            .spawn(move || {
                for job in rx {
                    run_job(&db, &temp_dir, &st, job);
                }
            })
            .expect("spawn import thread");
        Self { statuses, jobs }
    }

    pub fn statuses(&self) -> HashMap<i64, Status> {
        let mut s = self.statuses.lock();
        // Successful imports fade out after a few seconds.
        s.retain(|_, v| v.error.is_some() || v.finished_at.is_none_or(|t| t.elapsed() < Duration::from_secs(6)));
        s.clone()
    }

    pub fn is_active(&self, source_id: i64) -> bool {
        self.statuses.lock().get(&source_id).is_some_and(Status::active)
    }

    pub fn any_running(&self) -> bool {
        self.statuses.lock().values().any(|s| s.running)
    }

    /// Queues an import, unless this playlist is already queued or running.
    pub fn enqueue(&self, source_id: i64, scope: Scope, settings: &Settings) {
        {
            let mut s = self.statuses.lock();
            if s.get(&source_id).is_some_and(Status::active) {
                return;
            }
            s.insert(
                source_id,
                Status { message: "Waiting…".into(), fraction: None, running: false, error: None, finished_at: None },
            );
        }
        crate::ui::repaint();
        let _ = self.jobs.send(Job { source_id, scope, settings: settings.clone() });
    }

    pub fn dismiss(&self, source_id: i64) {
        let mut s = self.statuses.lock();
        if s.get(&source_id).is_some_and(|v| !v.running) {
            s.remove(&source_id);
        }
    }

    /// Queues refreshes for stale playlists and guides.
    pub fn refresh_stale(&self, sources: &[crate::model::Source], settings: &Settings) {
        let now = now_secs();
        let older = |t: Option<i64>, hours: i64| t.is_none_or(|t| hours > 0 && now - t >= hours * 3600);
        for s in sources {
            let playlist_stale = s.last_refresh.is_none() || (settings.auto_refresh_hours > 0 && older(s.last_refresh, settings.auto_refresh_hours));
            let epg_stale = settings.epg_refresh_hours > 0 && older(s.last_epg, settings.epg_refresh_hours);
            if playlist_stale {
                self.enqueue(s.id, Scope::All, settings);
            } else if epg_stale && (s.epg_url.is_some() || s.kind == SourceType::Xtream) {
                self.enqueue(s.id, Scope::Epg, settings);
            }
        }
    }
}

type Report<'a> = dyn FnMut(&str, Option<f32>) + 'a;

fn run_job(db: &Db, temp_dir: &std::path::Path, statuses: &Mutex<HashMap<i64, Status>>, job: Job) {
    let id = job.source_id;
    let set = |f: &dyn Fn(&mut Status)| {
        if let Some(s) = statuses.lock().get_mut(&id) {
            f(s);
        }
        crate::ui::repaint();
    };
    set(&|s| {
        s.running = true;
        s.message = "Starting…".into();
    });
    let mut last = Instant::now() - Duration::from_secs(1);
    let mut report = |msg: &str, fraction: Option<f32>| {
        // At most ~10 updates per second.
        if last.elapsed() < Duration::from_millis(100) {
            return;
        }
        last = Instant::now();
        set(&|s| {
            s.message = msg.to_string();
            s.fraction = fraction;
        });
    };
    let started = Instant::now();
    let result = ImportJob::open(db, temp_dir, &job).and_then(|mut j| {
        let r = j.run(&mut report);
        if let Err(e) = &r {
            let _ = j.db.execute("UPDATE sources SET status='error', error=?1 WHERE id=?2", params![e, id]);
        }
        r.map(|()| j.summary())
    });
    let finished = |s: &mut Status, msg: String, err: Option<String>| {
        s.running = false;
        s.finished_at = Some(Instant::now());
        s.fraction = err.is_none().then_some(1.0);
        s.message = msg;
        s.error = err;
    };
    match result {
        Ok(summary) => {
            let msg = format!("{summary} · {:.1} s", started.elapsed().as_secs_f32());
            set(&|s| finished(s, msg.clone(), None));
        }
        Err(e) => {
            log::warn!("import {id} failed: {e}");
            set(&|s| finished(s, e.clone(), Some(e.clone())));
        }
    }
    let epg_dir = db.epg_dir.clone();
    db.write(&[Group::Sources, Group::Items, Group::Epg, Group::Favorites], move |c| {
        repo::cleanup_epg_files(c, &epg_dir)
    });
}

struct ImportJob<'a> {
    db: Connection,
    temp_dir: &'a std::path::Path,
    epg_dir: PathBuf,
    source: crate::model::Source,
    password: String,
    scope: Scope,
    settings: &'a Settings,
    agent: ureq::Agent,
    counts: [usize; 3],
    programmes: usize,
    discovered_epg: Option<String>,
}

fn sql(e: rusqlite::Error) -> String {
    format!("Database error: {e}")
}

impl<'a> ImportJob<'a> {
    fn open(db: &Db, temp_dir: &'a std::path::Path, job: &'a Job) -> Result<Self, String> {
        let c = db::open_connection(&db.path).map_err(sql)?;
        // Bulk work: bigger cache, fewer checkpoints, sorts spill to disk.
        c.execute_batch("PRAGMA wal_autocheckpoint = 10000; PRAGMA cache_size = -131072; PRAGMA temp_store = FILE;")
            .map_err(sql)?;
        let source = repo::source(&c, job.source_id).map_err(sql)?.ok_or("The playlist was removed")?;
        let password = if source.kind == SourceType::Xtream { secrets::password(source.id).unwrap_or_default() } else { String::new() };
        let ua = source.user_agent.clone().filter(|s| !s.is_empty()).or_else(|| Some(job.settings.user_agent.clone()));
        Ok(Self {
            db: c,
            temp_dir,
            epg_dir: db.epg_dir.clone(),
            agent: http::agent(ua.as_deref()),
            source,
            password,
            scope: job.scope,
            settings: &job.settings,
            counts: [0; 3],
            programmes: 0,
            discovered_epg: None,
        })
    }

    fn summary(&self) -> String {
        let mut parts = vec![];
        if self.scope != Scope::Epg {
            let [l, m, s] = self.counts;
            parts.push(format!("{l} channels, {m} movies, {s} series"));
        }
        if self.scope != Scope::Playlist {
            parts.push(format!("{} programmes", self.programmes));
        }
        parts.join(" · ")
    }

    fn xtream(&self) -> Xtream {
        Xtream::new(&self.source.url, self.source.username.as_deref().unwrap_or(""), &self.password)
    }

    fn run(&mut self, report: &mut Report) -> Result<(), String> {
        if self.scope != Scope::Epg {
            if self.source.kind == SourceType::Xtream {
                self.import_xtream(report)?;
            } else {
                self.import_m3u(report)?;
            }
            let [l, m, s] = self.counts;
            self.db
                .execute(
                    "UPDATE sources SET status='ok', error=NULL, last_refresh=?1, live_count=?2, movie_count=?3, series_count=?4 WHERE id=?5",
                    params![now_secs(), l as i64, m as i64, s as i64, self.source.id],
                )
                .map_err(sql)?;
        }
        if self.scope != Scope::Playlist
            && let Some(url) = self.epg_url()
        {
            self.import_epg(&url, report)?;
        }
        Ok(())
    }

    fn epg_url(&self) -> Option<String> {
        if let Some(u) = self.source.epg_url.as_deref().map(str::trim).filter(|s| !s.is_empty()) {
            return Some(u.to_string());
        }
        if self.source.kind == SourceType::Xtream {
            return Some(self.xtream().epg_url());
        }
        if self.discovered_epg.is_some() {
            return self.discovered_epg.clone();
        }
        let v: Option<String> =
            self.db.query_row("SELECT epg_url FROM sources WHERE id=?1", [self.source.id], |r| r.get(0)).ok().flatten();
        v.filter(|s| !s.is_empty())
    }

    // ---- M3U ------------------------------------------------------------------

    fn import_m3u(&mut self, report: &mut Report) -> Result<(), String> {
        let mut temp = None;
        let mut path = PathBuf::from(self.source.url.strip_prefix("file://").unwrap_or(&self.source.url));
        if self.source.kind == SourceType::M3uUrl {
            std::fs::create_dir_all(self.temp_dir).map_err(|e| e.to_string())?;
            let t = self.temp_dir.join(format!("playlist_{}_{}.m3u", self.source.id, now_secs()));
            report("Downloading playlist…", None);
            http::download_to_file(&self.agent, &self.source.url, &t, |r, total| {
                report(&format!("Downloading playlist… {}{}", mb(r), total.map(|t| format!(" / {}", mb(t))).unwrap_or_default()),
                    total.map(|t| r as f32 / t as f32));
            })?;
            path = t.clone();
            temp = Some(t);
        }
        let result = self.parse_m3u_file(&path, report);
        if let Some(t) = temp {
            let _ = std::fs::remove_file(t);
        }
        result
    }

    fn parse_m3u_file(&mut self, path: &std::path::Path, report: &mut Report) -> Result<(), String> {
        let file = std::fs::File::open(path).map_err(|e| format!("Cannot open {}: {e}", path.display()))?;
        let len = file.metadata().map(|m| m.len()).unwrap_or(0);
        let mut reader = BufReader::with_capacity(1 << 20, http::Counted { inner: file, read: 0 });
        report("Reading playlist…", Some(0.0));
        let mut parser = M3uParser::new();
        let mut w = ItemWriter::begin(&self.db, self.source.id)?;
        let mut line = Vec::new();
        let res: Result<(), String> = (|| {
            loop {
                line.clear();
                if reader.read_until(b'\n', &mut line).map_err(|e| e.to_string())? == 0 {
                    break;
                }
                let text = String::from_utf8_lossy(&line);
                let Some(e) = parser.add_line(&text) else { continue };
                let kind = e.kind();
                let group = e.group.clone().unwrap_or_else(|| "Uncategorized".into());
                w.add(NewItem {
                    kind,
                    category_name: Some(group.clone()),
                    key: format!("{}|{group}|{}", kind.index(), e.name),
                    logo: e.logo(),
                    url: Some(e.url.clone()),
                    epg_id: e.tvg_id(),
                    num: e.channel_number(),
                    catchup_days: e.catchup_days(),
                    headers: e.headers.clone(),
                    name: e.name,
                    ..Default::default()
                })?;
                if w.count % 5000 == 0 {
                    let read = reader.get_ref().read;
                    report(&format!("Saving {} entries…", w.count), (len > 0).then(|| read as f32 / len as f32));
                }
            }
            Ok(())
        })();
        if let Err(e) = res {
            w.abort();
            return Err(e);
        }
        if w.count == 0 {
            w.abort();
            return Err("The playlist is empty or not a valid M3U file".into());
        }
        report("Building search index…", None);
        self.counts = w.finish()?;
        self.discovered_epg = parser.epg_url.clone();
        if let Some(u) = &parser.epg_url {
            self.db
                .execute("UPDATE sources SET epg_url=?1 WHERE id=?2 AND (epg_url IS NULL OR epg_url='')", params![u, self.source.id])
                .map_err(sql)?;
        }
        Ok(())
    }

    // ---- Xtream -----------------------------------------------------------------

    fn import_xtream(&mut self, report: &mut Report) -> Result<(), String> {
        let api = self.xtream();
        report("Signing in…", None);
        let account = api.authenticate(&self.agent)?;
        self.db
            .execute(
                "UPDATE sources SET expires_at=?1, max_connections=?2 WHERE id=?3",
                params![account.expires_at, account.max_connections, self.source.id],
            )
            .map_err(sql)?;
        report("Loading categories…", Some(0.05));
        let cats = [
            api.list(&self.agent, "get_live_categories")?,
            api.list(&self.agent, "get_vod_categories")?,
            api.list(&self.agent, "get_series_categories")?,
        ];
        report("Loading live channels…", Some(0.15));
        let live = api.list(&self.agent, "get_live_streams")?;
        report("Loading movies…", Some(0.35));
        let vod = api.list(&self.agent, "get_vod_streams")?;
        report("Loading series…", Some(0.55));
        let series = api.list(&self.agent, "get_series")?;

        report(&format!("Saving {} entries…", live.len() + vod.len() + series.len()), Some(0.75));
        let mut w = ItemWriter::begin(&self.db, self.source.id)?;
        if let Err(e) = write_xtream(&mut w, &api, &self.settings.live_format, &cats, &live, &vod, &series) {
            w.abort();
            return Err(e);
        }
        report("Building search index…", Some(0.9));
        self.counts = w.finish()?;
        Ok(())
    }

    // ---- TV guide -----------------------------------------------------------------

    fn import_epg(&mut self, url: &str, report: &mut Report) -> Result<(), String> {
        let gen_: i64 = self.db.query_row("SELECT epg_gen FROM sources WHERE id=?1", [self.source.id], |r| r.get(0)).map_err(sql)?;
        let new_gen = gen_ + 1;
        let now = now_secs();
        std::fs::create_dir_all(&self.epg_dir).map_err(|e| e.to_string())?;
        let file = self.epg_dir.join(db::epg_file_name(self.source.id, new_gen));
        let _ = std::fs::remove_file(&file);

        let window = (now - self.settings.epg_past_hours * 3600, now + self.settings.epg_future_days * 86_400);
        report("Downloading TV guide…", None);
        let result = self.write_guide(&file, url, window, report);
        let names = match result {
            Ok(n) => n,
            Err(e) => {
                let _ = std::fs::remove_file(&file);
                return Err(e);
            }
        };

        // Flip to the new guide; the old file is deleted afterwards.
        report("Matching channels…", Some(0.97));
        self.db.execute_batch("BEGIN IMMEDIATE;").map_err(sql)?;
        let r = (|| {
            self.db.execute("UPDATE sources SET epg_gen=?1, last_epg=?2 WHERE id=?3", params![new_gen, now, self.source.id])?;
            self.match_channels_by_name(&names)
        })();
        match r {
            Ok(()) => self.db.execute_batch("COMMIT;").map_err(sql),
            Err(e) => {
                let _ = self.db.execute_batch("ROLLBACK;");
                Err(sql(e))
            }
        }
    }

    /// Downloads and parses on one thread while this one writes rows, so XML
    /// scanning and SQLite inserts use two cores. A bounded channel keeps
    /// memory flat whatever the guide size.
    fn write_guide(
        &mut self,
        file: &std::path::Path,
        url: &str,
        window: (i64, i64),
        report: &mut Report,
    ) -> Result<HashMap<String, Vec<String>>, String> {
        // Scratch database, invisible until the flip: no journal, no fsync.
        let g = Connection::open(file).map_err(sql)?;
        g.execute_batch(
            "PRAGMA journal_mode = OFF; PRAGMA synchronous = OFF; PRAGMA locking_mode = EXCLUSIVE; PRAGMA cache_size = -65536; PRAGMA temp_store = FILE;",
        )
        .map_err(sql)?;
        g.execute_batch(db::EPG_TABLE_DDL).map_err(sql)?;

        enum Msg {
            Batch(Vec<XmltvProgramme>),
            Progress(u64, Option<u64>),
            Done(Result<HashMap<String, Vec<String>>, String>),
        }
        let (tx, rx) = crossbeam_channel::bounded::<Msg>(8);
        let (agent, url) = (self.agent.clone(), url.to_string());
        let parser = std::thread::spawn(move || {
            let res = (|| {
                let (r, total) = http::open(&agent, &url, &[])?;
                let mut r = http::Counted { inner: r, read: 0 };
                let mut p = XmltvParser::new(window.0, window.1);
                let mut batch = Vec::with_capacity(2000);
                let mut buf = vec![0u8; 256 * 1024];
                let mut last = Instant::now();
                loop {
                    let n = r.read(&mut buf).map_err(|e| format!("Download failed: {e}"))?;
                    let mut on = |x| batch.push(x);
                    if n == 0 {
                        p.finish(&mut on);
                        break;
                    }
                    p.add(&buf[..n], &mut on);
                    if batch.len() >= 2000 && tx.send(Msg::Batch(std::mem::take(&mut batch))).is_err() {
                        return Err("Stopped".into());
                    }
                    if last.elapsed() > Duration::from_millis(100) {
                        last = Instant::now();
                        let _ = tx.send(Msg::Progress(r.read, total));
                    }
                }
                let _ = tx.send(Msg::Batch(batch));
                if p.programmes == 0 && p.channel_names.is_empty() {
                    return Err("The TV guide is empty or not valid XMLTV".into());
                }
                Ok(p.channel_names)
            })();
            let _ = tx.send(Msg::Done(res));
        });

        g.execute_batch("BEGIN;").map_err(sql)?;
        let mut names = Err("TV guide parser stopped unexpectedly".to_string());
        {
            let mut ins = g.prepare("INSERT INTO programmes VALUES (?1,?2,?3,?4,?5,?6)").map_err(sql)?;
            for msg in &rx {
                match msg {
                    Msg::Batch(rows) => {
                        for p in rows {
                            ins.execute(params![p.channel, p.start, p.stop, p.title, p.description, p.category]).map_err(sql)?;
                        }
                        self.programmes = g.last_insert_rowid() as usize;
                    }
                    Msg::Progress(bytes, total) => report(
                        &format!(
                            "Reading TV guide… {}{} · {} programmes",
                            mb(bytes),
                            total.map(|t| format!(" / {}", mb(t))).unwrap_or_default(),
                            count(self.programmes)
                        ),
                        total.map(|t| (bytes as f32 / t as f32 * 0.9).min(0.9)),
                    ),
                    Msg::Done(r) => {
                        names = r;
                        break;
                    }
                }
            }
        }
        drop(rx);
        let _ = parser.join();
        let names = names?;
        g.execute_batch("COMMIT;").map_err(sql)?;
        report(&format!("Indexing {} programmes…", count(self.programmes)), Some(0.92));
        g.execute_batch(db::EPG_INDEX_DDL).map_err(sql)?;
        g.execute_batch("ANALYZE;").map_err(sql)?;
        Ok(names)
    }

    /// Fills `epg_id` for channels without a known one by matching normalised
    /// names against the guide's display names.
    fn match_channels_by_name(&self, names: &HashMap<String, Vec<String>>) -> rusqlite::Result<()> {
        if names.is_empty() {
            return Ok(());
        }
        let mut by_name: HashMap<String, &String> = HashMap::new();
        for (id, list) in names {
            for n in list.iter().chain(std::iter::once(id)) {
                let k = normalize_channel_name(n);
                if !k.is_empty() {
                    by_name.entry(k).or_insert(id);
                }
            }
        }
        let rows: Vec<(i64, String, Option<String>)> = self
            .db
            .prepare("SELECT id, name, epg_id FROM items WHERE source_id=?1 AND kind=0")?
            .query_map([self.source.id], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)))?
            .collect::<rusqlite::Result<_>>()?;
        let mut upd = self.db.prepare("UPDATE items SET epg_id=?1 WHERE id=?2")?;
        for (id, name, current) in rows {
            if current.as_ref().is_some_and(|c| names.contains_key(c)) {
                continue;
            }
            if let Some(m) = by_name.get(&normalize_channel_name(&name))
                && current.as_deref() != Some(m.as_str())
            {
                upd.execute(params![m, id])?;
            }
        }
        Ok(())
    }
}

fn write_xtream(
    w: &mut ItemWriter,
    api: &Xtream,
    live_format: &str,
    cats: &[Vec<Map<String, Value>>; 3],
    live: &[Map<String, Value>],
    vod: &[Map<String, Value>],
    series: &[Map<String, Value>],
) -> Result<(), String> {
    for (kind, list) in ItemKind::ALL.iter().zip(cats) {
        for c in list {
            if let Some(id) = str_of(c.get("category_id")) {
                w.category(*kind, &id, &str_of(c.get("category_name")).unwrap_or_else(|| "Unnamed".into()))?;
            }
        }
    }
    let ext = if live_format == "m3u8" { "m3u8" } else { "ts" };
    for s in live {
        let Some(id) = str_of(s.get("stream_id")) else { continue };
        w.add(NewItem {
            kind: ItemKind::Live,
            category_ext_id: str_of(s.get("category_id")),
            key: format!("x:{id}"),
            name: str_of(s.get("name")).unwrap_or_else(|| format!("Channel {id}")),
            logo: str_of(s.get("stream_icon")),
            url: Some(api.live_url(&id, ext)),
            epg_id: str_of(s.get("epg_channel_id")),
            num: int_of(s.get("num")),
            catchup_days: (int_of(s.get("tv_archive")) == Some(1)).then(|| int_of(s.get("tv_archive_duration"))).flatten(),
            added_at: int_of(s.get("added")),
            ext_id: Some(id),
            ..Default::default()
        })?;
    }
    for s in vod {
        let Some(id) = str_of(s.get("stream_id")) else { continue };
        let ext = str_of(s.get("container_extension")).unwrap_or_else(|| "mp4".into());
        w.add(NewItem {
            kind: ItemKind::Movie,
            category_ext_id: str_of(s.get("category_id")),
            key: format!("x:{id}"),
            name: str_of(s.get("name")).unwrap_or_else(|| format!("Movie {id}")),
            logo: str_of(s.get("stream_icon")),
            url: Some(api.movie_url(&id, &ext)),
            rating: f64_of(s.get("rating")),
            year: str_of(s.get("year")),
            added_at: int_of(s.get("added")),
            container: Some(ext),
            ext_id: Some(id),
            ..Default::default()
        })?;
    }
    for s in series {
        let Some(id) = str_of(s.get("series_id")) else { continue };
        w.add(NewItem {
            kind: ItemKind::Series,
            category_ext_id: str_of(s.get("category_id")),
            key: format!("x:{id}"),
            name: str_of(s.get("name")).unwrap_or_else(|| format!("Series {id}")),
            logo: str_of(s.get("cover")),
            rating: f64_of(s.get("rating")),
            year: str_of(s.get("releaseDate"))
                .map(|d| d.split('-').next().unwrap_or("").to_string())
                .or_else(|| str_of(s.get("year"))),
            added_at: int_of(s.get("last_modified")),
            ext_id: Some(id),
            ..Default::default()
        })?;
    }
    Ok(())
}

fn mb(bytes: u64) -> String {
    format!("{:.1} MB", bytes as f64 / (1024.0 * 1024.0))
}

fn count(n: usize) -> String {
    if n >= 1000 { format!("{}k", n / 1000) } else { n.to_string() }
}

#[derive(Default)]
struct NewItem {
    kind: ItemKind,
    key: String,
    name: String,
    category_name: Option<String>,
    category_ext_id: Option<String>,
    logo: Option<String>,
    url: Option<String>,
    epg_id: Option<String>,
    num: Option<i64>,
    ext_id: Option<String>,
    container: Option<String>,
    rating: Option<f64>,
    year: Option<String>,
    added_at: Option<i64>,
    catchup_days: Option<i64>,
    headers: BTreeMap<String, String>,
}

/// Replaces a playlist's categories and items in one transaction (readers
/// keep the old snapshot until it commits).
struct ItemWriter<'c> {
    db: &'c Connection,
    source_id: i64,
    cat_ids: HashMap<(i64, String), i64>,
    counts: [usize; 3],
    count: usize,
    cat_sort: i64,
}

impl<'c> ItemWriter<'c> {
    fn begin(db: &'c Connection, source_id: i64) -> Result<Self, String> {
        db.execute_batch("BEGIN IMMEDIATE;").map_err(sql)?;
        let w = Self { db, source_id, cat_ids: HashMap::new(), counts: [0; 3], count: 0, cat_sort: 0 };
        let r = (|| {
            // Keep the search index in step with the deleted rows.
            db.execute(
                "INSERT INTO items_fts(items_fts, rowid, name) SELECT 'delete', id, name FROM items WHERE source_id=?1",
                [source_id],
            )?;
            db.execute("DELETE FROM items WHERE source_id=?1", [source_id])?;
            db.execute("DELETE FROM categories WHERE source_id=?1", [source_id])
        })();
        if let Err(e) = r {
            w.abort();
            return Err(sql(e));
        }
        Ok(w)
    }

    fn category(&mut self, kind: ItemKind, ext_id: &str, name: &str) -> Result<i64, String> {
        let k = (kind.index(), ext_id.to_string());
        if let Some(id) = self.cat_ids.get(&k) {
            return Ok(*id);
        }
        self.db
            .prepare_cached("INSERT INTO categories (source_id, kind, ext_id, name, sort) VALUES (?1,?2,?3,?4,?5)")
            .and_then(|mut s| s.execute(params![self.source_id, kind.index(), ext_id, name, self.cat_sort]))
            .map_err(sql)?;
        self.cat_sort += 1;
        let id = self.db.last_insert_rowid();
        self.cat_ids.insert(k, id);
        Ok(id)
    }

    fn add(&mut self, it: NewItem) -> Result<(), String> {
        let cat = match (&it.category_name, &it.category_ext_id) {
            (Some(name), _) => self.category(it.kind, name, name)?,
            (None, Some(ext)) => match self.cat_ids.get(&(it.kind.index(), ext.clone())) {
                Some(id) => *id,
                None => self.category(it.kind, ext, "Other")?,
            },
            (None, None) => self.category(it.kind, "__none", "Uncategorized")?,
        };
        let headers = (!it.headers.is_empty()).then(|| serde_json::to_string(&it.headers).unwrap_or_default());
        self.db
            .prepare_cached(
                "INSERT INTO items (source_id, kind, category_id, key, name, logo, url, epg_id, num, ext_id, container, \
                 rating, year, added_at, catchup_days, headers, sort) VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17)",
            )
            .and_then(|mut s| {
                s.execute(params![
                    self.source_id,
                    it.kind.index(),
                    cat,
                    it.key,
                    it.name,
                    it.logo,
                    it.url,
                    it.epg_id,
                    it.num,
                    it.ext_id,
                    it.container,
                    it.rating,
                    it.year,
                    it.added_at,
                    it.catchup_days,
                    headers,
                    self.count as i64
                ])
            })
            .map_err(sql)?;
        self.count += 1;
        self.counts[it.kind.index() as usize] += 1;
        Ok(())
    }

    fn abort(&self) {
        let _ = self.db.execute_batch("ROLLBACK;");
    }

    fn finish(self) -> Result<[usize; 3], String> {
        let r = self.db.execute_batch(&format!(
            "UPDATE categories SET item_count = (SELECT COUNT(*) FROM items i WHERE i.category_id = categories.id) WHERE source_id={id};
             DELETE FROM categories WHERE source_id={id} AND item_count=0;
             INSERT INTO items_fts(rowid, name) SELECT id, name FROM items WHERE source_id={id};
             COMMIT;",
            id = self.source_id
        ));
        if let Err(e) = r {
            self.abort();
            return Err(sql(e));
        }
        Ok(self.counts)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp(name: &str) -> PathBuf {
        let d = std::env::temp_dir().join(format!("catplay-test-{name}-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&d);
        std::fs::create_dir_all(&d).unwrap();
        d
    }

    #[test]
    fn imports_m3u_file_with_guide() {
        let dir = temp("import");
        let now = now_secs();
        let fmt = |t: i64| chrono::DateTime::from_timestamp(t, 0).unwrap().format("%Y%m%d%H%M%S +0000").to_string();
        let guide = dir.join("guide.xml");
        std::fs::write(
            &guide,
            format!(
                r#"<tv><channel id="one.uk"><display-name>Channel One</display-name></channel>
<programme start="{}" stop="{}" channel="one.uk"><title>Now</title></programme></tv>"#,
                fmt(now - 600),
                fmt(now + 600)
            ),
        )
        .unwrap();
        let list = dir.join("list.m3u");
        let mut f = std::fs::File::create(&list).unwrap();
        writeln!(f, "#EXTM3U url-tvg=\"{}\"", guide.display()).unwrap();
        writeln!(f, "#EXTINF:-1 group-title=\"News\",UK: Channel One HD\nhttp://a/1.ts").unwrap();
        writeln!(f, "#EXTINF:-1 group-title=\"Films\",Film\nhttp://a/movie/1.mkv").unwrap();
        drop(f);

        let db = Db::open(dir.join("iptv.db"), dir.join("epg")).unwrap();
        let form = repo::SourceForm { name: "T".into(), url: list.display().to_string(), ..Default::default() };
        let id = db.write(&[], move |c| repo::add_source(c, SourceType::M3uFile, &form));
        while !id.is_done() {
            std::thread::sleep(Duration::from_millis(5));
        }
        let id = id.take().unwrap().unwrap();
        let importer = Importer::new(db.clone(), dir.join("tmp"));
        importer.enqueue(id, Scope::All, &Settings::default());
        while importer.is_active(id) {
            std::thread::sleep(Duration::from_millis(20));
        }
        let st = importer.statuses();
        assert_eq!(st[&id].error, None, "{}", st[&id].message);

        let c = db::open_connection(&db.path).unwrap();
        let src = repo::source(&c, id).unwrap().unwrap();
        assert_eq!((src.live_count, src.movie_count, src.status.as_str()), (1, 1, "ok"));
        let q = repo::ItemQuery::new(ItemKind::Live, id);
        let ch = &repo::items(&c, &q, 0, 1).unwrap()[0];
        assert_eq!(ch.epg_id.as_deref(), Some("one.uk"), "matched by name");
        let nn = repo::now_next(&c, &db.epg_dir, id, &["one.uk".into()], now).unwrap();
        assert_eq!(nn["one.uk"][0].title, "Now");
        assert_eq!(repo::search(&c, "chan", None, None, 5).unwrap().len(), 1);

        // Re-import replaces rows and keeps the search index consistent.
        importer.enqueue(id, Scope::Playlist, &Settings::default());
        while importer.is_active(id) {
            std::thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(repo::search(&c, "chan", None, None, 5).unwrap().len(), 1);
        let _ = std::fs::remove_dir_all(dir);
    }
}
