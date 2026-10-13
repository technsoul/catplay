// ignore_for_file: avoid_print

// Stress test for the import pipeline.
//
//   dart run tool/bench.dart [channels=100000] [epgMb=500]
//
// Generates a synthetic M3U playlist and XMLTV guide, imports both through the
// real import isolate code, then times typical UI queries.
import 'dart:io';
import 'dart:isolate';

import 'package:iptv_player/core/db/database.dart';
import 'package:iptv_player/core/models.dart';
import 'package:iptv_player/data/repository.dart';
import 'package:iptv_player/import/import_job.dart';
import 'package:path/path.dart' as p;

Future<void> main(List<String> args) async {
  final channels = args.isNotEmpty ? int.parse(args[0]) : 100000;
  final epgMb = args.length > 1 ? int.parse(args[1]) : 500;
  final verbose = args.contains('-v');
  final dir = Directory(p.join(Directory.systemTemp.path, 'iptv_bench'));
  if (dir.existsSync()) dir.deleteSync(recursive: true);
  dir.createSync(recursive: true);

  final m3u = File(p.join(dir.path, 'big.m3u'));
  final xml = File(p.join(dir.path, 'big.xml'));
  final sw = Stopwatch()..start();
  await _genM3u(m3u, channels);
  await _genXmltv(xml, channels, epgMb);
  await Future<void>.delayed(const Duration(seconds: 1));
  print('Generated M3U ${_mb(m3u.lengthSync())}, XMLTV ${_mb(xml.lengthSync())} '
      'in ${sw.elapsed.inSeconds}s');

  final dbPath = p.join(dir.path, 'bench.db');
  final db = await AppDatabase.open(dbPath);
  final sourceId = await db.insert(
      "INSERT INTO sources (name, type, url, created_at) VALUES ('bench', 'm3u_file', ?, 0)",
      [m3u.path]);

  Future<void> runImport(ImportScope scope) async {
    final rp = ReceivePort();
    final rss = <int>[];
    final t = Stopwatch()..start();
    final timer = Stream.periodic(const Duration(milliseconds: 250))
        .listen((_) => rss.add(ProcessInfo.currentRss));
    await Isolate.spawn(importMain, [
      ImportRequest(
        dbPath: dbPath,
        tempDir: dir.path,
        epgDir: dir.path,
        sourceId: sourceId,
        type: SourceType.m3uFile,
        url: m3u.path,
        scope: scope,
        epgUrl: xml.path,
        epgPastHours: 24 * 365 * 10,
        epgFutureDays: 365 * 10,
      ),
      rp.sendPort,
    ]);
    await for (final msg in rp) {
      final pr = msg as ImportProgress;
      if (verbose && !pr.done) {
        print('    [${(t.elapsedMilliseconds / 1000).toStringAsFixed(1)}s] ${pr.message}');
      }
      if (pr.done) {
        if (pr.error != null) print('ERROR: ${pr.error}');
        print('  ${scope.name}: ${pr.message} — ${t.elapsedMilliseconds} ms, '
            'peak RSS ${_mb(rss.isEmpty ? ProcessInfo.currentRss : rss.reduce((a, b) => a > b ? a : b))}');
        rp.close();
      }
    }
    await timer.cancel();
  }

  print('Import:');
  await runImport(ImportScope.playlist);
  await runImport(ImportScope.epg);

  Future<void> time(String label, Future<Object?> Function() q, {int runs = 20}) async {
    await q(); // warm
    final t = Stopwatch()..start();
    Object? r;
    for (var i = 0; i < runs; i++) {
      r = await q();
    }
    final n = r is List ? r.length : r;
    print('  $label: ${(t.elapsedMicroseconds / runs / 1000).toStringAsFixed(2)} ms  ($n rows)');
  }

  print('Queries (avg, via worker isolate):');
  await time('FTS search "sport 12"', () => db.select(
      "SELECT i.id, i.name FROM items_fts f JOIN items i ON i.id=f.rowid "
      "WHERE items_fts MATCH ? ORDER BY rank LIMIT 100", ['"sport"* "12"*']));
  await time('Category page (100)', () => db.select(
      'SELECT * FROM items WHERE category_id=(SELECT id FROM categories LIMIT 1 OFFSET 7) '
      'ORDER BY sort LIMIT 100 OFFSET 200'));
  final now = 1760000000;
  final repo = Repository(db, epgDir: dir.path);
  final ids = [for (var i = 500; i < 530; i++) 'ch$i.tv'];
  final ids100 = [for (var i = 0; i < 100; i++) 'ch$i.tv'];
  final at = DateTime.fromMillisecondsSinceEpoch(now * 1000);
  await time('EPG grid 30 ch x 24h', () => repo.guide(sourceId, ids, at, at.add(const Duration(hours: 24))).then((m) => m.values.expand((e) => e).toList()));
  await time('Now/next 100 ch', () => repo.nowNextAt(sourceId, ids100, now).then((m) => m.values.expand((e) => e).toList()));

  final counts = await db.selectOne(
      'SELECT (SELECT COUNT(*) FROM items) items, 0 progs');
  print('DB: $counts, programmes ${await repo.programmeCount(sourceId)}, main DB ${_mb(File(dbPath).lengthSync())}');
  await db.close();
}

