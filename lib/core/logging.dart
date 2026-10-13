import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Tiny rotating file log in `%APPDATA%/.../logs/app.log` for support.
class AppLog {
  static IOSink? _sink;

  static Future<void> init(String dir) async {
    try {
      await Directory(dir).create(recursive: true);
      final file = File(p.join(dir, 'app.log'));
      // Rotate at 2 MB.
      if (await file.exists() && await file.length() > 2 * 1024 * 1024) {
        final old = File(p.join(dir, 'app.old.log'));
        if (await old.exists()) await old.delete();
        await file.rename(old.path);
      }
      _sink = File(p.join(dir, 'app.log')).openWrite(mode: FileMode.append);
      info('App started');
    } catch (_) {
      // Logging must never break the app.
    }
  }

  static void info(String msg) => _write('INFO', msg);

  static void error(String where, Object e, [StackTrace? st]) {
    _write('ERROR', '$where: $e${st == null ? '' : '\n$st'}');
  }

  static void _write(String level, String msg) {
    final line = '${DateTime.now().toIso8601String()} [$level] $msg';
    if (kDebugMode) debugPrint(line);
    try {
      _sink?.writeln(line);
    } catch (_) {}
  }
}
