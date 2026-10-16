import 'dart:io';

/// Windows, Linux or macOS: a resizable window managed by window_manager.
final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Android build target, set with `--dart-define=FORM_FACTOR=mobile|tv`.
const _formFactor = String.fromEnvironment('FORM_FACTOR', defaultValue: 'tv');

/// The Android phone/tablet build (touch, immersive full screen).
final isMobile = Platform.isAndroid && _formFactor == 'mobile';
