//! SQLite database: the schema (identical to the Flutter app's, so both read
//! the same file) and background worker threads that run every query, so the
//! UI thread never waits on disk.
//!
//! Reads go to a small pool of connections. Writes go to their own thread,
//! because an import can hold the write lock for a while (WAL mode lets reads
//! continue meanwhile).

use crossbeam_channel::{Receiver, Sender, unbounded};
use parking_lot::Mutex;
use rusqlite::{Connection, OpenFlags};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

/// Bump when the schema changes, and add a migration step in [`migrate`].
pub const SCHEMA_VERSION: i64 = 1;

pub type DbResult<T> = Result<T, String>;

pub fn configure(c: &Connection) -> rusqlite::Result<()> {
    c.execute_batch(
        "PRAGMA journal_mode = WAL;
         PRAGMA synchronous = NORMAL;
         PRAGMA foreign_keys = ON;
         PRAGMA busy_timeout = 10000;
         PRAGMA temp_store = MEMORY;
         PRAGMA cache_size = -32000;",
    )
}

pub fn open_connection(path: &Path) -> rusqlite::Result<Connection> {
    let c = Connection::open(path)?;
    configure(&c)?;
    Ok(c)
}

/// Opens a guide file read-only. Opened per query, so a replaced guide file
/// can be deleted right away (Windows refuses to delete open files).
pub fn open_epg(path: &Path) -> rusqlite::Result<Connection> {
    let c = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY | OpenFlags::SQLITE_OPEN_NO_MUTEX)?;
    c.execute_batch("PRAGMA query_only = ON;")?;
    Ok(c)
}

/// TV guide programmes live outside the main database, one SQLite file per
/// source and guide generation. A refresh writes a new file, then flips
/// `sources.epg_gen`; dropping an old guide is a file delete.
pub fn epg_file_name(source_id: i64, gen_: i64) -> String {
    format!("epg_{source_id}_g{gen_}.db")
}

pub fn parse_epg_file_name(name: &str) -> Option<(i64, i64)> {
    let rest = name.strip_prefix("epg_")?.strip_suffix(".db")?;
    let (sid, g) = rest.split_once("_g")?;
    Some((sid.parse().ok()?, g.parse().ok()?))
}

pub const EPG_TABLE_DDL: &str = "CREATE TABLE programmes (
    channel  TEXT    NOT NULL,
    start    INTEGER NOT NULL,
    stop     INTEGER NOT NULL,
    title    TEXT    NOT NULL,
    descr    TEXT,
    category TEXT
);";

pub const EPG_INDEX_DDL: &str = "CREATE INDEX idx_programmes ON programmes(channel, start);";

pub fn migrate(c: &Connection) -> rusqlite::Result<()> {
    let current: i64 = c.query_row("PRAGMA user_version", [], |r| r.get(0))?;
    if current >= SCHEMA_VERSION {
        return Ok(());
    }
    c.execute_batch("BEGIN;")?;
    let result = (|| {
        if current < 1 {
            c.execute_batch(V1)?;
        }
        c.execute_batch(&format!("PRAGMA user_version = {SCHEMA_VERSION};"))
    })();
    match result {
        Ok(()) => c.execute_batch("COMMIT;"),
        Err(e) => {
            let _ = c.execute_batch("ROLLBACK;");
            Err(e)
        }
    }
}

