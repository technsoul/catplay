import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path/path.dart' as p;

import '../app/providers.dart';
import '../core/http.dart';
import '../core/logging.dart';
import '../core/models.dart';

enum DownloadStatus { queued, downloading, paused, done, failed }

/// A movie or episode saved to disk for offline playback.
class DownloadTask {
  DownloadTask({
    required this.sourceId,
    required this.key,
    required this.kind,
    required this.title,
    required this.url,
    required this.path,
    this.subtitle,
    this.logo,
    this.headers = const {},
    this.status = DownloadStatus.queued,
    this.received = 0,
    this.total,
    this.speed = 0,
    this.error,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  final int sourceId;
  final String key;
  final ItemKind kind;
  final String title;
  final String? subtitle;
  final String? logo;
  final String url;
  final Map<String, String> headers;
  final String path;
  final DownloadStatus status;
  final int received;
  final int? total;
  final double speed; // bytes/s while downloading
  final String? error;
  final DateTime createdAt;

  String get id => '$sourceId|$key';
  bool get isActive => status == DownloadStatus.queued || status == DownloadStatus.downloading;
  double? get fraction => total == null || total == 0 ? null : (received / total!).clamp(0, 1);

  DownloadTask copyWith({
    DownloadStatus? status,
    int? received,
    int? total,
    double? speed,
    String? error,
  }) =>
      DownloadTask(
        sourceId: sourceId,
        key: key,
        kind: kind,
        title: title,
        subtitle: subtitle,
        logo: logo,
        url: url,
        headers: headers,
        path: path,
        status: status ?? this.status,
        received: received ?? this.received,
        total: total ?? this.total,
        speed: speed ?? this.speed,
        error: error,
        createdAt: createdAt,
      );

  Map<String, Object?> toJson() => {
        'sourceId': sourceId,
        'key': key,
        'kind': kind.index,
        'title': title,
        'subtitle': subtitle,
        'logo': logo,
        'url': url,
        'headers': headers,
        'path': path,
        'status': status.name,
        'received': received,
        'total': total,
        'error': error,
        'createdAt': createdAt.millisecondsSinceEpoch,
      };

  factory DownloadTask.fromJson(Map<String, dynamic> j) => DownloadTask(
        sourceId: j['sourceId'] as int,
        key: j['key'] as String,
        kind: ItemKind.values[j['kind'] as int],
        title: j['title'] as String,
        subtitle: j['subtitle'] as String?,
        logo: j['logo'] as String?,
        url: j['url'] as String,
        headers: (j['headers'] as Map?)?.cast<String, String>() ?? const {},
        path: j['path'] as String,
        status: DownloadStatus.values.byName(j['status'] as String),
        received: j['received'] as int? ?? 0,
        total: j['total'] as int?,
        error: j['error'] as String?,
        createdAt: DateTime.fromMillisecondsSinceEpoch(j['createdAt'] as int),
      );
}

/// Whether [url] is a single file that can be saved (not an HLS playlist).
bool isDownloadable(String? url) {
  if (url == null || isLocalPath(url)) return false;
  final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
  return !path.endsWith('.m3u8') && !path.endsWith('.m3u');
}

/// Queue of movie/episode downloads, persisted to `downloads.json`.
///
/// One file downloads at a time: most providers allow a single connection,
/// and a second one would kick out whatever is playing.
class DownloadManager extends Notifier<List<DownloadTask>> {
  static const _maxConcurrent = 1;

  final _clients = <String, HttpClient>{};
  final _stopping = <String>{};

  String get _dir => ref.read(appPathsProvider).downloads;
  File get _index => File(ref.read(appPathsProvider).downloadsIndex);

  @override
  List<DownloadTask> build() {
    ref.onDispose(() {
      for (final c in _clients.values) {
        c.close(force: true);
      }
    });
    var tasks = <DownloadTask>[];
    try {
      if (_index.existsSync()) {
        tasks = [
          for (final j in jsonDecode(_index.readAsStringSync()) as List)
            DownloadTask.fromJson((j as Map).cast<String, dynamic>()),
        ];
      }
    } catch (e, st) {
      AppLog.error('Downloads', e, st);
    }
    // Interrupted by the last exit: pick up where they left off.
    tasks = [
      for (final t in tasks)
        t.status == DownloadStatus.downloading ? t.copyWith(status: DownloadStatus.queued) : t,
    ];
    Future.microtask(_pump);
    return tasks;
  }

  DownloadTask? find(int sourceId, String key) =>
      state.where((t) => t.sourceId == sourceId && t.key == key).firstOrNull;

  /// The saved file for an item, if it finished downloading and still exists.
  String? localPath(int sourceId, String key) {
    final t = find(sourceId, key);
    if (t == null || t.status != DownloadStatus.done) return null;
    return File(t.path).existsSync() ? t.path : null;
  }

  /// Queues a download; does nothing if the item is already queued or saved.
  Future<void> add({
    required int sourceId,
    required String key,
    required ItemKind kind,
    required String title,
    required String url,
    String? subtitle,
    String? logo,
    Map<String, String> headers = const {},
    String? folder,
  }) async {
    final existing = find(sourceId, key);
    if (existing != null) {
      if (existing.status == DownloadStatus.paused || existing.status == DownloadStatus.failed) {
        resume(existing.id);
      }
      return;
    }
    final ext = _extension(url);
    final dir = folder == null ? _dir : p.join(_dir, _safeName(folder));
    final path = _uniquePath(p.join(dir, '${_safeName(title)}.$ext'));
    _put(DownloadTask(
      sourceId: sourceId,
      key: key,
      kind: kind,
      title: title,
      subtitle: subtitle,
      logo: logo,
      url: url,
      headers: headers,
      path: path,
    ));
    _save();
    _pump();
  }

  Future<void> addItem(MediaItem item) async {
    final url = item.url;
    if (url == null) return;
    await add(
      sourceId: item.sourceId,
      key: item.key,
      kind: item.kind,
      title: item.name,
      url: url,
      logo: item.logo,
      headers: item.headers,
    );
  }

  Future<void> addEpisode(MediaItem series, Episode e, {String? cover}) => add(
        sourceId: series.sourceId,
        key: 'ep:${e.id}',
        kind: ItemKind.series,
        title: episodeTitle(e),
        subtitle: series.name,
        logo: e.image ?? cover ?? series.logo,
        url: e.url,
        folder: series.name,
      );

  void pause(String id) {
    final t = _byId(id);
    if (t == null || !t.isActive) return;
    _stop(id);
    _put(t.copyWith(status: DownloadStatus.paused, speed: 0));
    _save();
    _pump();
  }

  void resume(String id) {
    final t = _byId(id);
    if (t == null || t.isActive || t.status == DownloadStatus.done) return;
    _put(t.copyWith(status: DownloadStatus.queued));
    _save();
    _pump();
  }

  /// Removes the download and deletes its file (finished or partial).
  Future<void> remove(String id) async {
    final t = _byId(id);
    if (t == null) return;
    _stop(id);
    state = [for (final x in state) if (x.id != id) x];
    _save();
    for (final f in [File(t.path), File('${t.path}.part')]) {
      try {
        if (await f.exists()) await f.delete();
      } catch (e) {
        AppLog.error('Downloads', e);
      }
    }
    _pump();
  }

  DownloadTask? _byId(String id) => state.where((t) => t.id == id).firstOrNull;

  void _put(DownloadTask t) {
    final i = state.indexWhere((x) => x.id == t.id);
    state = i < 0 ? [...state, t] : ([...state]..[i] = t);
  }

  void _stop(String id) {
    final c = _clients.remove(id);
    if (c == null) return;
    _stopping.add(id);
    c.close(force: true);
  }

  void _pump() {
    var running = state.where((t) => t.status == DownloadStatus.downloading).length;
    for (final t in state) {
      if (running >= _maxConcurrent) break;
      if (t.status != DownloadStatus.queued) continue;
      running++;
      _put(t.copyWith(status: DownloadStatus.downloading));
      unawaited(_run(t.id));
    }
  }

  Future<void> _run(String id) async {
    var t = _byId(id)!;
    final source = await ref.read(repositoryProvider).source(t.sourceId);
    final settings = ref.read(settingsProvider);
    final ua = (source?.userAgent?.isNotEmpty ?? false)
        ? source!.userAgent
        : (settings.userAgent.isNotEmpty ? settings.userAgent : null);
    final client = createHttpClient(userAgent: ua)..autoUncompress = false;
    _clients[id] = client;
    final part = File('${t.path}.part');
    IOSink? sink;
    try {
      await part.parent.create(recursive: true);
      var start = await part.exists() ? await part.length() : 0;
      final req = await client.getUrl(Uri.parse(t.url)).timeout(const Duration(seconds: 30));
      t.headers.forEach(req.headers.set);
      if (start > 0) req.headers.set(HttpHeaders.rangeHeader, 'bytes=$start-');
      final res = await req.close().timeout(const Duration(seconds: 60));
      if (res.statusCode == 416 && start > 0) {
        // Nothing left to fetch: the partial file is already complete.
        await res.drain<void>();
      } else {
        if (res.statusCode >= 400) {
          await res.drain<void>();
          throw HttpException2('Server returned HTTP ${res.statusCode}', statusCode: res.statusCode);
        }
        if (start > 0 && res.statusCode != HttpStatus.partialContent) start = 0; // range ignored
        final total = res.contentLength > 0 ? start + res.contentLength : null;
        sink = part.openWrite(mode: start > 0 ? FileMode.append : FileMode.write);
        var received = start;
        var lastBytes = start;
        final watch = Stopwatch()..start();
        t = t.copyWith(received: received, total: total);
        _put(t);
        await for (final chunk in res) {
          sink.add(chunk);
          received += chunk.length;
          if (watch.elapsedMilliseconds >= 500) {
            final speed = (received - lastBytes) * 1000 / watch.elapsedMilliseconds;
            lastBytes = received;
            watch.reset();
            if (_byId(id)?.status == DownloadStatus.downloading) {
              _put(t = t.copyWith(received: received, speed: speed));
            }
          }
        }
        await sink.close();
        sink = null;
        if (total != null && received < total) {
          throw const _IncompleteDownload();
        }
        t = t.copyWith(received: received, total: total ?? received);
      }
      final target = File(t.path);
      if (await target.exists()) await target.delete();
      await part.rename(t.path);
      if (_byId(id) != null) _put(t.copyWith(status: DownloadStatus.done, speed: 0));
      AppLog.info('Downloaded ${t.title} → ${t.path}');
    } catch (e, st) {
      await sink?.close().catchError((_) {});
      if (!_stopping.contains(id)) {
        AppLog.error('Downloads', e, st);
        final cur = _byId(id);
        if (cur != null) {
          final received = await part.exists() ? await part.length() : 0;
          _put(cur.copyWith(
              status: DownloadStatus.failed, received: received, speed: 0, error: _friendly(e)));
        }
      }
    } finally {
      _stopping.remove(id);
      if (_clients[id] == client) _clients.remove(id);
      client.close(force: true);
      _save();
      _pump();
    }
  }

  static String _friendly(Object e) {
    if (e is HttpException2) return e.message;
    if (e is _IncompleteDownload) return 'Connection dropped before the file finished';
    if (e is TimeoutException) return 'The server did not respond';
    if (e is SocketException) return 'Network error: ${e.message}';
    if (e is FileSystemException) return 'Could not write the file: ${e.osError?.message ?? e.message}';
    return '$e';
  }

  Timer? _saveTimer;
  void _save() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(milliseconds: 300), () async {
      try {
        await _index.parent.create(recursive: true);
        await _index.writeAsString(jsonEncode([for (final t in state) t.toJson()]));
      } catch (e, st) {
        AppLog.error('Downloads', e, st);
      }
    });
  }

