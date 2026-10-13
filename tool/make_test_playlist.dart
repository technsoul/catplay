// Generates a local test playlist + XMLTV guide using public test streams.
//   dart run tool/make_test_playlist.dart <outDir>
import 'dart:io';

import 'package:path/path.dart' as p;

void main(List<String> args) {
  final dir = args.isEmpty ? Directory.current.path : args[0];
  final xmlPath = p.join(dir, 'test_guide.xml');
  const akamai = 'https://cph-p2p-msl.akamaized.net/hls/live/2000341/test/master.m3u8';
  final live = <(String, String, String, String)>[
    ('akamai.live', 'Akamai Live Test', 'News', akamai),
    ('bbb.hls', 'Big Buck Bunny HLS', 'Movies 24/7', 'https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8'),
    ('apple.bipbop', 'Apple BipBop (fMP4)', 'Entertainment', 'https://devstreaming-cdn.apple.com/videos/streaming/examples/img_bipbop_adv_example_fmp4/master.m3u8'),
    ('tos.hls', 'Tears of Steel', 'Movies 24/7', 'https://test-streams.mux.dev/tos_ismc/main.m3u8'),
    ('broken.tv', 'Broken Channel (404)', 'News', 'https://test-streams.mux.dev/does-not-exist.m3u8'),
  ];
  final b = StringBuffer('#EXTM3U url-tvg="$xmlPath"\n');
  for (final (id, name, group, url) in live) {
    b.writeln('#EXTINF:-1 tvg-id="$id" tvg-name="$name" group-title="$group",$name');
    b.writeln(url);
  }
  const groups = ['Sports', 'Kids', 'Music', 'Documentary'];
  for (var i = 1; i <= 2000; i++) {
    final g = groups[i % groups.length];
    b.writeln('#EXTINF:-1 tvg-id="filler$i" group-title="$g",$g Channel $i HD');
    b.writeln(akamai);
  }
  b.writeln('#EXTINF:-1 group-title="Movies",Big Buck Bunny (2008)');
  b.writeln('https://test-videos.co.uk/vids/bigbuckbunny/mp4/h264/1080/Big_Buck_Bunny_1080_10s_1MB.mp4');
  b.writeln('#EXTINF:-1 group-title="Movies",Sintel Trailer');
  b.writeln('https://test-videos.co.uk/vids/sintel/mp4/h264/720/Sintel_720_10s_1MB.mp4');
  File(p.join(dir, 'test_playlist.m3u')).writeAsStringSync(b.toString());

  String t(DateTime d) {
    String two(int v) => v.toString().padLeft(2, '0');
    final u = d.toUtc();
    return '${u.year}${two(u.month)}${two(u.day)}${two(u.hour)}${two(u.minute)}00 +0000';
  }

  final x = StringBuffer('<?xml version="1.0" encoding="UTF-8"?>\n<tv>\n');
  final ids = [for (final l in live) l.$1, for (var i = 1; i <= 2000; i++) 'filler$i'];
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day).subtract(const Duration(hours: 6));
  const shows = ['Morning Report', 'Live Match', 'Cartoon Hour', 'Top 40', 'Nature & Wildlife', 'Evening News', 'Late Movie', 'Talk Show'];
  for (final id in ids) {
    x.writeln('<channel id="$id"><display-name>$id</display-name></channel>');
  }
  for (var c = 0; c < ids.length; c++) {
    var s = start.add(Duration(minutes: (c * 17) % 60));
    var k = c;
    while (s.isBefore(now.add(const Duration(days: 2)))) {
      final len = Duration(minutes: [30, 45, 60, 90, 120][k % 5]);
      final title = shows[k % shows.length];
      x.writeln('<programme start="${t(s)}" stop="${t(s.add(len))}" channel="${ids[c]}">'
          '<title>$title</title><desc>Episode ${k + 1} of $title on ${ids[c]}.</desc></programme>');
      s = s.add(len);
      k++;
    }
  }
  x.writeln('</tv>');
  File(xmlPath).writeAsStringSync(x.toString());
  stdout.writeln('wrote ${p.join(dir, 'test_playlist.m3u')} and $xmlPath');
}
