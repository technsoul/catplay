import 'dart:io';

/// Windows, Linux or macOS: a resizable window managed by window_manager.
final isDesktop = Platform.isWindows || Platform.isLinux || Platform.isMacOS;
