import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart' hide Playable;
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../app/providers.dart';
import '../core/models.dart';
import '../core/platform.dart';
import '../ui/theme.dart';
import '../ui/widgets.dart';
import 'app_player.dart';
import 'mini_player.dart';

/// Video surface + overlay controls. Used compact (Live TV preview) and
/// full size (player page).
class PlayerView extends ConsumerStatefulWidget {
  const PlayerView({
    super.key,
    this.compact = false,
    this.onExpand,
    this.onBack,
    this.autofocus = false,
  });

  final bool compact;
  final VoidCallback? onExpand;
  final VoidCallback? onBack;
  final bool autofocus;

  @override
  ConsumerState<PlayerView> createState() => _PlayerViewState();
}

class _PlayerViewState extends ConsumerState<PlayerView> {
  bool _controlsVisible = true;
  Timer? _hideTimer;
  BoxFit _fit = BoxFit.contain;
  final _focus = FocusNode(debugLabel: 'player');
  String? _toast;
  Timer? _toastTimer;
  Offset? _doubleTapAt;

  AppPlayer get _p => ref.read(appPlayerProvider);

  @override
  void initState() {
    super.initState();
    _bump();
    // `autofocus` is ignored when something else (a dropdown, a list) still
    // holds focus, so take it explicitly for keyboard shortcuts.
    if (widget.autofocus) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _focus.requestFocus();
      });
    }
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    _toastTimer?.cancel();
    _focus.dispose();
    super.dispose();
  }

  void _bump() {
    if (!_controlsVisible) setState(() => _controlsVisible = true);
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _p.player.state.playing) setState(() => _controlsVisible = false);
    });
  }

  void _flash(String text) {
    setState(() => _toast = text);
    _toastTimer?.cancel();
    _toastTimer = Timer(const Duration(milliseconds: 1200), () {
      if (mounted) setState(() => _toast = null);
    });
  }

  Future<void> _toggleFullscreen() async {
    if (widget.compact) {
      widget.onExpand?.call();
      return;
    }
    if (!isDesktop) return; // TVs and phones are always full screen
    final fs = await windowManager.isFullScreen();
    await windowManager.setFullScreen(!fs);
  }

  Future<void> _zap(int delta) async {
    final ok = await _p.zap(delta);
    if (!ok && mounted) _flash('No more channels');
  }

  void _seekBy(int seconds) {
    final t = _p.player.state.position + Duration(seconds: seconds);
    _p.player.seek(t < Duration.zero ? Duration.zero : t);
    _flash(seconds > 0 ? '+$seconds s' : '−${-seconds} s');
  }

  /// Phones: double-tap the left or right side of the video to seek.
  void _onDoubleTap(double width) {
    final live = _p.state.value.playable?.isLive ?? true;
    final x = _doubleTapAt?.dx;
    if (isTouch && !widget.compact && !live && x != null) {
      if (x < width / 3) return _seekBy(-10);
      if (x > width * 2 / 3) return _seekBy(10);
    }
    _toggleFullscreen();
  }

  Future<void> _volume(double delta) async {
    final v = (_p.player.state.volume + delta).clamp(0.0, 100.0);
    await _p.setVolume(v);
    _flash('Volume ${v.round()}');
    unawaited(_p.persistVolume());
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final live = _p.state.value.playable?.isLive ?? false;
    final k = e.logicalKey;
    _bump();
    if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK ||
        k == LogicalKeyboardKey.select || k == LogicalKeyboardKey.enter ||
        k == LogicalKeyboardKey.mediaPlayPause) {
      _p.player.playOrPause();
    } else if (k == LogicalKeyboardKey.mediaPlay) {
      _p.player.play();
    } else if (k == LogicalKeyboardKey.mediaPause) {
      _p.player.pause();
    } else if (live && k == LogicalKeyboardKey.channelUp) {
      _zap(-1);
    } else if (live && k == LogicalKeyboardKey.channelDown) {
      _zap(1);
    } else if (k == LogicalKeyboardKey.keyF || k == LogicalKeyboardKey.f11) {
      _toggleFullscreen();
    } else if (k == LogicalKeyboardKey.escape || k == LogicalKeyboardKey.goBack) {
      if (!isDesktop) {
        widget.onBack?.call();
        return KeyEventResult.handled;
      }
      windowManager.isFullScreen().then((fs) {
        if (fs) {
          windowManager.setFullScreen(false);
        } else {
          widget.onBack?.call();
        }
      });
    } else if (k == LogicalKeyboardKey.keyP) {
      MiniMode.enter();
    } else if (k == LogicalKeyboardKey.keyM) {
      _p.setVolume(_p.player.state.volume > 0 ? 0 : 100);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _volume(5);
    } else if (k == LogicalKeyboardKey.arrowDown) {
      _volume(-5);
    } else if (live && (k == LogicalKeyboardKey.pageUp || k == LogicalKeyboardKey.arrowLeft)) {
      _zap(-1);
    } else if (live && (k == LogicalKeyboardKey.pageDown || k == LogicalKeyboardKey.arrowRight)) {
      _zap(1);
    } else if (!live && k == LogicalKeyboardKey.arrowRight) {
      _p.player.seek(_p.player.state.position + const Duration(seconds: 10));
      _flash('+10 s');
    } else if (!live && k == LogicalKeyboardKey.arrowLeft) {
      final t = _p.player.state.position - const Duration(seconds: 10);
      _p.player.seek(t < Duration.zero ? Duration.zero : t);
      _flash('−10 s');
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final p = ref.watch(appPlayerProvider);
    return Focus(
      focusNode: _focus,
      autofocus: widget.autofocus,
      onKeyEvent: _onKey,
      child: MouseRegion(
        onHover: (_) => _bump(),
        cursor: _controlsVisible ? SystemMouseCursors.basic : SystemMouseCursors.none,
        child: LayoutBuilder(
          builder: (context, box) => GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: () {
            _focus.requestFocus();
            if (isTouch && _controlsVisible) {
              // Touch: a tap shows or hides the controls; play/pause has
              // its own button.
              _hideTimer?.cancel();
              setState(() => _controlsVisible = false);
            } else if (widget.compact || !_controlsVisible) {
              // While controls are hidden the first click only reveals them, so
              // aiming for a button never pauses the video by accident.
              _bump();
            } else {
              p.player.playOrPause();
            }
          },
          onDoubleTapDown: (d) => _doubleTapAt = d.localPosition,
          onDoubleTap: () => _onDoubleTap(box.maxWidth),
          child: ColoredBox(
            color: Colors.black,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Video(
                  controller: p.video,
                  controls: NoVideoControls,
                  fit: _fit,
                  fill: Colors.black,
                ),
                ValueListenableBuilder(
                  valueListenable: p.state,
                  builder: (_, s, _) => _StatusOverlay(state: s, onRetry: p.retry, compact: widget.compact),
                ),
                if (_toast != null)
                  Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(_toast!, style: const TextStyle(fontSize: 18)),
                    ),
                  ),
                AnimatedOpacity(
                  opacity: _controlsVisible ? 1 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: !_controlsVisible,
                    child: _Controls(
                      compact: widget.compact,
                      fit: _fit,
                      onFit: (f) => setState(() => _fit = f),
                      onFullscreen: _toggleFullscreen,
                      onBack: widget.onBack,
                      onZap: _zap,
                      onSeek: _seekBy,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
        ),
      ),
    );
  }
}

