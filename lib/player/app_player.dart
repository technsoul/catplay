import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' hide Playable;
import 'package:media_kit_video/media_kit_video.dart';

import '../app/providers.dart';
import '../core/http.dart';
import '../core/logging.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../data/repository.dart';

enum PlayPhase { idle, loading, playing, reconnecting, error }

@immutable
class PlayerUiState {
  const PlayerUiState({
    this.playable,
    this.phase = PlayPhase.idle,
    this.error,
    this.attempt = 0,
    this.zapIndex,
  });

  final Playable? playable;
  final PlayPhase phase;
  final String? error;
  final int attempt;
  final int? zapIndex;

  PlayerUiState copyWith({
    Playable? playable,
    PlayPhase? phase,
    String? error,
    int? attempt,
    int? zapIndex,
  }) =>
      PlayerUiState(
        playable: playable ?? this.playable,
        phase: phase ?? this.phase,
        error: error,
        attempt: attempt ?? this.attempt,
        zapIndex: zapIndex ?? this.zapIndex,
      );
}

/// Turns a list item into something playable (null for series containers).
Future<Playable?> playableFor(Repository repo, MediaItem item, {String? subtitle}) async {
  final url = item.url;
  if (url == null) return null;
  final resume = item.kind == ItemKind.live
      ? null
      : await repo.resumePosition(item.sourceId, item.key);
  return Playable(
    sourceId: item.sourceId,
    key: item.key,
    kind: item.kind,
    title: item.name,
    subtitle: subtitle,
    url: url,
    logo: item.logo,
    headers: item.headers,
    epgId: item.epgId,
    resumeFrom: resume,
  );
}

/// The app's single playback engine (libmpv via media_kit).
///
/// One instance is shared by the Live TV preview and the full-screen player
/// so switching between them never restarts the stream.
class AppPlayer {
  AppPlayer(this._ref) {
    final s = _ref.read(settingsProvider);
    player = Player(
      configuration: PlayerConfiguration(
        title: 'CAT',
        bufferSize: 64 * 1024 * 1024,
        logLevel: kDebugMode ? MPVLogLevel.info : MPVLogLevel.warn,
      ),
    );
    video = VideoController(
      player,
      configuration: VideoControllerConfiguration(
        enableHardwareAcceleration: s.hardwareDecoding,
        hwdec: s.hardwareDecoding ? 'auto-safe' : 'no',
      ),
    );
    _ready = _configure(s);
    _subs.addAll([
      player.stream.error.listen(_onError),
      player.stream.completed.listen((done) {
        if (done && (state.value.playable?.isLive ?? false)) {
          _onError('Stream ended');
        }
      }),
      player.stream.playing.listen((_) => _markPlayingIfReady()),
      player.stream.buffering.listen((_) => _markPlayingIfReady()),
      player.stream.position.listen(_onPosition),
      player.stream.volume.listen((v) => _volume = v),
      // mpv warnings/errors go to the app log for diagnosing streams.
      player.stream.log.listen((l) => AppLog.info('mpv [${l.prefix}] ${l.level}: ${l.text.trim()}')),
    ]);
  }

  final Ref _ref;
  late final Player player;
  late final VideoController video;
  late final Future<void> _ready;
  final _subs = <StreamSubscription>[];

  final state = ValueNotifier(const PlayerUiState());

  ItemQuery? _zapQuery;
  Timer? _retryTimer;
  Timer? _saveTimer;
  // Progress tracking for the current open (see [_onPosition]).
  Duration? _lastPos;
  Duration _progress = Duration.zero;
  DateTime _ignorePosUntil = DateTime(0);
  DateTime? _stableSince;
  bool _resumeApplied = false;
  bool _everPlayed = false;
  double _volume = 100;
  int _openToken = 0;

  Repository get _repo => _ref.read(repositoryProvider);