const V1: &str = "
CREATE TABLE sources (
  id            INTEGER PRIMARY KEY,
  name          TEXT    NOT NULL,
  type          TEXT    NOT NULL,
  url           TEXT    NOT NULL,
  username      TEXT,
  epg_url       TEXT,
  user_agent    TEXT,
  created_at    INTEGER NOT NULL,
  last_refresh  INTEGER,
  last_epg      INTEGER,
  epg_gen       INTEGER NOT NULL DEFAULT 0,
  status        TEXT    NOT NULL DEFAULT 'new',
  error         TEXT,
  live_count    INTEGER NOT NULL DEFAULT 0,
  movie_count   INTEGER NOT NULL DEFAULT 0,
  series_count  INTEGER NOT NULL DEFAULT 0,
  expires_at    INTEGER,
  max_connections INTEGER
);
CREATE TABLE categories (
  id         INTEGER PRIMARY KEY,
  source_id  INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  kind       INTEGER NOT NULL,
  ext_id     TEXT    NOT NULL,
  name       TEXT    NOT NULL,
  sort       INTEGER NOT NULL,
  item_count INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX idx_categories_source ON categories(source_id, kind, sort);
CREATE TABLE items (
  id          INTEGER PRIMARY KEY,
  source_id   INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  kind        INTEGER NOT NULL,
  category_id INTEGER,
  key         TEXT    NOT NULL,
  name        TEXT    NOT NULL,
  logo        TEXT,
  url         TEXT,
  epg_id      TEXT,
  num         INTEGER,
  ext_id      TEXT,
  container   TEXT,
  rating      REAL,
  year        TEXT,
  added_at    INTEGER,
  catchup_days INTEGER,
  headers     TEXT,
  sort        INTEGER NOT NULL
);
CREATE INDEX idx_items_cat ON items(category_id, sort);
CREATE INDEX idx_items_source_kind ON items(source_id, kind, sort);
CREATE INDEX idx_items_key ON items(source_id, key);
CREATE INDEX idx_items_epg ON items(source_id, epg_id);
CREATE VIRTUAL TABLE items_fts USING fts5(
  name,
  content='items',
  content_rowid='id',
  tokenize='unicode61 remove_diacritics 2',
  prefix='2 3'
);
CREATE TABLE favorites (
  source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  key       TEXT    NOT NULL,
  kind      INTEGER NOT NULL,
  added_at  INTEGER NOT NULL,
  PRIMARY KEY (source_id, key)
) WITHOUT ROWID;
CREATE TABLE history (
  source_id   INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
  key         TEXT    NOT NULL,
  kind        INTEGER NOT NULL,
  name        TEXT    NOT NULL,
  logo        TEXT,
  url         TEXT    NOT NULL,
  position_ms INTEGER NOT NULL DEFAULT 0,
  duration_ms INTEGER NOT NULL DEFAULT 0,
  updated_at  INTEGER NOT NULL,
  PRIMARY KEY (source_id, key)
) WITHOUT ROWID;
CREATE INDEX idx_history_updated ON history(updated_at DESC);
CREATE TABLE settings (
  key   TEXT PRIMARY KEY,
  value TEXT NOT NULL
) WITHOUT ROWID;
";

// ---- change tracking ---------------------------------------------------------

/// Groups of tables a write can touch; pages reload when a group they show
/// changes.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Group {
    Sources = 0,
    Items = 1,
    Favorites = 2,
    History = 3,
    Epg = 4,
}

#[derive(Default)]
pub struct Versions([AtomicU64; 5]);

impl Versions {
    pub fn bump(&self, groups: &[Group]) {
        for g in groups {
            self.0[*g as usize].fetch_add(1, Ordering::Relaxed);
        }
        crate::ui::repaint();
    }

    pub fn get(&self, g: Group) -> u64 {
        self.0[g as usize].load(Ordering::Relaxed)
    }
}

// ---- tasks -------------------------------------------------------------------

/// Result of background work, polled by the UI each frame.
pub struct Task<T>(Arc<Mutex<Option<DbResult<T>>>>);

impl<T> Clone for Task<T> {
    fn clone(&self) -> Self {
        Self(self.0.clone())
    }
}

impl<T> Task<T> {
    pub fn pending() -> (Self, impl FnOnce(DbResult<T>)) {
        let slot = Arc::new(Mutex::new(None));
        let fill = slot.clone();
        (Self(slot), move |v| {
            *fill.lock() = Some(v);
            crate::ui::repaint();
        })
    }

