import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:window_manager/window_manager.dart';

import '../core/platform.dart';
import 'app_player.dart';

/// Picture-in-picture: shrinks the app window to a small, frameless,
/// always-on-top video in the screen corner, and restores it afterwards.
///
/// The app keeps its whole navigation state underneath (it is only hidden),
/// so restoring returns exactly where the user was.
class MiniMode {
  MiniMode._();

  static final active = ValueNotifier(false);

  static const _size = Size(480, 270);
  static const _minSize = Size(256, 144);
  static const _appMinSize = Size(1100, 680);

  static Rect? _savedBounds;
  static bool _savedMaximized = false;
  static bool _busy = false;

  static Future<void> enter() async {
    if (!isDesktop || active.value || _busy) return;
    _busy = true;
    try {
      if (await windowManager.isFullScreen()) {
        await windowManager.setFullScreen(false);
        // Let Windows finish the fullscreen transition before resizing.
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      _savedMaximized = await windowManager.isMaximized();
      if (_savedMaximized) await windowManager.unmaximize();
      _savedBounds = await windowManager.getBounds();

      active.value = true;
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden, windowButtonVisibility: false);
      await windowManager.setMinimumSize(_minSize);
      await windowManager.setSize(_size);
      await windowManager.setAspectRatio(16 / 9);
      await windowManager.setAlignment(Alignment.bottomRight);
      await windowManager.setAlwaysOnTop(true);
    } finally {
      _busy = false;
    }
  }

  static Future<void> exit() async {
    if (!isDesktop || !active.value || _busy) return;
    _busy = true;
    try {
      await windowManager.setAlwaysOnTop(false);
      await windowManager.setAspectRatio(0);
      await windowManager.setTitleBarStyle(TitleBarStyle.normal);
      await windowManager.setMinimumSize(_appMinSize);
      final b = _savedBounds;
      if (b != null) {
        await windowManager.setBounds(b);
      } else {
        await windowManager.setSize(const Size(1440, 900));
        await windowManager.center();
      }
      if (_savedMaximized) await windowManager.maximize();
      active.value = false;
      await windowManager.focus();
    } finally {
      _busy = false;
    }
  }

  static Future<void> toggle() => active.value ? exit() : enter();
}

/// Wraps the app: when mini mode is on, the normal UI is hidden and only the
/// video with small hover controls is shown.
class MiniModeHost extends StatelessWidget {
  const MiniModeHost({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
        valueListenable: MiniMode.active,
        builder: (_, mini, _) => Stack(
          fit: StackFit.expand,
          children: [
            Offstage(offstage: mini, child: TickerMode(enabled: !mini, child: child)),
            // Built above the Navigator, so it needs its own Overlay for tooltips.
            if (mini) Overlay(initialEntries: [OverlayEntry(builder: (_) => const _MiniPlayer())]),
          ],
        ),
      );
}

class _MiniPlayer extends ConsumerStatefulWidget {
  const _MiniPlayer();
  @override
  ConsumerState<_MiniPlayer> createState() => _MiniPlayerState();
}

class _MiniPlayerState extends ConsumerState<_MiniPlayer> {
  bool _hover = false;
  final _focus = FocusNode(debugLabel: 'mini-player');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _focus.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    await ref.read(appPlayerProvider).stop();
    await MiniMode.exit();
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.ignored;
    final p = ref.read(appPlayerProvider);
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.escape) {
      MiniMode.exit();
    } else if (k == LogicalKeyboardKey.space || k == LogicalKeyboardKey.keyK) {
      p.player.playOrPause();
    } else if (k == LogicalKeyboardKey.keyM) {
      p.setVolume(p.player.state.volume > 0 ? 0 : 100);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final ap = ref.watch(appPlayerProvider);
    final player = ap.player;
    return Material(
      color: Colors.black,
      child: Focus(
        focusNode: _focus,
        onKeyEvent: _onKey,
        child: MouseRegion(
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() => _hover = false),
          // The whole surface drags the window; double-click restores.
          child: DragToMoveArea(
            child: GestureDetector(
              onDoubleTap: MiniMode.exit,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Video(
                    controller: ap.video,
                    controls: NoVideoControls,
                    fill: Colors.black,
                  ),
                  ValueListenableBuilder(
                    valueListenable: ap.state,
                    builder: (_, s, _) => switch (s.phase) {
                      PlayPhase.loading || PlayPhase.reconnecting => const Center(
                          child: CircularProgressIndicator(strokeWidth: 2)),
                      PlayPhase.idle => const Center(
                          child: Text('Nothing playing',
                              style: TextStyle(color: Colors.white54))),
                      PlayPhase.error => Center(
                          child: IconButton(
                            tooltip: s.error ?? 'Playback failed — retry',
                            icon: const Icon(Icons.refresh, color: Colors.white),
                            onPressed: ap.retry,
                          ),
                        ),
                      PlayPhase.playing => const SizedBox.shrink(),
                    },
                  ),
                  AnimatedOpacity(
                    opacity: _hover ? 1 : 0,
                    duration: const Duration(milliseconds: 150),
                    child: IgnorePointer(
                      ignoring: !_hover,
                      child: DecoratedBox(
                        decoration: const BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [Color(0x99000000), Color(0x00000000), Color(0x99000000)],
                          ),
                        ),
                        child: Column(children: [
                          Row(children: [
                            const SizedBox(width: 10),
                            Expanded(
                              child: ValueListenableBuilder(
                                valueListenable: ap.state,
                                builder: (_, s, _) => Text(
                                  s.playable?.title ?? '',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: 13),
                                ),
                              ),
                            ),
                            _btn('Back to app (Esc)', Icons.open_in_full, MiniMode.exit),
                            _btn('Close', Icons.close, _close),
                          ]),
                          const Spacer(),
                          Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                            StreamBuilder<bool>(
                              stream: player.stream.playing,
                              initialData: player.state.playing,
                              builder: (_, snap) => _btn(
                                'Play/Pause (Space)',
                                snap.data == true ? Icons.pause : Icons.play_arrow,
                                player.playOrPause,
                                size: 30,
                              ),
                            ),
                            StreamBuilder<double>(
                              stream: player.stream.volume,
                              initialData: player.state.volume,
                              builder: (_, snap) => _btn(
                                'Mute (M)',
                                (snap.data ?? 100) == 0 ? Icons.volume_off : Icons.volume_up,
                                () => ap.setVolume((snap.data ?? 100) > 0 ? 0 : 100),
                              ),
                            ),
                          ]),
                        ]),
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

  Widget _btn(String tip, IconData icon, VoidCallback onTap, {double size = 20}) =>
      IconButton(
        tooltip: tip,
        iconSize: size,
        visualDensity: VisualDensity.compact,
        color: Colors.white,
        icon: Icon(icon),
        onPressed: onTap,
      );
}
