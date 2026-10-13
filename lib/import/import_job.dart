import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../core/db/database.dart' show openConnection;
import '../core/db/schema.dart';
import '../core/http.dart';
import '../core/models.dart';
import '../parsers/m3u_parser.dart';
import '../parsers/xmltv_parser.dart';
import '../parsers/xtream_api.dart';
import 'epg_pipeline.dart';

enum ImportScope { playlist, epg, all }

/// Everything an import isolate needs (must be sendable across isolates).
class ImportRequest {
  ImportRequest({
    required this.dbPath,
    required this.tempDir,
    required this.epgDir,
    required this.sourceId,
    required this.type,
    required this.url,
    required this.scope,
    this.username,
    this.password,
    this.epgUrl,
    this.userAgent,
    this.epgPastHours = 24,
    this.epgFutureDays = 7,
    this.liveFormat = 'ts',
  });

  final String dbPath;
  final String tempDir;
  final String epgDir;
  final int sourceId;
  final SourceType type;
  final String url;
  final ImportScope scope;
  final String? username;
  final String? password;
  final String? epgUrl;
  final String? userAgent;
  final int epgPastHours;
  final int epgFutureDays;
  final String liveFormat;
}

/// Progress event sent back to the UI isolate.
class ImportProgress {
  ImportProgress(this.stage, this.message, {this.fraction, this.done = false, this.error});
  final String stage; // download | parse | save | epg | done | error
  final String message;
  final double? fraction;
  final bool done;
  final String? error;
}

/// Isolate entry point.
Future<void> importMain(List args) async {
  final req = args[0] as ImportRequest;
  final out = args[1] as SendPort;
  // Throttled: at most ~10 progress messages per second per stage.
  final since = Stopwatch()..start();
  var lastStage = '';
  void report(String stage, String msg, [double? f]) {
    if (stage == lastStage && since.elapsedMilliseconds < 100) return;
    lastStage = stage;
    since.reset();
    out.send(ImportProgress(stage, msg, fraction: f));
  }

  Database? db;
  final client = createHttpClient(userAgent: req.userAgent);
  try {
    db = openConnection(req.dbPath);
    migrate(db);
    // Checkpoint less often during bulk writes; a final checkpoint runs on
    // close.
    db.execute('PRAGMA wal_autocheckpoint = 10000;');
    db.execute('PRAGMA cache_size = -131072;'); // 128 MB for bulk work
    db.execute('PRAGMA temp_store = FILE;'); // index sorts spill to disk
    final job = _ImportJob(req, db, client, report);
    await job.run();
    out.send(ImportProgress('done', job.summary, done: true));
  } catch (e, st) {
    final msg = _friendlyError(e);
    try {
      db?.execute(
          "UPDATE sources SET status='error', error=? WHERE id=?",
          [msg, req.sourceId]);
    } catch (_) {}
    out.send(ImportProgress('error', msg, done: true, error: '$e\n$st'));
  } finally {
    client.close(force: true);
    db?.close();
  }
}

String _friendlyError(Object e) {
  if (e is SocketException) {
    return 'Network error: ${e.osError?.message ?? e.message}';
  }
  if (e is TimeoutException) return 'The server took too long to respond';
  if (e is HandshakeException) return 'Secure connection failed (TLS)';
  if (e is HttpException2) return e.message;
  if (e is FormatException) return 'Invalid data from server: ${e.message}';
  return '$e';
}

class _ImportJob {
  _ImportJob(this.req, this.db, this.client, this.report);

  final ImportRequest req;
  final Database db;
  final HttpClient client;
  final void Function(String stage, String msg, [double? f]) report;

  int live = 0, movies = 0, series = 0, programmes = 0;
  String? discoveredEpgUrl;

