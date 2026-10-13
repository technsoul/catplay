import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:media_kit/media_kit.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:window_manager/window_manager.dart';

import 'app/app_lock.dart';
import 'app/providers.dart';
import 'app/shell.dart';
import 'core/db/database.dart';
import 'core/image_cache.dart';
import 'core/logging.dart';
import 'data/repository.dart';
import 'player/mini_player.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final support = await getApplicationSupportDirectory();
  final cache = await getApplicationCacheDirectory();
  final temp = await getTemporaryDirectory();
  final paths = AppPaths(
    database: p.join(support.path, 'iptv.db'),
    epgDir: p.join(support.path, 'epg'),
    importTemp: p.join(temp.path, 'iptv_import'),
    imageCache: p.join(cache.path, 'images'),
  );
  await Directory(support.path).create(recursive: true);
  await AppLog.init(p.join(support.path, 'logs'));

  // Last-resort error reporting: log instead of crashing silently.
  FlutterError.onError = (d) {
    FlutterError.presentError(d);
    AppLog.error('Flutter', d.exception, d.stack);
  };
  PlatformDispatcher.instance.onError = (e, st) {
    AppLog.error('Uncaught', e, st);
    return true;
  };

  MediaKit.ensureInitialized();
  await windowManager.ensureInitialized();
  await windowManager.waitUntilReadyToShow(
    const WindowOptions(
      size: Size(1440, 900),
      minimumSize: Size(1100, 680),
      center: true,
      title: 'CAT',
      backgroundColor: AppColors.bg,
    ),
    () async {
      await windowManager.show();
      await windowManager.focus();
    },
  );

  CachedNetImage.init(paths.imageCache);
  final db = await AppDatabase.open(paths.database);
  final repo = Repository(db, epgDir: paths.epgDir);
  final settings = await repo.loadSettings();
  final pinSet = await PinStore().isSet().catchError((Object e) {
    AppLog.error('AppLock', e);
    return false;
  });
  unawaited(repo.cleanupEpgFiles());

  runApp(ProviderScope(
    overrides: [
      appPathsProvider.overrideWithValue(paths),
      databaseProvider.overrideWithValue(db),
      initialSettingsProvider.overrideWithValue(settings),
      initialPinSetProvider.overrideWithValue(pinSet),
    ],
    // Errors are surfaced in the UI; don't silently retry providers.
    retry: (_, _) => null,
    child: const IptvApp(),
  ));
}

class IptvApp extends StatelessWidget {
  const IptvApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'CAT',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        home: const AppShell(),
        builder: (_, child) => AppLockGate(child: MiniModeHost(child: child!)),
      );
}
