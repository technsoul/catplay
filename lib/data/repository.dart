import 'dart:io';

import 'package:path/path.dart' as p;

import '../core/db/database.dart';
import '../core/db/schema.dart' show epgFileName, epgFilePattern;
import '../core/models.dart';
import '../core/settings.dart';

enum ItemSort { playlist, name, added, rating }

/// Which items a list shows.
class ItemQuery {
  const ItemQuery({
    required this.kind,
    this.sourceId,
    this.categoryId,
    this.favoritesOnly = false,
    this.sort = ItemSort.playlist,
  });

  final ItemKind kind;
  final int? sourceId;
  final int? categoryId; // null = all
  final bool favoritesOnly;
  final ItemSort sort;

  @override
  bool operator ==(Object other) =>
      other is ItemQuery &&
      other.kind == kind &&
      other.sourceId == sourceId &&
      other.categoryId == categoryId &&
      other.favoritesOnly == favoritesOnly &&
      other.sort == sort;

  @override
  int get hashCode => Object.hash(kind, sourceId, categoryId, favoritesOnly, sort);
}

/// All SQL lives here. Every call runs on the DB worker isolate.
class Repository {
  Repository(this.db, {required this.epgDir});

  final AppDatabase db;
  final String epgDir;

  static int _secs(DateTime t) => t.millisecondsSinceEpoch ~/ 1000;
  static int get _nowSecs => _secs(DateTime.now());

  // ------------------------------------------------------------ settings

  Future<AppSettings> loadSettings() async {
    final r = await db.selectOne("SELECT value FROM settings WHERE key='app'");
    return AppSettings.decode(r?['value'] as String?);
  }

  Future<void> saveSettings(AppSettings s) => db.execute(
      "INSERT INTO settings (key, value) VALUES ('app', ?) "
      'ON CONFLICT(key) DO UPDATE SET value=excluded.value',
      [s.encode()]);

  // ------------------------------------------------------------ sources

  Future<List<Source>> sources() async =>
      (await db.select('SELECT * FROM sources ORDER BY id')).map(Source.fromRow).toList();

  Future<Source?> source(int id) async {
    final r = await db.selectOne('SELECT * FROM sources WHERE id=?', [id]);
    return r == null ? null : Source.fromRow(r);
  }

  Future<int> addSource({
    required String name,
    required SourceType type,
    required String url,
    String? username,
    String? epgUrl,
    String? userAgent,
  }) =>
      db.insert(
        'INSERT INTO sources (name, type, url, username, epg_url, user_agent, created_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?)',
        [name, type.id, url, username, _blank(epgUrl), _blank(userAgent), _nowSecs],
        touches: {'sources'},
      );

  Future<void> updateSource(
    int id, {
    required String name,
    required String url,
    String? username,
    String? epgUrl,
    String? userAgent,
  }) =>
      db.execute(
        'UPDATE sources SET name=?, url=?, username=?, epg_url=?, user_agent=? WHERE id=?',
        [name, url, username, _blank(epgUrl), _blank(userAgent), id],
        {'sources'},
      );

  Future<void> deleteSource(int id) async {
    // FTS is external-content: remove rows from the index before deleting.
    await db.execute(
        "INSERT INTO items_fts(items_fts, rowid, name) SELECT 'delete', id, name FROM items WHERE source_id=?",
        [id]);
    await db.execute('DELETE FROM sources WHERE id=?', [id],
        {'sources', 'items', 'favorites', 'history', 'epg'});
    await cleanupEpgFiles();
  }

  static String? _blank(String? s) =>
      (s == null || s.trim().isEmpty) ? null : s.trim();

  // ------------------------------------------------------------ categories

  Future<List<Category>> categories(int sourceId, ItemKind kind) async => (await db.select(
          'SELECT * FROM categories WHERE source_id=? AND kind=? ORDER BY sort',
          [sourceId, kind.index]))
      .map(Category.fromRow)
      .toList();

  // ------------------------------------------------------------ items

  static const _itemCols =
      'i.id, i.source_id, i.kind, i.category_id, i.key, i.name, i.logo, i.url, '
      'i.epg_id, i.num, i.ext_id, i.container, i.rating, i.year, i.catchup_days, i.headers';

  (String, List<Object?>) _where(ItemQuery q) {
    final w = <String>['i.kind=?'];
    final p = <Object?>[q.kind.index];
    if (q.sourceId != null) {
      w.add('i.source_id=?');
      p.add(q.sourceId);
    }
    if (q.categoryId != null) {
      w.add('i.category_id=?');
      p.add(q.categoryId);
    }
    if (q.favoritesOnly) w.add('f.key IS NOT NULL');
    return (w.join(' AND '), p);
  }

  String _order(ItemSort s) => switch (s) {
        ItemSort.playlist => 'i.sort',
        ItemSort.name => 'i.name COLLATE NOCASE',
        ItemSort.added => 'i.added_at DESC NULLS LAST, i.sort',
        ItemSort.rating => 'i.rating DESC NULLS LAST, i.sort',
      };

