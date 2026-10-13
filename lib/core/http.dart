import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const defaultUserAgent = 'IPTVPlayer/1.0 (Windows; Flutter) libmpv';

class HttpException2 implements Exception {
  HttpException2(this.message, {this.statusCode});
  final String message;
  final int? statusCode;
  @override
  String toString() => message;
}

HttpClient createHttpClient({String? userAgent}) {
  final c = HttpClient()
    ..connectionTimeout = const Duration(seconds: 20)
    ..idleTimeout = const Duration(seconds: 15)
    ..autoUncompress = true
    ..userAgent = userAgent ?? defaultUserAgent;
  return c;
}

bool isLocalPath(String url) {
  final uri = Uri.tryParse(url);
  if (uri != null && uri.scheme == 'file') return true;
  if (RegExp(r'^[a-zA-Z]:[\\/]').hasMatch(url)) return true; // C:\...
  if (url.startsWith('/') || url.startsWith(r'\\')) return true;
  return false;
}

/// Opens [url] (http(s) or a local file path) and returns the body as bytes.
///
/// Gzip-compressed files (`.xml.gz`, detected by magic bytes) are
/// decompressed transparently while streaming.
Future<Stream<List<int>>> openStream(
  String url, {
  HttpClient? client,
  Map<String, String> headers = const {},
  void Function(int received, int? total)? onProgress,
}) async {
  Stream<List<int>> raw;
  int? total;

  if (isLocalPath(url)) {
    final uri = Uri.tryParse(url);
    final file =
        (uri != null && uri.scheme == 'file') ? File.fromUri(uri) : File(url);
    if (!await file.exists()) {
      throw HttpException2('File not found: ${file.path}');
    }
    total = await file.length();
    raw = file.openRead();
  } else {
    final uri = Uri.parse(url);
    final c = client ?? createHttpClient();
    final req = await c.getUrl(uri).timeout(const Duration(seconds: 30));
    headers.forEach(req.headers.set);
    final res = await req.close().timeout(const Duration(seconds: 60));
    if (res.statusCode >= 400) {
      await res.drain<void>();
      throw HttpException2(
        'Server returned HTTP ${res.statusCode} for ${uri.host}',
        statusCode: res.statusCode,
      );
    }
    total = res.contentLength > 0 ? res.contentLength : null;
    raw = res;
  }

  var received = 0;
  final counted = raw.map((chunk) {
    received += chunk.length;
    onProgress?.call(received, total);
    return chunk;
  });
  return _maybeGunzip(counted);
}

/// Peeks at the first bytes; if they're gzip magic, decompress the stream.
Stream<List<int>> _maybeGunzip(Stream<List<int>> input) async* {
  final it = StreamIterator(input);
  final head = BytesBuilder(copy: false);
  final buffered = <List<int>>[];
  while (head.length < 2 && await it.moveNext()) {
    head.add(it.current);
    buffered.add(it.current);
  }
  final bytes = head.toBytes();
  final isGzip = bytes.length >= 2 && bytes[0] == 0x1f && bytes[1] == 0x8b;

  Stream<List<int>> rest() async* {
    yield* Stream.fromIterable(buffered);
    while (await it.moveNext()) {
      yield it.current;
    }
  }

  if (isGzip) {
    yield* rest().transform(gzip.decoder);
  } else {
    yield* rest();
  }
}

/// Streams [url] into [target] (decompressed). Imports parse from local disk
/// so DB write locks are never held while waiting on a slow network.
Future<int> downloadToFile(
  String url,
  File target, {
  HttpClient? client,
  Map<String, String> headers = const {},
  void Function(int received, int? total)? onProgress,
}) async {
  final stream = await openStream(url,
      client: client, headers: headers, onProgress: onProgress);
  final sink = target.openWrite();
  var n = 0;
  try {
    await for (final chunk in stream) {
      n += chunk.length;
      sink.add(chunk);
    }
  } finally {
    await sink.close();
  }
  return n;
}

/// GET + JSON decode. Call from an isolate for big payloads (Xtream stream
/// lists can be tens of MB).
Future<Object?> getJson(
  String url, {
  HttpClient? client,
  Map<String, String> headers = const {},
  Duration timeout = const Duration(seconds: 90),
}) async {
  final stream = await openStream(url, client: client, headers: headers);
  final text = await const Utf8Decoder(allowMalformed: true)
      .bind(stream)
      .join()
      .timeout(timeout);
  final trimmed = text.trimLeft();
  if (trimmed.isEmpty) return null;
  if (!(trimmed.startsWith('{') || trimmed.startsWith('['))) {
    throw HttpException2('Server did not return JSON (check the URL)');
  }
  return jsonDecode(trimmed);
}