  Future<void> _configure(AppSettings s) async {
    final p = player.platform;
    if (p is! NativePlayer) return;
    Future<void> set(String k, String v) async {
      try {
        await p.setProperty(k, v);
      } catch (e) {
        debugPrint('mpv property $k failed: $e');
      }
    }

    await set('network-timeout', '20');
    await set('cache', 'yes');
    await set('cache-secs', '${s.cacheSeconds}');
    await set('demuxer-max-bytes', '96MiB');
    await set('demuxer-max-back-bytes', '32MiB');
    await set('demuxer-readahead-secs', '${s.cacheSeconds}');
    await set('hls-bitrate', 'max');
    // Deliberately no `stream-lavf-o=reconnect=…`: with HLS over TLS, FFmpeg's
    // internal reconnect loops stalled channel changes for 20–40 s. Dropped
    // streams are reopened by [_onError] with backoff instead.
    await set('user-agent', s.userAgent.isNotEmpty ? s.userAgent : defaultUserAgent);
    await player.setVolume(s.volume);
  }

  /// Opens [p]. [zapQuery]/[zapIndex] describe the list it came from so
  /// channel up/down can move through it.
  Future<void> open(Playable p, {ItemQuery? zapQuery, int? zapIndex}) async {
    await _ready;
    await _saveProgress();
    _retryTimer?.cancel();
    _zapQuery = zapQuery ?? (p.isLive ? _zapQuery : null);
    _resumeApplied = p.resumeFrom == null;
    _everPlayed = false;
    _stableSince = null;
    state.value = PlayerUiState(
      playable: p,
      phase: PlayPhase.loading,
      zapIndex: zapIndex ?? (p.isLive ? state.value.zapIndex : null),
    );
    await _openMedia(p);

    _saveTimer?.cancel();
    if (p.isLive) {
      unawaited(_repo.saveProgress(p, Duration.zero, Duration.zero));
      unawaited(_ref.read(settingsProvider.notifier).update((s) => s.copyWith(lastChannelKey: '${p.sourceId}|${p.key}')));
    } else {
      _saveTimer = Timer.periodic(const Duration(seconds: 10), (_) => _saveProgress());
    }
  }

  Future<void> _openMedia(Playable p) async {
    final token = ++_openToken;
    final headers = <String, String>{...p.headers};
    final source = await _repo.source(p.sourceId);
    if (source?.userAgent != null && source!.userAgent!.isNotEmpty) {
      headers.putIfAbsent('User-Agent', () => source.userAgent!);
    }
    if (token != _openToken) return; // superseded by a newer open
    // Position events from the previous media can still arrive right after
    // switching; only progress measured within this open counts.
    _lastPos = null;
    _progress = Duration.zero;
    _ignorePosUntil = DateTime.now().add(const Duration(milliseconds: 700));
    await player.open(
      Media(p.url, httpHeaders: headers.isEmpty ? null : headers),
      play: true,
    );
  }

  void _markPlayingIfReady() {
    final s = state.value;
    if (s.playable == null) return;
    // mpv reports "playing" as soon as play is requested, so also require
    // real progress before leaving the loading state.
    if (player.state.playing && !player.state.buffering &&
        _progress > const Duration(milliseconds: 300) &&
        (s.phase == PlayPhase.loading || s.phase == PlayPhase.reconnecting)) {
      state.value = s.copyWith(phase: PlayPhase.playing, attempt: s.attempt);
    }
  }

  void _onPosition(Duration pos) {
    final s = state.value;
    final p = s.playable;
    if (p == null) return;
    if (!_resumeApplied && player.state.duration > Duration.zero) {
      _resumeApplied = true;
      if (p.resumeFrom! < player.state.duration) {
        unawaited(player.seek(p.resumeFrom!));
      }
    }
    if (DateTime.now().isBefore(_ignorePosUntil)) return;
    final last = _lastPos;
    _lastPos = pos;
    if (last == null) return;
    final delta = pos - last;
    // Forward movement of less than a few seconds is playback (bigger jumps
    // are seeks or a new stream timeline).
    if (delta > Duration.zero && delta < const Duration(seconds: 3)) {
      _progress += delta;
      _stableSince ??= DateTime.now();
      // Playing smoothly for 30 s: forget earlier reconnect attempts.
      if (s.attempt > 0 && DateTime.now().difference(_stableSince!).inSeconds > 30) {
        state.value = s.copyWith(attempt: 0);
      }
      if (_progress > const Duration(seconds: 1)) _everPlayed = true;
      if (s.phase != PlayPhase.playing && !player.state.buffering &&
          _progress > const Duration(milliseconds: 300)) {
        state.value = s.copyWith(phase: PlayPhase.playing, attempt: s.attempt);
      }
    }
  }