  String get summary {
    final parts = <String>[];
    if (req.scope != ImportScope.epg) {
      parts.add('$live channels, $movies movies, $series series');
    }
    if (req.scope != ImportScope.playlist) parts.add('$programmes programmes');
    return parts.join(' · ');
  }

  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  Future<void> run() async {
    final sw = Stopwatch()..start();
    if (req.scope != ImportScope.epg) {
      if (req.type == SourceType.xtream) {
        await _importXtream();
      } else {
        await _importM3u();
      }
      db.execute(
        "UPDATE sources SET status='ok', error=NULL, last_refresh=?, "
        'live_count=?, movie_count=?, series_count=? WHERE id=?',
        [_now, live, movies, series, req.sourceId],
      );
    }
    if (req.scope != ImportScope.playlist) {
      final epgUrl = _resolveEpgUrl();
      if (epgUrl != null) {
        await _importEpg(epgUrl);
      }
    }
    report('done', 'Finished in ${(sw.elapsedMilliseconds / 1000).toStringAsFixed(1)} s');
  }

  String? _resolveEpgUrl() {
    final configured = req.epgUrl?.trim();
    if (configured != null && configured.isNotEmpty) return configured;
    if (req.type == SourceType.xtream) {
      return XtreamApi(
        server: req.url,
        username: req.username ?? '',
        password: req.password ?? '',
        client: client,
      ).epgUrl;
    }
    if (discoveredEpgUrl != null) return discoveredEpgUrl;
    final row = db.select('SELECT epg_url FROM sources WHERE id=?', [req.sourceId]);
    final v = row.isEmpty ? null : row.first['epg_url'] as String?;
    return (v == null || v.isEmpty) ? null : v;
  }

  // ---------------------------------------------------------------- M3U

  Future<void> _importM3u() async {
    File? temp;
    String path = req.url;
    if (req.type == SourceType.m3uUrl) {
      temp = File(p.join(req.tempDir, 'playlist_${req.sourceId}_$_now.m3u'));
      report('download', 'Downloading playlist…');
      await downloadToFile(req.url, temp, client: client,
          onProgress: (r, t) => report('download',
              'Downloading playlist… ${_mb(r)}${t != null ? ' / ${_mb(t)}' : ''}',
              t != null ? r / t : null));
      path = temp.path;
    }

    try {
      final writer = _ItemWriter(db, req.sourceId);
      final fileLen = await File(path).length();
      var bytesRead = 0;
      var lastReport = 0;
      report('parse', 'Reading playlist…', 0);

      writer.begin();
      final M3uParser parser;
      try {
        parser = await parseM3uStream(
        File(path).openRead().map((c) {
          bytesRead += c.length;
          return c;
        }),
        (e) {
          final kind = e.kind;
          final group = e.group ?? 'Uncategorized';
          writer.add(
            kind: kind,
            categoryName: group,
            key: '${kind.index}|$group|${e.name}',
            name: e.name,
            logo: e.logo,
            url: e.url,
            epgId: e.tvgId,
            num: e.channelNumber,
            catchupDays: e.catchupDays,
            headers: e.headers,
          );
          if (writer.count - lastReport >= 5000) {
            lastReport = writer.count;
            report('parse', 'Saving ${writer.count} entries…',
                fileLen > 0 ? bytesRead / fileLen : null);
          }
        },
      );
      } catch (_) {
        writer.abort();
        rethrow;
      }
      if (writer.count == 0) {
        writer.abort();
        throw HttpException2('The playlist is empty or not a valid M3U file');
      }
      report('save', 'Building search index…');
      writer.finish();
      live = writer.counts[ItemKind.live]!;
      movies = writer.counts[ItemKind.movie]!;
      series = writer.counts[ItemKind.series]!;
      discoveredEpgUrl = parser.epgUrl;
      if (parser.epgUrl != null) {
        db.execute(
            "UPDATE sources SET epg_url=? WHERE id=? AND (epg_url IS NULL OR epg_url='')",
            [parser.epgUrl, req.sourceId]);
      }
    } finally {
      if (temp != null && await temp.exists()) await temp.delete();
    }
  }

  // ---------------------------------------------------------------- Xtream