class _StatusOverlay extends StatelessWidget {
  const _StatusOverlay({required this.state, required this.onRetry, required this.compact});
  final PlayerUiState state;
  final VoidCallback onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    switch (state.phase) {
      case PlayPhase.idle:
        return compact
            ? const Center(
                child: Text('Select a channel to start watching',
                    style: TextStyle(color: AppColors.textDim)))
            : const SizedBox.shrink();
      case PlayPhase.loading:
        return const Center(child: CircularProgressIndicator(strokeWidth: 3));
      case PlayPhase.reconnecting:
        return Center(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const CircularProgressIndicator(strokeWidth: 3),
            const SizedBox(height: 12),
            Text('Reconnecting… (attempt ${state.attempt})',
                style: const TextStyle(color: Colors.white70)),
          ]),
        );
      case PlayPhase.error:
        return Center(
          child: Container(
            constraints: const BoxConstraints(maxWidth: 420),
            margin: const EdgeInsets.all(16),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.black87,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Icon(Icons.portable_wifi_off, size: 36, color: AppColors.live),
              const SizedBox(height: 10),
              Text(state.error ?? 'Playback failed', textAlign: TextAlign.center),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('Retry'),
              ),
            ]),
          ),
        );
      case PlayPhase.playing:
        return const _BufferingIndicator();
    }
  }
}

