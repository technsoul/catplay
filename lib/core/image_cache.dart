import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:path/path.dart' as p;

/// Disk + memory cached network image for channel logos and posters.
///
/// Playlists reference tens of thousands of logos, so downloads are limited
/// to a few at a time and failed URLs are not retried during the session.
class CachedNetImage extends ImageProvider<CachedNetImage> {
  const CachedNetImage(this.url);

  final String url;

  static String? _dir;
  static final _failed = <String>{};
  static final _limiter = _Limiter(6);
  static HttpClient? _client;

  static void init(String cacheDir) {
    _dir = cacheDir;
    Directory(cacheDir).createSync(recursive: true);
  }

  static Future<int> cacheSize() async {
    final d = _dir;
    if (d == null) return 0;
    var total = 0;
    await for (final e in Directory(d).list()) {
      if (e is File) total += await e.length();
    }
    return total;
  }

  static Future<void> clear() async {
    final d = _dir;
    if (d == null) return;
    await for (final e in Directory(d).list()) {
      try {
        await e.delete(recursive: true);
      } catch (_) {}
    }
    _failed.clear();
    PaintingBinding.instance.imageCache.clear();
  }

  @override
  Future<CachedNetImage> obtainKey(ImageConfiguration configuration) =>
      SynchronousFuture(this);

  @override
  ImageStreamCompleter loadImage(CachedNetImage key, ImageDecoderCallback decode) =>
      OneFrameImageStreamCompleter(_load(decode).then((img) => ImageInfo(image: img)));

  Future<ui.Image> _load(ImageDecoderCallback decode) async {
    if (_failed.contains(url)) throw StateError('failed before: $url');
    final bytes = await _bytes();
    try {
      final buffer = await ui.ImmutableBuffer.fromUint8List(bytes);
      final codec = await decode(buffer);
      final frame = await codec.getNextFrame();
      return frame.image;
    } catch (e) {
      _failed.add(url);
      final f = _file;
      if (f != null && f.existsSync()) f.deleteSync();
      rethrow;
    }
  }

  File? get _file {
    final d = _dir;
    if (d == null) return null;
    return File(p.join(d, sha1.convert(utf8.encode(url)).toString()));
  }

  Future<Uint8List> _bytes() async {
    final f = _file;
    if (f != null && await f.exists()) return f.readAsBytes();

    return _limiter.run(() async {
      final uri = Uri.tryParse(url);
      if (uri == null || !(uri.scheme == 'http' || uri.scheme == 'https')) {
        _failed.add(url);
        throw StateError('bad image url');
      }
      try {
        final client = _client ??= (HttpClient()
          ..connectionTimeout = const Duration(seconds: 10)
          ..maxConnectionsPerHost = 4);
        final req = await client.getUrl(uri).timeout(const Duration(seconds: 10));
        final res = await req.close().timeout(const Duration(seconds: 15));
        if (res.statusCode != 200) {
          await res.drain<void>();
          throw HttpException('HTTP ${res.statusCode}');
        }
        final bytes = await consolidateHttpClientResponseBytes(res)
            .timeout(const Duration(seconds: 20));
        if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
          throw const HttpException('bad size');
        }
        if (f != null) {
          // Write atomically so a crash never leaves a half file.
          final tmp = File('${f.path}.part');
          await tmp.writeAsBytes(bytes, flush: false);
          await tmp.rename(f.path);
        }
        return bytes;
      } catch (_) {
        _failed.add(url);
        rethrow;
      }
    });
  }

  @override
  bool operator ==(Object other) => other is CachedNetImage && other.url == url;

  @override
  int get hashCode => url.hashCode;
}

class _Limiter {
  _Limiter(this.max);
  final int max;
  int _running = 0;
  final _waiting = Queue<Completer<void>>();

  Future<T> run<T>(Future<T> Function() task) async {
    if (_running >= max) {
      final c = Completer<void>();
      _waiting.add(c);
      await c.future;
    }
    _running++;
    try {
      return await task();
    } finally {
      _running--;
      if (_waiting.isNotEmpty) _waiting.removeFirst().complete();
    }
  }
}