  Future<void> _importXtream() async {
    final api = XtreamApi(
      server: req.url,
      username: req.username ?? '',
      password: req.password ?? '',
      client: client,
    );
    report('download', 'Signing in…');
    final account = await api.authenticate();
    db.execute('UPDATE sources SET expires_at=?, max_connections=? WHERE id=?',
        [account.expiresAt, account.maxConnections, req.sourceId]);

    report('download', 'Loading categories…', 0.05);
    final results = await Future.wait([
      api.liveCategories(),
      api.vodCategories(),
      api.seriesCategories(),
    ]);
    report('download', 'Loading live channels…', 0.15);
    final liveStreams = await api.liveStreams();
    report('download', 'Loading movies…', 0.35);
    final vod = await api.vodStreams();
    report('download', 'Loading series…', 0.55);
    final seriesList = await api.series();

    report('save', 'Saving ${liveStreams.length + vod.length + seriesList.length} entries…', 0.75);
    final writer = _ItemWriter(db, req.sourceId);
    writer.begin();

    void cats(ItemKind kind, List<Map<String, dynamic>> list) {
      for (final c in list) {
        final id = xtStr(c['category_id']);
        if (id == null) continue;
        writer.category(kind, id, xtStr(c['category_name']) ?? 'Unnamed');
      }
    }

    try {
      _writeXtream(writer, api, cats, results, liveStreams, vod, seriesList);
    } catch (_) {
      writer.abort();
      rethrow;
    }
    report('save', 'Building search index…', 0.9);
    writer.finish();
    live = writer.counts[ItemKind.live]!;
    movies = writer.counts[ItemKind.movie]!;
    series = writer.counts[ItemKind.series]!;
  }

  void _writeXtream(
    _ItemWriter writer,
    XtreamApi api,
    void Function(ItemKind, List<Map<String, dynamic>>) cats,
    List<List<Map<String, dynamic>>> results,
    List<Map<String, dynamic>> liveStreams,
    List<Map<String, dynamic>> vod,
    List<Map<String, dynamic>> seriesList,
  ) {
    cats(ItemKind.live, results[0]);
    cats(ItemKind.movie, results[1]);
    cats(ItemKind.series, results[2]);

    for (final s in liveStreams) {
      final id = xtStr(s['stream_id']);
      if (id == null) continue;
      writer.add(
        kind: ItemKind.live,
        categoryExtId: xtStr(s['category_id']),
        key: 'x:$id',
        name: xtStr(s['name']) ?? 'Channel $id',
        logo: xtStr(s['stream_icon']),
        url: api.liveUrl(id, ext: req.liveFormat),
        epgId: xtStr(s['epg_channel_id']),
        num: xtInt(s['num']),
        extId: id,
        catchupDays: (xtInt(s['tv_archive']) ?? 0) == 1
            ? xtInt(s['tv_archive_duration'])
            : null,
        addedAt: xtInt(s['added']),
      );
    }
    for (final s in vod) {
      final id = xtStr(s['stream_id']);
      if (id == null) continue;
      final ext = xtStr(s['container_extension']) ?? 'mp4';
      writer.add(
        kind: ItemKind.movie,
        categoryExtId: xtStr(s['category_id']),
        key: 'x:$id',
        name: xtStr(s['name']) ?? 'Movie $id',
        logo: xtStr(s['stream_icon']),
        url: api.movieUrl(id, ext),
        extId: id,
        container: ext,
        rating: xtDouble(s['rating']),
        year: xtStr(s['year']),
        addedAt: xtInt(s['added']),
      );
    }
    for (final s in seriesList) {
      final id = xtStr(s['series_id']);
      if (id == null) continue;
      writer.add(
        kind: ItemKind.series,
        categoryExtId: xtStr(s['category_id']),
        key: 'x:$id',
        name: xtStr(s['name']) ?? 'Series $id',
        logo: xtStr(s['cover']),
        extId: id,
        rating: xtDouble(s['rating']),
        year: xtStr(s['releaseDate'])?.split('-').first ?? xtStr(s['year']),
        addedAt: xtInt(s['last_modified']),
      );
    }
  }