  String _uniquePath(String path) {
    final taken = {for (final t in state) t.path};
    final base = p.withoutExtension(path);
    final ext = p.extension(path);
    var candidate = path;
    for (var n = 2; taken.contains(candidate) || File(candidate).existsSync(); n++) {
      candidate = '$base ($n)$ext';
    }
    return candidate;
  }

  static String _extension(String url) {
    final ext = p.extension(Uri.tryParse(url)?.path ?? '').replaceFirst('.', '').toLowerCase();
    return RegExp(r'^[a-z0-9]{2,4}$').hasMatch(ext) ? ext : 'mp4';
  }

  static String _safeName(String name) {
    final s = name
        .replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1F]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .replaceAll(RegExp(r'[. ]+$'), '');
    if (s.isEmpty) return 'Untitled';
    return s.length > 120 ? s.substring(0, 120).trim() : s;
  }
}

class _IncompleteDownload implements Exception {
  const _IncompleteDownload();
}

String episodeTitle(Episode e) =>
    'S${e.season.toString().padLeft(2, '0')}E${e.number.toString().padLeft(2, '0')} · ${e.title}';

final downloadsProvider =
    NotifierProvider<DownloadManager, List<DownloadTask>>(DownloadManager.new);

/// The download for one item (null when it was never downloaded).
final downloadProvider = Provider.family<DownloadTask?, String>((ref, id) =>
    ref.watch(downloadsProvider.select((l) => l.where((t) => t.id == id).firstOrNull)));

String formatBytes(num bytes) {
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  var v = bytes.toDouble();
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(i < 2 ? 0 : 1)} ${units[i]}';
}

/// Shows [path] in the system file manager.
Future<void> revealInFolder(String path) async {
  try {
    if (Platform.isAndroid || Platform.isIOS) return;
    if (Platform.isWindows) {
      final isFile = File(path).existsSync();
      await Process.run('explorer', [if (isFile) '/select,$path' else path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [if (File(path).existsSync()) '-R', path]);
    } else {
      await Process.run('xdg-open', [File(path).existsSync() ? p.dirname(path) : path]);
    }
  } catch (e) {
    AppLog.error('Downloads', e);
  }
}
