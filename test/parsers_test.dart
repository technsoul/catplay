import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iptv_player/core/http.dart';
import 'package:iptv_player/core/models.dart';
import 'package:iptv_player/import/import_job.dart' show normalizeChannelName;
import 'package:iptv_player/parsers/m3u_parser.dart';
import 'package:iptv_player/parsers/xmltv_parser.dart';
import 'package:iptv_player/parsers/xtream_api.dart';

Future<List<M3uEntry>> parseM3u(String text, {int chunk = 7}) async {
  final out = <M3uEntry>[];
  // Feed in tiny chunks to exercise line splitting across boundaries.
  final bytes = utf8.encode(text);
  final stream = Stream.fromIterable([
    for (var i = 0; i < bytes.length; i += chunk)
      bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk),
  ]);
  await parseM3uStream(stream, out.add);
  return out;
}

Future<(List<XmltvProgramme>, XmltvResult)> parseXml(String text,
    {int chunk = 13, int windowStart = 0, int windowEnd = 1 << 40}) async {
  final out = <XmltvProgramme>[];
  final bytes = utf8.encode(text);
  final stream = Stream.fromIterable([
    for (var i = 0; i < bytes.length; i += chunk)
      bytes.sublist(i, i + chunk > bytes.length ? bytes.length : i + chunk),
  ]);
  final r = await parseXmltvStream(stream,
      onProgramme: out.add, windowStart: windowStart, windowEnd: windowEnd);
  return (out, r);
}

