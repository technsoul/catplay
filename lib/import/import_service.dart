import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../app/providers.dart';
import '../core/models.dart';
import 'import_job.dart';

/// UI-facing state of one source's import.
@immutable
class ImportStatus {
  const ImportStatus({
    required this.sourceId,
    required this.scope,
    this.message = 'Waiting…',
    this.fraction,
    this.running = false,
    this.queued = true,
    this.error,
    this.finished = false,
  });

  final int sourceId;
  final ImportScope scope;
  final String message;
  final double? fraction;
  final bool running;
  final bool queued;
  final String? error;
  final bool finished;

  ImportStatus copyWith({
    String? message,
    double? fraction,
    bool? running,
    bool? queued,
    String? error,
    bool? finished,
  }) =>
      ImportStatus(
        sourceId: sourceId,
        scope: scope,
        message: message ?? this.message,
        fraction: fraction,
        running: running ?? this.running,
        queued: queued ?? this.queued,
        error: error ?? this.error,
        finished: finished ?? this.finished,
      );
}

/// Runs imports one at a time (they're CPU/disk heavy and share the DB write
/// lock) in background isolates, exposing progress per source.
class ImportController extends Notifier<Map<int, ImportStatus>> {
  final _queue = Queue<(int, ImportScope)>();
  bool _busy = false;

  @override
  Map<int, ImportStatus> build() => const {};

  bool isActive(int sourceId) {
    final s = state[sourceId];
    return s != null && (s.running || s.queued) && !s.finished;
  }

  bool get anyRunning => state.values.any((s) => s.running);

  /// Queues an import. Ignored if this source is already queued/running.
  void enqueue(int sourceId, {ImportScope scope = ImportScope.all}) {
    if (isActive(sourceId)) return;
    _queue.add((sourceId, scope));
    _set(ImportStatus(sourceId: sourceId, scope: scope));
    _pump();
  }

  void dismiss(int sourceId) {
    final s = state[sourceId];
    if (s == null || s.running) return;
    state = {...state}..remove(sourceId);
  }

  void _set(ImportStatus s) => state = {...state, s.sourceId: s};

  Future<void> _pump() async {
    if (_busy || _queue.isEmpty) return;
    _busy = true;
    final (sourceId, scope) = _queue.removeFirst();
    try {
      await _run(sourceId, scope);
    } finally {
      _busy = false;
      unawaited(_pump());
    }
  }

  Future<void> _run(int sourceId, ImportScope scope) async {
    final repo = ref.read(repositoryProvider);
    final paths = ref.read(appPathsProvider);
    final settings = ref.read(settingsProvider);
    final db = ref.read(databaseProvider);

    final source = await repo.source(sourceId);
    if (source == null) {
      state = {...state}..remove(sourceId);
      return;
    }
    final password = source.type == SourceType.xtream
        ? await ref.read(secretsProvider).password(sourceId)
        : null;

    _set(ImportStatus(
        sourceId: sourceId, scope: scope, running: true, queued: false,
        message: 'Starting…'));

    final req = ImportRequest(
      dbPath: db.path,
      tempDir: paths.importTemp,
      epgDir: paths.epgDir,
      sourceId: sourceId,
      type: source.type,
      url: source.url,
      scope: scope,
      username: source.username,
      password: password,
      epgUrl: source.epgUrl,
      userAgent: (source.userAgent?.isNotEmpty ?? false)
          ? source.userAgent
          : (settings.userAgent.isNotEmpty ? settings.userAgent : null),
      epgPastHours: settings.epgPastHours,
      epgFutureDays: settings.epgFutureDays,
      liveFormat: settings.liveFormat,
    );

    final port = ReceivePort();
    final exitPort = ReceivePort();
    final done = Completer<void>();
    try {
      await Directory(paths.importTemp).create(recursive: true);
      await Isolate.spawn(importMain, [req, port.sendPort],
          debugName: 'import-$sourceId',
          onExit: exitPort.sendPort,
          onError: port.sendPort);
    } catch (e) {
      _set(state[sourceId]!.copyWith(
          running: false, finished: true, error: '$e', message: 'Failed to start import'));
      port.close();
      exitPort.close();
      return;
    }

    exitPort.listen((_) {
      // Isolate died without a final message (crash / OOM).
      if (!done.isCompleted) {
        _set(state[sourceId]!.copyWith(
            running: false, finished: true,
            error: 'Import stopped unexpectedly', message: 'Import stopped unexpectedly'));
        done.complete();
      }
    });

    port.listen((msg) {
      if (msg is ImportProgress) {
        if (msg.done) {
          final ok = msg.error == null;
          if (!ok) debugPrint('Import $sourceId failed: ${msg.error}');
          _set(state[sourceId]!.copyWith(
            running: false,
            finished: true,
            message: msg.message,
            fraction: ok ? 1 : null,
            error: ok ? null : msg.message,
          ));
          if (!done.isCompleted) done.complete();
        } else {
          _set(state[sourceId]!.copyWith(message: msg.message, fraction: msg.fraction));
        }
      } else if (msg is List && msg.length == 2) {
        // Uncaught isolate error: [message, stack].
        debugPrint('Import isolate error: ${msg[0]}\n${msg[1]}');
        _set(state[sourceId]!.copyWith(
            running: false, finished: true, error: '${msg[0]}', message: '${msg[0]}'));
        if (!done.isCompleted) done.complete();
      }
    });

    await done.future;
    port.close();
    exitPort.close();
    db.notify({'sources', 'items', 'epg', 'favorites'});
    unawaited(repo.cleanupEpgFiles());

    // Clear successful statuses after a moment so the UI calms down.
    if (state[sourceId]?.error == null) {
      Timer(const Duration(seconds: 6), () {
        final s = state[sourceId];
        if (s != null && s.finished && s.error == null) dismiss(sourceId);
      });
    }
  }

  /// Refreshes stale sources/guides according to the user's settings.
  Future<void> refreshStale() async {
    final settings = ref.read(settingsProvider);
    final sources = await ref.read(repositoryProvider).sources();
    final now = DateTime.now();
    for (final s in sources) {
      final playlistStale = s.lastRefresh == null ||
          (settings.autoRefreshHours > 0 &&
              now.difference(s.lastRefresh!).inHours >= settings.autoRefreshHours);
      final epgStale = settings.epgRefreshHours > 0 &&
          (s.lastEpg == null ||
              now.difference(s.lastEpg!).inHours >= settings.epgRefreshHours);
      if (playlistStale) {
        enqueue(s.id, scope: ImportScope.all);
      } else if (epgStale && (s.epgUrl != null || s.type == SourceType.xtream)) {
        enqueue(s.id, scope: ImportScope.epg);
      }
    }
  }
}

final importProvider =
    NotifierProvider<ImportController, Map<int, ImportStatus>>(ImportController.new);
