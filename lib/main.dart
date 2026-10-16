import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import 'core/platform.dart';
import 'data/repository.dart';
import 'player/mini_player.dart';
import 'ui/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final support = await getApplicationSupportDirectory();
  final cache = await getApplicationCacheDirectory();
  final temp = await getTemporaryDirectory();
  // Android keeps downloads in the app's external storage folder.
  final userDownloads = Platform.isAndroid
      ? await getExternalStorageDirectory().catchError((Object _) => null)
      : await getDownloadsDirectory().catchError((Object _) => null);
  final paths = AppPaths(
    database: p.join(support.path, 'iptv.db'),
    epgDir: p.join(support.path, 'epg'),
    importTemp: p.join(temp.path, 'iptv_import'),
    imageCache: p.join(cache.path, 'images'),
    downloads: userDownloads != null
        ? p.join(userDownloads.path, Platform.isAndroid ? 'Downloads' : 'CAT')
        : p.join(support.path, 'downloads'),
    downloadsIndex: p.join(support.path, 'downloads.json'),
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
  if (isMobile) {
    // Phones: landscape, edge to edge, system bars hidden until swiped in.
    await SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }
  if (isDesktop) {
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
  }

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
        // TV remotes send "select" for the OK button.
        shortcuts: {
          ...WidgetsApp.defaultShortcuts,
          const SingleActivator(LogicalKeyboardKey.select): const ActivateIntent(),
        },
        builder: (_, child) =>
            _TvScale(child: AppLockGate(child: MiniModeHost(child: child!))),
      );
}

/// The UI is laid out for a desktop window (at least 1100 logical px wide).
/// TVs report about 960x540 and phones about 900x400 in landscape, so the UI
/// is drawn on a larger canvas and scaled down to fit.
class _TvScale extends StatelessWidget {
  const _TvScale({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    if (isDesktop || size.isEmpty) return child;
    // Phones keep the UI as large as possible; TVs are viewed from afar at
    // a 720p-like layout.
    final min = isMobile ? const Size(1100, 600) : const Size(1280, 720);
    final scale = [size.width / min.width, size.height / min.height, 1.0]
        .reduce((a, b) => a < b ? a : b);
    if (scale >= 1) return child;
    final virtual = size / scale;
    return ColoredBox(
      color: AppColors.bg,
      child: FittedBox(
        fit: BoxFit.contain,
        alignment: Alignment.topLeft,
        child: SizedBox.fromSize(
          size: virtual,
          child: MediaQuery(
            data: mq.copyWith(
              size: virtual,
              padding: mq.padding / scale,
              viewPadding: mq.viewPadding / scale,
              viewInsets: mq.viewInsets / scale,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}