  // ---------------------------------------------------------------- EPG

  Future<void> _importEpg(String url) async {
    final genRow = db.select('SELECT epg_gen FROM sources WHERE id=?', [req.sourceId]);
    final newGen = (genRow.first['epg_gen'] as int) + 1;
    final now = _now;

    await Directory(req.epgDir).create(recursive: true);
    final file = File(p.join(req.epgDir, epgFileName(req.sourceId, newGen)));
    if (await file.exists()) await file.delete();

    // Scratch database: invisible to everyone until the flip below, so
    // journaling and fsync are pure overhead.
    final edb = sqlite3.open(file.path);
    XmltvResult result;
    try {
      edb.execute('PRAGMA journal_mode = OFF;');
      edb.execute('PRAGMA synchronous = OFF;');
      edb.execute('PRAGMA locking_mode = EXCLUSIVE;');
      edb.execute('PRAGMA cache_size = -65536;');
      edb.execute('PRAGMA temp_store = FILE;');
      edb.execute(epgTableDdl);

      final insert = edb.prepare('INSERT INTO programmes VALUES (?, ?, ?, ?, ?, ?)');
      edb.execute('BEGIN;');
      report('epg', 'Downloading TV guide…');
      try {
        // Download + parse run in a second isolate and stream row batches
        // here, so XML scanning and SQLite inserts use two cores.
        result = await parseEpgInParallel(
          url: url,
          userAgent: req.userAgent,
          windowStart: now - req.epgPastHours * 3600,
          windowEnd: now + req.epgFutureDays * 86400,
          onBatch: (rows) {
            for (var i = 0; i < rows.length; i += 6) {
              insert.execute(rows.sublist(i, i + 6));
            }
            programmes += rows.length ~/ 6;
          },
          onProgress: (bytes, total) => report(
            'epg',
            'Reading TV guide… ${_mb(bytes)}${total != null ? ' / ${_mb(total)}' : ''} · '
                '${_count(programmes)} programmes',
            total != null ? (bytes / total * 0.9).clamp(0, 0.9) : null,
          ),
        );
        edb.execute('COMMIT;');
      } finally {
        insert.close();
      }
      if (programmes == 0 && result.channelNames.isEmpty) {
        throw HttpException2('The TV guide is empty or not valid XMLTV');
      }
      report('epg', 'Indexing ${_count(programmes)} programmes…', 0.92);
      edb.execute(epgIndexDdl);
      edb.execute('ANALYZE;');
    } catch (_) {
      edb.close();
      if (await file.exists()) await file.delete();
      rethrow;
    }
    edb.close();

    // Flip to the new guide. The UI releases and deletes the old file.
    report('epg', 'Matching channels…', 0.97);
    db.execute('BEGIN IMMEDIATE;');
    db.execute('UPDATE sources SET epg_gen=?, last_epg=? WHERE id=?',
        [newGen, now, req.sourceId]);
    _matchChannelsByName(result.channelNames);
    db.execute('COMMIT;');
  }

  /// Fills `epg_id` for channels that have none (or an unknown one) by
  /// matching normalised channel names against XMLTV display names.
  void _matchChannelsByName(Map<String, List<String>> names) {
    if (names.isEmpty) return;
    final byName = <String, String>{};
    for (final e in names.entries) {
      for (final n in e.value) {
        byName.putIfAbsent(normalizeChannelName(n), () => e.key);
      }
      byName.putIfAbsent(normalizeChannelName(e.key), () => e.key);
    }
    final rows = db.select(
        'SELECT id, name, epg_id FROM items WHERE source_id=? AND kind=0',
        [req.sourceId]);
    final update = db.prepare('UPDATE items SET epg_id=? WHERE id=?');
    try {
      for (final r in rows) {
        final current = r['epg_id'] as String?;
        if (current != null && names.containsKey(current)) continue;
        final match = byName[normalizeChannelName(r['name'] as String)];
        if (match != null && match != current) {
          update.execute([match, r['id']]);
        }
      }
    } finally {
      update.close();
    }
  }
}