class _BufferingIndicator extends ConsumerWidget {
  const _BufferingIndicator();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final player = ref.watch(appPlayerProvider).player;
    return StreamBuilder<bool>(
      stream: player.stream.buffering,
      initialData: player.state.buffering,
      builder: (_, s) => (s.data ?? false)
          ? const Center(child: CircularProgressIndicator(strokeWidth: 3))
          : const SizedBox.shrink(),
    );
  }
}

class _Controls extends ConsumerWidget {
  const _Controls({
    required this.compact,
    required this.fit,
    required this.onFit,
    required this.onFullscreen,
    required this.onZap,
    required this.onSeek,
    this.onBack,
  });

  final ValueChanged<int> onSeek;
  final bool compact;
  final BoxFit fit;
  final ValueChanged<BoxFit> onFit;
  final VoidCallback onFullscreen;
  final ValueChanged<int> onZap;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final ap = ref.watch(appPlayerProvider);
    final player = ap.player;
    return ValueListenableBuilder(
      valueListenable: ap.state,
      builder: (context, s, _) {
        final p = s.playable;
        final live = p?.isLive ?? true;
        final controls = Column(
          children: [
            if (!compact)
              _Gradient(
                top: true,
                child: Row(children: [
                  IconButton(
                    tooltip: 'Back (Esc)',
                    icon: const Icon(Icons.arrow_back),
                    onPressed: onBack,
                  ),
                  if (p?.logo != null) ...[
                    NetLogo(url: p!.logo, name: p.title, width: 40, height: 30),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(p?.title ?? '',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.titleMedium),
                        if (p != null && live && p.epgId != null)
                          NowPlayingLine(sourceId: p.sourceId, epgId: p.epgId!)
                        else if (p?.subtitle != null)
                          Text(p!.subtitle!,
                              style: const TextStyle(color: AppColors.textDim)),
                      ],
                    ),
                  ),
                ]),
              ),
            Expanded(
              child: isTouch && !compact
                  ? _TouchCenter(player: player, live: live, canZap: ap.canZap, onSeek: onSeek, onZap: onZap)
                  : const SizedBox.shrink(),
            ),
            _Gradient(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!live) _SeekBar(player: player),
                  Row(
                    children: [
                      // Touch full screen has these as big centre buttons.
                      if (!isTouch || compact)
                      StreamBuilder<bool>(
                        stream: player.stream.playing,
                        initialData: player.state.playing,
                        builder: (_, snap) => IconButton(
                          tooltip: 'Play/Pause (Space)',
                          icon: Icon(snap.data == true ? Icons.pause : Icons.play_arrow),
                          onPressed: player.playOrPause,
                        ),
                      ),
                      if (live && ap.canZap && (!isTouch || compact)) ...[
                        IconButton(
                          tooltip: 'Previous channel (Page Up)',
                          icon: const Icon(Icons.skip_previous),
                          onPressed: () => onZap(-1),
                        ),
                        IconButton(
                          tooltip: 'Next channel (Page Down)',
                          icon: const Icon(Icons.skip_next),
                          onPressed: () => onZap(1),
                        ),
                      ],
                      if (live) ...[
                        const SizedBox(width: 6),
                        const LiveBadge(),
                      ] else
                        _TimeLabel(player: player),
                      if (compact && p != null) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(p.title,
                              maxLines: 1, overflow: TextOverflow.ellipsis),
                        ),
                      ] else
                        const Spacer(),
                      // Phones have volume keys; the slider only takes room.
                      if (!isMobile) _VolumeControl(player: player, compact: compact),
                      if (!compact) ...[
                        _TracksButton(player: player),
                        PopupMenuButton<BoxFit>(
                          tooltip: 'Aspect ratio',
                          icon: const Icon(Icons.aspect_ratio),
                          initialValue: fit,
                          onSelected: onFit,
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: BoxFit.contain, child: Text('Fit')),
                            PopupMenuItem(value: BoxFit.cover, child: Text('Fill (crop)')),
                            PopupMenuItem(value: BoxFit.fill, child: Text('Stretch')),
                          ],
                        ),
                      ],
                      if (isDesktop || (isMobile && !compact && MiniMode.pipSupported))
                        IconButton(
                          tooltip: compact
                              ? 'Mini player (always on top)'
                              : 'Mini player — always on top (P)',
                          icon: const Icon(Icons.picture_in_picture_alt),
                          onPressed: MiniMode.enter,
                        ),
                      if (isDesktop || compact)
                        IconButton(
                          tooltip: compact ? 'Full screen' : 'Full screen (F)',
                          icon: const Icon(Icons.fullscreen),
                          onPressed: onFullscreen,
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
        // Full screen on a phone: keep buttons clear of notches and the
        // gesture bar.
        return compact ? controls : SafeArea(child: controls);
      },
    );
  }
}