const _groups = ['Sports', 'News', 'Movies', 'Kids', 'Music', 'Docs', 'Entertainment'];
const _countries = ['UK', 'US', 'FR', 'DE', 'ES', 'IT', 'AR', 'TR'];

Future<void> _genM3u(File f, int n) async {
  final s = f.openWrite();
  s.writeln('#EXTM3U');
  final b = StringBuffer();
  for (var i = 0; i < n; i++) {
    final g = '${_countries[i % 8]} | ${_groups[i % 7]}';
    b
      ..write('#EXTINF:-1 tvg-id="ch$i.tv" tvg-name="Channel $i" ')
      ..write('tvg-logo="http://logos.example/ch$i.png" group-title="$g",')
      ..write('${_countries[i % 8]}: ${_groups[i % 7]} Channel $i HD\n')
      ..write('http://example.com/live/user/pass/$i.ts\n');
    if (i % 2000 == 0) {
      s.write(b);
      b.clear();
      await s.flush();
    }
  }
  s.write(b);
  await s.close();
}

Future<void> _genXmltv(File f, int channels, int targetMb) async {
  final s = f.openWrite();
  s.writeln('<?xml version="1.0" encoding="UTF-8"?>\n<tv generator-info-name="bench">');
  for (var i = 0; i < channels; i++) {
    s.writeln('<channel id="ch$i.tv"><display-name>Channel $i</display-name></channel>');
  }
  final target = targetMb * 1024 * 1024;
  var written = 0;
  final b = StringBuffer();
  var base = DateTime.utc(2025, 10, 9);
  var slot = 0;
  outer:
  while (true) {
    for (var c = 0; c < channels; c++) {
      final st = base.add(Duration(hours: slot));
      final en = st.add(const Duration(hours: 1));
      final line = '<programme start="${_t(st)} +0000" stop="${_t(en)} +0000" channel="ch$c.tv">'
          '<title lang="en">Show $slot on channel $c &amp; friends</title>'
          '<desc lang="en">An episode of a programme with a reasonably long description to mimic real guides. Episode $slot.</desc>'
          '<category lang="en">${_groups[c % 7]}</category></programme>\n';
      b.write(line);
      written += line.length;
      if (b.length > 1 << 20) {
        s.write(b);
        b.clear();
        await s.flush();
      }
      if (written >= target) break outer;
    }
    slot++;
  }
  s.write(b);
  s.writeln('</tv>');
  await s.close();
}

String _t(DateTime d) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${d.year}${two(d.month)}${two(d.day)}${two(d.hour)}${two(d.minute)}00';
}

String _mb(int b) => '${(b / 1048576).toStringAsFixed(1)} MB';