final _tagRe = RegExp(r'\b(hd|fhd|uhd|4k|sd|hevc|h265|\d{3,4}p)\b');
final _prefixRe = RegExp(r'^[a-z]{2,3}\s*[:|\-]\s*');
final _nonAlnum = RegExp(r'[^a-z0-9]+');

/// "UK: BBC One HD" -> "bbcone"
String normalizeChannelName(String s) {
  var v = s.toLowerCase().trim();
  v = v.replaceAll(_prefixRe, '');
  v = v.replaceAll(_tagRe, '');
  return v.replaceAll(_nonAlnum, '');
}

String _mb(int bytes) => '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
String _count(int n) => n >= 1000 ? '${(n / 1000).toStringAsFixed(0)}k' : '$n';

/// Batched writer for categories + items, replacing a source's previous data
/// in one transaction (readers keep the old snapshot until COMMIT).
class _ItemWriter {
  _ItemWriter(this.db, this.sourceId);

  final Database db;
  final int sourceId;
  final _catIds = <String, int>{}; // "kind|extId" -> category row id
  final counts = {for (final k in ItemKind.values) k: 0};
  int count = 0;
  int _catSort = 0;
  late final PreparedStatement _insItem;
  late final PreparedStatement _insCat;

  void begin() {
    db.execute('BEGIN IMMEDIATE;');
    db.execute('DELETE FROM items WHERE source_id=?', [sourceId]);
    db.execute('DELETE FROM categories WHERE source_id=?', [sourceId]);
    _insCat = db.prepare(
        'INSERT INTO categories (source_id, kind, ext_id, name, sort) VALUES (?, ?, ?, ?, ?)');
    _insItem = db.prepare(
        'INSERT INTO items (source_id, kind, category_id, key, name, logo, url, epg_id, num, '
        'ext_id, container, rating, year, added_at, catchup_days, headers, sort) '
        'VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)');
  }

  int category(ItemKind kind, String extId, String name) {
    final k = '${kind.index}|$extId';
    final existing = _catIds[k];
    if (existing != null) return existing;
    _insCat.execute([sourceId, kind.index, extId, name, _catSort++]);
    return _catIds[k] = db.lastInsertRowId;
  }

  void add({
    required ItemKind kind,
    required String key,
    required String name,
    String? categoryName,
    String? categoryExtId,
    String? logo,
    String? url,
    String? epgId,
    int? num,
    String? extId,
    String? container,
    double? rating,
    String? year,
    int? addedAt,
    int? catchupDays,
    Map<String, String> headers = const {},
  }) {
    int? catId;
    if (categoryName != null) {
      catId = category(kind, categoryName, categoryName);
    } else if (categoryExtId != null) {
      catId = _catIds['${kind.index}|$categoryExtId'] ??
          category(kind, categoryExtId, 'Other');
    } else {
      catId = category(kind, '__none', 'Uncategorized');
    }
    _insItem.execute([
      sourceId, kind.index, catId, key, name, logo, url, epgId, num, extId,
      container, rating, year, addedAt, catchupDays,
      headers.isEmpty ? null : jsonEncode(headers),
      count,
    ]);
    count++;
    counts[kind] = counts[kind]! + 1;
  }

  void abort() {
    try {
      _insItem.close();
      _insCat.close();
    } catch (_) {}
    try {
      db.execute('ROLLBACK;');
    } catch (_) {}
  }

  void finish() {
    try {
      _insItem.close();
      _insCat.close();
      db.execute(
          'UPDATE categories SET item_count = (SELECT COUNT(*) FROM items i WHERE i.category_id = categories.id) '
          'WHERE source_id=?',
          [sourceId]);
      db.execute('DELETE FROM categories WHERE source_id=? AND item_count=0', [sourceId]);
      db.execute("INSERT INTO items_fts(items_fts) VALUES('rebuild');");
      db.execute('COMMIT;');
    } catch (_) {
      db.execute('ROLLBACK;');
      rethrow;
    }
  }
}