/// Big centre buttons for touch: play/pause between seek (movies) or
/// channel (live) buttons.
class _TouchCenter extends StatelessWidget {
  const _TouchCenter({
    required this.player,
    required this.live,
    required this.canZap,
    required this.onSeek,
    required this.onZap,
  });

  final Player player;
  final bool live;
  final bool canZap;
  final ValueChanged<int> onSeek;
  final ValueChanged<int> onZap;

  Widget _button(IconData icon, String tip, VoidCallback onTap, {double size = 36}) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 18),
        child: Material(
          color: Colors.black38,
          shape: const CircleBorder(),
          child: IconButton(
            tooltip: tip,
            iconSize: size,
            padding: EdgeInsets.all(size * 0.3),
            icon: Icon(icon, color: Colors.white),
            onPressed: onTap,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) => Center(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (!live)
            _button(Icons.replay_10_rounded, 'Back 10 s', () => onSeek(-10))
          else if (canZap)
            _button(Icons.skip_previous_rounded, 'Previous channel', () => onZap(-1)),
          StreamBuilder<bool>(
            stream: player.stream.playing,
            initialData: player.state.playing,
            builder: (_, snap) => _button(
              snap.data == true ? Icons.pause_rounded : Icons.play_arrow_rounded,
              'Play/Pause',
              player.playOrPause,
              size: 48,
            ),
          ),
          if (!live)
            _button(Icons.forward_10_rounded, 'Forward 10 s', () => onSeek(10))
          else if (canZap)
            _button(Icons.skip_next_rounded, 'Next channel', () => onZap(1)),
        ]),
      );
}

class _Gradient extends StatelessWidget {
  const _Gradient({required this.child, required this.top});
  final Widget child;
  final bool top;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: top ? Alignment.topCenter : Alignment.bottomCenter,
            end: top ? Alignment.bottomCenter : Alignment.topCenter,
            colors: const [Color(0xCC000000), Color(0x00000000)],
          ),
        ),
        child: child,
      );
}