  void _onError(String error) {
    final s = state.value;
    final p = s.playable;
    if (p == null) return;
    debugPrint('player error: $error');
    _stableSince = null;
    // Live streams drop often; retry with backoff before giving up. A
    // stream that never started (offline / 404) only gets two quick tries.
    final maxAttempts = _everPlayed ? 6 : 2;
    if (p.isLive && s.attempt < maxAttempts) {
      final attempt = s.attempt + 1;
      final delay = Duration(seconds: [1, 2, 3, 5, 8, 10][attempt - 1]);
      state.value = s.copyWith(phase: PlayPhase.reconnecting, attempt: attempt);
      _retryTimer?.cancel();
      _retryTimer = Timer(delay, () {
        if (state.value.playable == p) unawaited(_openMedia(p));
      });
      return;
    }
    state.value = s.copyWith(phase: PlayPhase.error, error: _friendly(error));
  }

  static String _friendly(String e) {
    final l = e.toLowerCase();
    if (l.contains('403') || l.contains('forbidden')) {
      return 'Access denied by the server (403). Your subscription may have expired or reached its connection limit.';
    }
    if (l.contains('404')) return 'Stream not found (404). The channel may be offline.';
    if (l.contains('401')) return 'Unauthorized (401). Check your login.';
    if (l.contains('timed out') || l.contains('timeout')) return 'The stream timed out.';
    if (l.contains('failed to open') || l.contains('loading failed')) {
      return 'Could not open the stream. It may be offline.';
    }
    return e;
  }

  Future<void> retry() async {
    final p = state.value.playable;
    if (p == null) return;
    state.value = state.value.copyWith(phase: PlayPhase.loading, attempt: 0);
    await _openMedia(p);
  }

  /// Channel up/down within the list the channel was opened from.
  Future<bool> zap(int delta) async {
    final q = _zapQuery;
    final idx = state.value.zapIndex;
    if (q == null || idx == null) return false;
    final item = await _repo.itemAt(q, idx + delta);
    if (item == null) return false;
    final p = await playableFor(_repo, item);
    if (p == null) return false;
    final total = await _repo.countItems(q);
    await open(p, zapQuery: q, zapIndex: ((idx + delta) % total + total) % total);
    return true;
  }

  bool get canZap => _zapQuery != null && state.value.zapIndex != null;

  Future<void> _saveProgress() async {
    final p = state.value.playable;
    if (p == null || p.isLive) return;
    final pos = player.state.position;
    final dur = player.state.duration;
    if (pos < const Duration(seconds: 5)) return;
    await _repo.saveProgress(p, pos, dur);
  }

  Future<void> setVolume(double v) async {
    await player.setVolume(v.clamp(0, 100));
  }

  Future<void> persistVolume() =>
      _ref.read(settingsProvider.notifier).update((s) => s.copyWith(volume: _volume));

  Future<void> stop() async {
    await _saveProgress();
    _retryTimer?.cancel();
    _saveTimer?.cancel();
    _zapQuery = null;
    ++_openToken;
    await player.stop();
    state.value = const PlayerUiState();
  }

  Future<void> dispose() async {
    await stop();
    for (final s in _subs) {
      await s.cancel();
    }
    await player.dispose();
  }
}

final appPlayerProvider = Provider<AppPlayer>((ref) {
  final p = AppPlayer(ref);
  ref.onDispose(p.dispose);
  return p;
});
