import 'package:sqlite3/sqlite3.dart';

/// Bump when the schema changes and add a migration step in [migrate].
const int schemaVersion = 1;

/// Pragmas applied to every connection (UI worker and import isolates).
void configureConnection(Database db) {
  db.execute('PRAGMA journal_mode = WAL;');
  db.execute('PRAGMA synchronous = NORMAL;');
  db.execute('PRAGMA foreign_keys = ON;');
  db.execute('PRAGMA busy_timeout = 10000;');
  db.execute('PRAGMA temp_store = MEMORY;');
  db.execute('PRAGMA cache_size = -32000;'); // ~32 MB page cache
}

/// EPG programmes live outside the main database, in one SQLite file per
/// source and guide generation: `<epgDir>/epg_<source>_g<gen>.db`.
///
/// A refresh writes a brand-new file (no journal, no fsync, one
/// transaction), indexes it in a single sorted pass, then flips
/// `sources.epg_gen`. Readers keep using the previous file until the flip,
/// the main DB's write lock is never held during the bulk load, and dropping
/// an old guide is a file delete instead of deleting millions of rows.
String epgFileName(int sourceId, int gen) => 'epg_${sourceId}_g$gen.db';

final epgFilePattern = RegExp(r'^epg_(\d+)_g(\d+)\.db$');

const epgTableDdl = '''
  CREATE TABLE programmes (
    channel  TEXT    NOT NULL,
    start    INTEGER NOT NULL,   -- unix seconds UTC
    stop     INTEGER NOT NULL,
    title    TEXT    NOT NULL,
    descr    TEXT,
    category TEXT
  );
''';

const epgIndexDdl =
    'CREATE INDEX idx_programmes ON programmes(channel, start);';

void migrate(Database db) {
  final current = db.select('PRAGMA user_version;').first.values.first as int;
  if (current >= schemaVersion) return;

  db.execute('BEGIN;');
  try {
    if (current < 1) _v1(db);
    db.execute('PRAGMA user_version = $schemaVersion;');
    db.execute('COMMIT;');
  } catch (_) {
    db.execute('ROLLBACK;');
    rethrow;
  }
}

void _v1(Database db) {
  db.execute('''
    CREATE TABLE sources (
      id            INTEGER PRIMARY KEY,
      name          TEXT    NOT NULL,
      type          TEXT    NOT NULL,           -- m3u_url | m3u_file | xtream
      url           TEXT    NOT NULL,           -- playlist url / file path / xtream server
      username      TEXT,
      epg_url       TEXT,
      user_agent    TEXT,
      created_at    INTEGER NOT NULL,
      last_refresh  INTEGER,
      last_epg      INTEGER,
      epg_gen       INTEGER NOT NULL DEFAULT 0,
      status        TEXT    NOT NULL DEFAULT 'new', -- new | ok | error
      error         TEXT,
      live_count    INTEGER NOT NULL DEFAULT 0,
      movie_count   INTEGER NOT NULL DEFAULT 0,
      series_count  INTEGER NOT NULL DEFAULT 0,
      expires_at    INTEGER,
      max_connections INTEGER
    );
  ''');

  db.execute('''
    CREATE TABLE categories (
      id         INTEGER PRIMARY KEY,
      source_id  INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
      kind       INTEGER NOT NULL,              -- 0 live, 1 movie, 2 series
      ext_id     TEXT    NOT NULL,
      name       TEXT    NOT NULL,
      sort       INTEGER NOT NULL,
      item_count INTEGER NOT NULL DEFAULT 0
    );
  ''');
  db.execute(
      'CREATE INDEX idx_categories_source ON categories(source_id, kind, sort);');

  // One table for live channels, movies and series.
  // `key` is stable across refreshes so favorites/history survive re-imports.
  db.execute('''
    CREATE TABLE items (
      id          INTEGER PRIMARY KEY,
      source_id   INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
      kind        INTEGER NOT NULL,
      category_id INTEGER,
      key         TEXT    NOT NULL,
      name        TEXT    NOT NULL,
      logo        TEXT,
      url         TEXT,                         -- null for series (episodes fetched on demand)
      epg_id      TEXT,
      num         INTEGER,
      ext_id      TEXT,
      container   TEXT,
      rating      REAL,
      year        TEXT,
      added_at    INTEGER,
      catchup_days INTEGER,
      headers     TEXT,                         -- JSON map (user-agent, referrer)
      sort        INTEGER NOT NULL
    );
  ''');
  db.execute(
      'CREATE INDEX idx_items_cat ON items(category_id, sort);');
  db.execute(
      'CREATE INDEX idx_items_source_kind ON items(source_id, kind, sort);');
  db.execute('CREATE INDEX idx_items_key ON items(source_id, key);');
  db.execute('CREATE INDEX idx_items_epg ON items(source_id, epg_id);');

  // External-content FTS index; rebuilt after every import.
  db.execute('''
    CREATE VIRTUAL TABLE items_fts USING fts5(
      name,
      content='items',
      content_rowid='id',
      tokenize='unicode61 remove_diacritics 2',
      prefix='2 3'
    );
  ''');

  db.execute('''
    CREATE TABLE favorites (
      source_id INTEGER NOT NULL REFERENCES sources(id) ON DELETE CASCADE,
      key       TEXT    NOT NULL,
      kind      INTEGER NOT NULL,
      added_at  INTEGER NOT NULL,
      PRIMARY KEY (source_id, key)
    ) WITHOUT ROWID;
  ''');

  db.execute('''
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
  ''');
  db.execute('CREATE INDEX idx_history_updated ON history(updated_at DESC);');

  // EPG programmes live in per-source, per-generation tables created by the
  // importer (see [epgTable]); `sources.epg_gen` names the live one.

  db.execute('''
    CREATE TABLE settings (
      key   TEXT PRIMARY KEY,
      value TEXT NOT NULL
    ) WITHOUT ROWID;
  ''');
}