class _SeekBar extends StatefulWidget {
  const _SeekBar({required this.player});
  final Player player;
  @override
  State<_SeekBar> createState() => _SeekBarState();
}

class _SeekBarState extends State<_SeekBar> {
  double? _drag;

  @override
  Widget build(BuildContext context) {
    final pl = widget.player;
    return StreamBuilder<Duration>(
      stream: pl.stream.position,
      initialData: pl.state.position,
      builder: (context, snap) {
        final dur = pl.state.duration.inMilliseconds.toDouble();
        final pos = (snap.data ?? Duration.zero).inMilliseconds.toDouble();
        final buffer = pl.state.buffer.inMilliseconds.toDouble();
        if (dur <= 0) return const SizedBox(height: 24);
        return SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            secondaryActiveTrackColor: Colors.white30,
          ),
          child: Slider(
            value: (_drag ?? pos).clamp(0, dur),
            secondaryTrackValue: buffer.clamp(0, dur),
            max: dur,
            onChanged: (v) => setState(() => _drag = v),
            onChangeEnd: (v) {
              pl.seek(Duration(milliseconds: v.round()));
              setState(() => _drag = null);
            },
          ),
        );
      },
    );
  }
}

class _TimeLabel extends StatelessWidget {
  const _TimeLabel({required this.player});
  final Player player;

  @override
  Widget build(BuildContext context) => StreamBuilder<Duration>(
        stream: player.stream.position,
        initialData: player.state.position,
        builder: (_, snap) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Text(
            '${formatDuration(snap.data ?? Duration.zero)} / ${formatDuration(player.state.duration)}',
            style: const TextStyle(fontFeatures: [FontFeature.tabularFigures()]),
          ),
        ),
      );
}

class _VolumeControl extends ConsumerWidget {
  const _VolumeControl({required this.player, required this.compact});
  final Player player;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) => StreamBuilder<double>(
        stream: player.stream.volume,
        initialData: player.state.volume,
        builder: (_, snap) {
          final v = snap.data ?? 100;
          final ap = ref.read(appPlayerProvider);
          return Row(mainAxisSize: MainAxisSize.min, children: [
            IconButton(
              tooltip: 'Mute (M)',
              icon: Icon(v == 0 ? Icons.volume_off : (v < 50 ? Icons.volume_down : Icons.volume_up)),
              onPressed: () => ap.setVolume(v > 0 ? 0 : 100),
            ),
            SizedBox(
              width: compact ? 70 : 110,
              child: SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 2,
                  thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5),
                  overlayShape: SliderComponentShape.noOverlay,
                ),
                child: Slider(
                  value: v.clamp(0, 100),
                  max: 100,
                  onChanged: ap.setVolume,
                  onChangeEnd: (_) => ap.persistVolume(),
                ),
              ),
            ),
          ]);
        },
      );
}

class _TracksButton extends StatelessWidget {
  const _TracksButton({required this.player});
  final Player player;

  String _label(dynamic t, int i) {
    final title = t.title as String?;
    final lang = t.language as String?;
    final parts = [?title, if (lang != null && lang != title) lang.toUpperCase()];
    return parts.isEmpty ? 'Track ${i + 1}' : parts.join(' · ');
  }