  Future<int> countItems(ItemQuery q) async {
    final (w, p) = _where(q);
    final join = q.favoritesOnly
        ? 'JOIN favorites f ON f.source_id=i.source_id AND f.key=i.key'
        : '';
    final r = await db.selectOne('SELECT COUNT(*) n FROM items i $join WHERE $w', p);
    return r!['n'] as int;
  }

  Future<List<MediaItem>> items(ItemQuery q, {int offset = 0, int limit = 100}) async {
    final (w, p) = _where(q);
    final join = q.favoritesOnly ? 'JOIN' : 'LEFT JOIN';
    final rows = await db.select(
      'SELECT $_itemCols, (f.key IS NOT NULL) fav FROM items i '
      '$join favorites f ON f.source_id=i.source_id AND f.key=i.key '
      'WHERE $w ORDER BY ${_order(q.sort)} LIMIT ? OFFSET ?',
      [...p, limit, offset],
    );
    return rows.map(MediaItem.fromRow).toList();
  }

  Future<MediaItem?> itemByKey(int sourceId, String key) async {
    final r = await db.selectOne(
      'SELECT $_itemCols, (f.key IS NOT NULL) fav FROM items i '
      'LEFT JOIN favorites f ON f.source_id=i.source_id AND f.key=i.key '
      'WHERE i.source_id=? AND i.key=? LIMIT 1',
      [sourceId, key],
    );
    return r == null ? null : MediaItem.fromRow(r);
  }

  /// Item at [index] of a list query, wrapping around (channel zapping).
  Future<MediaItem?> itemAt(ItemQuery q, int index) async {
    final total = await countItems(q);
    if (total == 0) return null;
    final i = ((index % total) + total) % total;
    final list = await items(q, offset: i, limit: 1);
    return list.isEmpty ? null : list.first;
  }