void main() {
  group('M3U', () {
    test('parses extended entries, attributes and groups', () async {
      final e = await parseM3u('''
﻿#EXTM3U url-tvg="http://epg.example/guide.xml.gz" x-tvg-url="ignored"
#EXTINF:-1 tvg-id="bbc1.uk" tvg-name="BBC One" tvg-logo="http://l/bbc.png" group-title="UK, News",BBC One HD
http://host/live/u/p/1.ts
#EXTINF:-1 tvg-chno="7" catchup-days="3",Channel, with comma
#EXTGRP:Sports
#EXTVLCOPT:http-user-agent=MyAgent/1.0
#EXTVLCOPT:http-referrer=http://ref/
http://host/2.m3u8|X-Token=abc%20def
''');
      expect(e, hasLength(2));
      expect(e[0].name, 'BBC One HD');
      expect(e[0].tvgId, 'bbc1.uk');
      expect(e[0].logo, 'http://l/bbc.png');
      expect(e[0].group, 'UK, News');
      expect(e[0].kind, ItemKind.live);
      expect(e[1].name, 'Channel, with comma');
      expect(e[1].group, 'Sports');
      expect(e[1].channelNumber, 7);
      expect(e[1].catchupDays, 3);
      expect(e[1].url, 'http://host/2.m3u8');
      expect(e[1].headers['User-Agent'], 'MyAgent/1.0');
      expect(e[1].headers['Referer'], 'http://ref/');
      expect(e[1].headers['X-Token'], 'abc def');
    });

    test('reads EPG url from header', () async {
      final parser = await parseM3uStream(
          Stream.value(utf8.encode('#EXTM3U url-tvg="http://a/x.xml,http://b/y.xml"\n')),
          (_) {});
      expect(parser.epgUrl, 'http://a/x.xml');
    });

    test('classifies movies and series', () async {
      final e = await parseM3u('''
#EXTM3U
#EXTINF:-1 group-title="Movies",Some Film (2020)
http://h/movie/u/p/55.mkv
#EXTINF:-1 group-title="Shows",Show S01E02
http://h/series/u/p/77.mp4
#EXTINF:-1 group-title="VOD",Plain Movie
http://h/files/plain.mp4
''');
      expect(e.map((x) => x.kind), [ItemKind.movie, ItemKind.series, ItemKind.movie]);
    });

    test('plain playlists without EXTINF', () async {
      final e = await parseM3u('http://h/a.ts\nhttp://h/b.ts\n');
      expect(e.map((x) => x.name), ['a.ts', 'b.ts']);
    });

    test('CRLF line endings and blank lines', () async {
      final e = await parseM3u('#EXTM3U\r\n\r\n#EXTINF:-1,One\r\nhttp://h/1\r\n');
      expect(e.single.name, 'One');
      expect(e.single.url, 'http://h/1');
    });
  });

  group('XMLTV', () {
    const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE tv SYSTEM "xmltv.dtd">
<tv generator-info-name="test">
  <channel id="bbc1.uk">
    <display-name lang="en">BBC One</display-name>
    <display-name>BBC 1 HD</display-name>
    <icon src="http://l/bbc.png"/>
  </channel>
  <channel id="empty.tv"/>
  <programme start="20251013180000 +0100" stop="20251013190000 +0100" channel="bbc1.uk">
    <title lang="en">News &amp; Weather</title>
    <sub-title>Not the title</sub-title>
    <desc lang="en"><![CDATA[A <b>bold</b> & raw description]]></desc>
    <category lang="en">News</category>
    <category lang="en">Second</category>
  </programme>
  <programme start="20251013190000" channel="bbc1.uk"><title>No stop &#233;t&#xE9;</title></programme>
  <programme start='20251013200000 -0500' stop='20251013210000 -0500' channel='bbc1.uk'>
    <title>Single quotes</title>
  </programme>
  <programme start="garbage" channel="bbc1.uk"><title>Bad time</title></programme>
  <programme start="20251013220000 +0000" stop="20251013230000 +0000" channel="bbc1.uk"/>
</tv>''';

    for (final chunk in [1, 7, 64, 100000]) {
      test('parses programmes and channels (chunk $chunk)', () async {
        final (progs, r) = await parseXml(xml, chunk: chunk);
        expect(progs, hasLength(4));
        final p0 = progs[0];
        expect(p0.channel, 'bbc1.uk');
        expect(p0.title, 'News & Weather');
        expect(p0.description, 'A <b>bold</b> & raw description');
        expect(p0.category, 'News');
        expect(p0.start, DateTime.utc(2025, 10, 13, 17).millisecondsSinceEpoch ~/ 1000);
        expect(p0.stop - p0.start, 3600);
        expect(progs[1].title, 'No stop été');
        expect(progs[1].stop - progs[1].start, 3600, reason: 'missing stop defaults to 1h');
        expect(progs[2].title, 'Single quotes');
        expect(progs[2].start, DateTime.utc(2025, 10, 14, 1).millisecondsSinceEpoch ~/ 1000);
        expect(progs[3].title, 'No title');
        expect(r.channelNames['bbc1.uk'], ['BBC One', 'BBC 1 HD']);
        expect(r.skipped, 1);
      });
    }

    test('drops programmes outside the window', () async {
      final ws = DateTime.utc(2025, 10, 13, 18, 30).millisecondsSinceEpoch ~/ 1000;
      final we = DateTime.utc(2025, 10, 13, 21).millisecondsSinceEpoch ~/ 1000;
      final (progs, r) = await parseXml(xml, windowStart: ws, windowEnd: we);
      expect(progs.map((p) => p.title), ['No stop été']);
      expect(r.skipped, 4);
    });

    test('time parsing', () {
      expect(parseXmltvTime('20240229235959 +0000'),
          DateTime.utc(2024, 2, 29, 23, 59, 59).millisecondsSinceEpoch ~/ 1000);
      expect(parseXmltvTime('202402292359'),
          DateTime.utc(2024, 2, 29, 23, 59).millisecondsSinceEpoch ~/ 1000);
      expect(parseXmltvTime('19991231230000 -0130'),
          DateTime.utc(2000, 1, 1, 0, 30).millisecondsSinceEpoch ~/ 1000);
      expect(parseXmltvTime('2024'), isNull);
      expect(parseXmltvTime('20241399000000'), isNull);
    });

    test('gzip-compressed file is detected by magic bytes', () async {
      final dir = await Directory.systemTemp.createTemp('xmltv');
      final f = File('${dir.path}/g.xml.gz')..writeAsBytesSync(gzip.encode(utf8.encode(xml)));
      final progs = <XmltvProgramme>[];
      final stream = await openStream(f.path);
      await parseXmltvStream(stream, onProgramme: progs.add, windowStart: 0, windowEnd: 1 << 40);
      expect(progs, hasLength(4));
      await dir.delete(recursive: true);
    });
  });

  group('misc', () {
    test('channel name normalisation for EPG matching', () {
      expect(normalizeChannelName('UK: BBC One HD'), 'bbcone');
      expect(normalizeChannelName('BBC One'), 'bbcone');
      expect(normalizeChannelName('FR | TF1 FHD'), 'tf1');
      expect(normalizeChannelName('Sky Sports Main Event 4K'), 'skysportsmainevent');
    });

    test('Xtream server normalisation', () {
      expect(XtreamApi.normalizeServer('example.com:8080'), 'http://example.com:8080');
      expect(XtreamApi.normalizeServer('https://ex.com/player_api.php?username=a'), 'https://ex.com');
      expect(XtreamApi.normalizeServer(' http://ex.com:80/ '), 'http://ex.com');
    });

    test('Xtream URLs escape credentials', () {
      final api = XtreamApi(server: 'http://h:1', username: 'a b', password: 'p&q');
      expect(api.liveUrl('5'), 'http://h:1/live/a%20b/p%26q/5.ts');
      expect(api.apiUrl('get_live_streams'),
          'http://h:1/player_api.php?username=a%20b&password=p%26q&action=get_live_streams');
      api.close();
    });
  });
}