  @override
  Widget build(BuildContext context) => StreamBuilder<Tracks>(
        stream: player.stream.tracks,
        initialData: player.state.tracks,
        builder: (context, snap) {
          final tracks = snap.data ?? const Tracks();
          final audio = tracks.audio.where((t) => t.id != 'auto' && t.id != 'no').toList();
          final subs = tracks.subtitle.where((t) => t.id != 'auto').toList();
          if (audio.length <= 1 && subs.where((t) => t.id != 'no').isEmpty) {
            return const SizedBox.shrink();
          }
          final current = player.state.track;
          return PopupMenuButton<Object>(
            tooltip: 'Audio & subtitles',
            icon: const Icon(Icons.subtitles_outlined),
            onSelected: (t) {
              if (t is AudioTrack) player.setAudioTrack(t);
              if (t is SubtitleTrack) player.setSubtitleTrack(t);
            },
            itemBuilder: (_) => [
              if (audio.isNotEmpty) const PopupMenuItem(enabled: false, child: Text('AUDIO')),
              for (var i = 0; i < audio.length; i++)
                CheckedPopupMenuItem(
                  value: audio[i],
                  checked: current.audio.id == audio[i].id,
                  child: Text(_label(audio[i], i)),
                ),
              if (subs.isNotEmpty) ...[
                const PopupMenuDivider(),
                const PopupMenuItem(enabled: false, child: Text('SUBTITLES')),
                for (var i = 0; i < subs.length; i++)
                  CheckedPopupMenuItem(
                    value: subs[i],
                    checked: current.subtitle.id == subs[i].id,
                    child: Text(subs[i].id == 'no' ? 'Off' : _label(subs[i], i)),
                  ),
              ],
            ],
          );
        },
      );
}

/// "Now: <title> · 20:00–21:00" for a live channel; refreshes every minute.
class NowPlayingLine extends ConsumerStatefulWidget {
  const NowPlayingLine({super.key, required this.sourceId, required this.epgId});
  final int sourceId;
  final String epgId;

  @override
  ConsumerState<NowPlayingLine> createState() => _NowPlayingLineState();
}

class _NowPlayingLineState extends ConsumerState<NowPlayingLine> {
  List<Programme> _pr = const [];
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _load();
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _load());
  }

  @override
  void didUpdateWidget(NowPlayingLine old) {
    super.didUpdateWidget(old);
    if (old.epgId != widget.epgId) _load();
  }

  Future<void> _load() async {
    final m = await ref.read(repositoryProvider).nowNext(widget.sourceId, [widget.epgId]);
    if (mounted) setState(() => _pr = m[widget.epgId] ?? const []);
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_pr.isEmpty) return const SizedBox.shrink();
    final now = _pr.first;
    final next = _pr.length > 1 ? _pr[1] : null;
    return Text(
      '${now.title}  ·  ${hhmm(now.start)}–${hhmm(now.stop)}'
      '${next != null ? '     Next: ${next.title}' : ''}',
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: const TextStyle(color: AppColors.textDim),
    );
  }
}

/// Full-window player route.
class PlayerPage extends ConsumerStatefulWidget {
  const PlayerPage({super.key, this.stopOnExit = true});

  /// Movies/episodes stop when closed; live channels opened from the preview
  /// keep playing there.
  final bool stopOnExit;

  static Future<void> open(BuildContext context, {bool stopOnExit = true}) =>
      Navigator.of(context).push(PageRouteBuilder(
        pageBuilder: (_, _, _) => PlayerPage(stopOnExit: stopOnExit),
        transitionsBuilder: (_, a, _, child) => FadeTransition(opacity: a, child: child),
        transitionDuration: const Duration(milliseconds: 150),
      ));

  @override
  ConsumerState<PlayerPage> createState() => _PlayerPageState();
}

class _PlayerPageState extends ConsumerState<PlayerPage> {
  late final AppPlayer _player;

  @override
  void initState() {
    super.initState();
    _player = ref.read(appPlayerProvider);
    if (isMobile) {
      MiniMode.arm(_player);
      // Phones watch sideways with the system bars hidden.
      SystemChrome.setPreferredOrientations(
          [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  void dispose() {
    if (isMobile) {
      MiniMode.disarm();
      SystemChrome.setPreferredOrientations(const []);
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    if (isDesktop) {
      windowManager.isFullScreen().then((fs) {
        if (fs) windowManager.setFullScreen(false);
      });
    }
    if (widget.stopOnExit) _player.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: Colors.black,
        body: PlayerView(
          autofocus: true,
          onBack: () => Navigator.of(context).maybePop(),
        ),
      );
}
