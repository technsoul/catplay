import 'dart:io';

/// Windows, Linux or macOS: a resizable window managed by window_manager.
final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;

/// Android build target, set with `--dart-define=FORM_FACTOR=mobile|tv`.
const _formFactor = String.fromEnvironment('FORM_FACTOR', defaultValue: 'tv');

/// The Android phone/tablet build (touch, rotates, edge to edge).
final isMobile = Platform.isAndroid && _formFactor == 'mobile';

/// The Android TV build (remote control, landscape, 720p-style layout).
final isTv = Platform.isAndroid && !isMobile;

/// Desktop run with `FORM_FACTOR=mobile`: opens a phone-sized window so the
/// phone layout can be developed and checked without a device.
final isPhonePreview = isDesktop && _formFactor == 'mobile';

/// Touch-first player controls: phones, and the phone preview on desktop.
final isTouch = isMobile || isPhonePreview;