  /// Full-text search. Each word is a prefix match; all words must match.
  Future<List<MediaItem>> search(String text,
      {ItemKind? kind, int? sourceId, int limit = 200}) async {
    final tokens = text
        .toLowerCase()
        .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
        .where((t) => t.isNotEmpty)
        .toList();
    if (tokens.isEmpty) return const [];
    final match = tokens.map((t) => '"${t.replaceAll('"', '')}"*').join(' ');
    final w = <String>['items_fts MATCH ?'];
    final p = <Object?>[match];
    if (kind != null) {
      w.add('i.kind=?');
      p.add(kind.index);
    }
    if (sourceId != null) {
      w.add('i.source_id=?');
      p.add(sourceId);
    }
    final rows = await db.select(
      'SELECT $_itemCols, (f.key IS NOT NULL) fav FROM items_fts '
      'JOIN items i ON i.id = items_fts.rowid '
      'LEFT JOIN favorites f ON f.source_id=i.source_id AND f.key=i.key '
      'WHERE ${w.join(' AND ')} ORDER BY rank LIMIT ?',
      [...p, limit],
    );
    return rows.map(MediaItem.fromRow).toList();
  }

  // ------------------------------------------------------------ favorites

  Future<bool> toggleFavorite(MediaItem item) async {
    final removed = await db.execute(
        'DELETE FROM favorites WHERE source_id=? AND key=?',
        [item.sourceId, item.key],
        {'favorites'});
    if (removed > 0) return false;
    await db.execute(
        'INSERT INTO favorites (source_id, key, kind, added_at) VALUES (?, ?, ?, ?)',
        [item.sourceId, item.key, item.kind.index, _nowSecs],
        {'favorites'});
    return true;
  }

  // ------------------------------------------------------------ history

  Future<void> saveProgress(Playable p, Duration position, Duration duration) =>
      db.execute(
        'INSERT INTO history (source_id, key, kind, name, logo, url, position_ms, duration_ms, updated_at) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?) '
        'ON CONFLICT(source_id, key) DO UPDATE SET position_ms=excluded.position_ms, '
        'duration_ms=excluded.duration_ms, updated_at=excluded.updated_at, url=excluded.url, '
        'name=excluded.name, logo=excluded.logo',
        [
          p.sourceId, p.key, p.kind.index,
          p.subtitle == null ? p.title : '${p.subtitle} · ${p.title}',
          p.logo, p.url, position.inMilliseconds, duration.inMilliseconds, _nowSecs,
        ],
        {'history'},
      );

  Future<Duration?> resumePosition(int sourceId, String key) async {
    final r = await db.selectOne(
        'SELECT position_ms, duration_ms FROM history WHERE source_id=? AND key=?',
        [sourceId, key]);
    if (r == null) return null;
    final pos = r['position_ms'] as int;
    final dur = r['duration_ms'] as int;
    // Don't resume near the start or after the credits.
    if (pos < 30000 || (dur > 0 && pos > dur * 0.95)) return null;
    return Duration(milliseconds: pos);
  }

  Future<List<HistoryEntry>> continueWatching({int limit = 30}) async => (await db.select(
          'SELECT * FROM history WHERE kind<>0 AND position_ms > 30000 '
          'AND (duration_ms = 0 OR position_ms < duration_ms * 0.95) '
          'ORDER BY updated_at DESC LIMIT ?',
          [limit]))
      .map(HistoryEntry.fromRow)
      .toList();

  Future<List<HistoryEntry>> recentChannels({int limit = 20}) async => (await db.select(
          'SELECT * FROM history WHERE kind=0 ORDER BY updated_at DESC LIMIT ?', [limit]))
      .map(HistoryEntry.fromRow)
      .toList();

  Future<void> removeHistory(int sourceId, String key) => db.execute(
      'DELETE FROM history WHERE source_id=? AND key=?', [sourceId, key], {'history'});

  Future<void> clearHistory() => db.execute('DELETE FROM history', const [], {'history'});

  // ------------------------------------------------------------ EPG

  static const _progCols = 'channel, start, stop, title, descr, category';

  /// Guide file of a source, or null if it has no guide yet.
  Future<String?> _epg(int sourceId) async {
    final r = await db.selectOne('SELECT epg_gen FROM sources WHERE id=?', [sourceId]);
    final gen = r?['epg_gen'] as int?;
    if (gen == null || gen == 0) return null;
    final path = p.join(epgDir, epgFileName(sourceId, gen));
    return File(path).existsSync() ? path : null;
  }

  /// Programmes overlapping [from, to) for many channels, grouped by channel.
  Future<Map<String, List<Programme>>> _range(int sourceId, List<String> epgIds,
      int from, int to, {int? maxPerChannel}) async {
    final ids = epgIds.toSet().toList();
    if (ids.isEmpty) return const {};
    final file = await _epg(sourceId);
    if (file == null) return const {};
    final out = <String, List<Programme>>{};
    // Chunk to stay well under SQLite's bound-variable limit.
    for (var i = 0; i < ids.length; i += 400) {
      final chunk = ids.sublist(i, i + 400 > ids.length ? ids.length : i + 400);
      final marks = List.filled(chunk.length, '?').join(',');
      // `start > from - 1 day` lets the (channel, start) index bound the scan.
      final rows = await db.selectFile(
        file,
        'SELECT $_progCols FROM programmes WHERE channel IN ($marks) '
        'AND start > ? AND start < ? AND stop > ? ORDER BY channel, start',
        [...chunk, from - 86400, to, from],
      );
      for (final r in rows) {
        final list = out.putIfAbsent(r['channel'] as String, () => []);
        if (maxPerChannel == null || list.length < maxPerChannel) {
          list.add(Programme.fromRow(r));
        }
      }
    }
    return out;
  }

  /// Current and next programme per EPG channel id.
  Future<Map<String, List<Programme>>> nowNext(int sourceId, List<String> epgIds) =>
      nowNextAt(sourceId, epgIds, _nowSecs);

  Future<Map<String, List<Programme>>> nowNextAt(
          int sourceId, List<String> epgIds, int nowSecs) =>
      _range(sourceId, epgIds, nowSecs, nowSecs + 8 * 3600, maxPerChannel: 2);

  Future<List<Programme>> programmes(
      int sourceId, String epgId, DateTime from, DateTime to) async {
    final m = await _range(sourceId, [epgId], _secs(from), _secs(to));
    return m[epgId] ?? const [];
  }

  /// Programmes for many channels in a time range (guide grid).
  Future<Map<String, List<Programme>>> guide(
          int sourceId, List<String> epgIds, DateTime from, DateTime to) =>
      _range(sourceId, epgIds, _secs(from), _secs(to));

  Future<int> programmeCount(int sourceId) async {
    final file = await _epg(sourceId);
    if (file == null) return 0;
    final r = await db.selectFile(file, 'SELECT COUNT(*) n FROM programmes');
    return r.first['n'] as int;
  }

  /// Deletes guide files that are no longer current (old generations,
  /// interrupted imports, removed sources).
  Future<void> cleanupEpgFiles() async {
    final dir = Directory(epgDir);
    if (!await dir.exists()) return;
    final gens = {
      for (final r in await db.select('SELECT id, epg_gen FROM sources'))
        r['id'] as int: r['epg_gen'] as int,
    };
    await for (final e in dir.list()) {
      if (e is! File) continue;
      final name = p.basename(e.path);
      final m = epgFilePattern.firstMatch(name);
      if (m == null) continue;
      final sid = int.parse(m[1]!);
      final gen = int.parse(m[2]!);
      if (gens[sid] == gen) continue;
      await db.releaseFiles(name);
      try {
        await e.delete();
      } catch (_) {
        // Still open somewhere (or an import is writing it); retry next time.
      }
    }
  }
}