    pub fn is_done(&self) -> bool {
        self.0.lock().is_some()
    }

    /// Takes the result once it is there.
    pub fn take(&self) -> Option<DbResult<T>> {
        self.0.lock().take()
    }
}

/// Runs `f` on a new thread (network calls, credential store).
pub fn background<T: Send + 'static>(f: impl FnOnce() -> DbResult<T> + Send + 'static) -> Task<T> {
    let (task, fill) = Task::pending();
    std::thread::spawn(move || fill(f()));
    task
}

type Job = Box<dyn FnOnce(&Connection) + Send>;

/// Handle to the database workers. Cheap to clone.
#[derive(Clone)]
pub struct Db {
    pub path: PathBuf,
    pub epg_dir: PathBuf,
    reads: Sender<Job>,
    writes: Sender<Job>,
    pub versions: Arc<Versions>,
}

impl Db {
    pub fn open(path: PathBuf, epg_dir: PathBuf) -> DbResult<Self> {
        let first = open_connection(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        migrate(&first).map_err(|e| e.to_string())?;
        let (reads, read_rx) = unbounded::<Job>();
        let (writes, write_rx) = unbounded::<Job>();
        spawn_worker("db-write", first, write_rx);
        for i in 0..2 {
            let c = open_connection(&path).map_err(|e| e.to_string())?;
            spawn_worker(&format!("db-read-{i}"), c, read_rx.clone());
        }
        Ok(Self { path, epg_dir, reads, writes, versions: Arc::default() })
    }

    /// Runs a query on a reader connection.
    pub fn read<T: Send + 'static>(
        &self,
        f: impl FnOnce(&Connection) -> rusqlite::Result<T> + Send + 'static,
    ) -> Task<T> {
        let (task, fill) = Task::pending();
        let _ = self.reads.send(Box::new(move |c| fill(f(c).map_err(|e| e.to_string()))));
        task
    }

    /// Runs a write, then marks `touches` as changed.
    pub fn write<T: Send + 'static>(
        &self,
        touches: &'static [Group],
        f: impl FnOnce(&Connection) -> rusqlite::Result<T> + Send + 'static,
    ) -> Task<T> {
        let (task, fill) = Task::pending();
        let versions = self.versions.clone();
        let _ = self.writes.send(Box::new(move |c| {
            let r = f(c).map_err(|e| e.to_string());
            if r.is_ok() {
                versions.bump(touches);
            }
            fill(r);
        }));
        task
    }

}

fn spawn_worker(name: &str, conn: Connection, jobs: Receiver<Job>) {
    std::thread::Builder::new()
        .name(name.into())
        .spawn(move || {
            for job in jobs {
                job(&conn);
            }
        })
        .expect("spawn database worker");
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn epg_file_names_round_trip() {
        assert_eq!(parse_epg_file_name(&epg_file_name(12, 3)), Some((12, 3)));
        assert_eq!(parse_epg_file_name("epg_x_g1.db"), None);
        assert_eq!(parse_epg_file_name("other.db"), None);
    }

    #[test]
    fn schema_creates_and_fts_works() {
        let c = Connection::open_in_memory().unwrap();
        migrate(&c).unwrap();
        migrate(&c).unwrap();
        c.execute_batch(
            "INSERT INTO sources (name,type,url,created_at) VALUES ('a','m3u_url','x',0);
             INSERT INTO items (source_id,kind,key,name,sort) VALUES (1,0,'k','BBC One HD',0);
             INSERT INTO items_fts(items_fts) VALUES('rebuild');",
        )
        .unwrap();
        let n: i64 = c
            .query_row("SELECT COUNT(*) FROM items_fts WHERE items_fts MATCH '\"bb\"*'", [], |r| r.get(0))
            .unwrap();
        assert_eq!(n, 1);
    }
}
