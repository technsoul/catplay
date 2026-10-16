import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../core/db/database.dart';
import '../core/models.dart';
import '../core/settings.dart';
import '../data/repository.dart';

class AppPaths {
  AppPaths({
    required this.database,
    required this.epgDir,
    required this.importTemp,
    required this.imageCache,
    required this.downloads,
    required this.downloadsIndex,
  });
  final String database;
  final String epgDir;
  final String importTemp;
  final String imageCache;
  /// Where downloaded movies/episodes are saved.
  final String downloads;
  final String downloadsIndex;
}

/// Overridden in main() once paths/DB are ready.
final appPathsProvider = Provider<AppPaths>((_) => throw UnimplementedError());
final databaseProvider = Provider<AppDatabase>((_) => throw UnimplementedError());
final initialSettingsProvider = Provider<AppSettings>((_) => const AppSettings());

final repositoryProvider = Provider<Repository>((ref) =>
    Repository(ref.watch(databaseProvider), epgDir: ref.watch(appPathsProvider).epgDir));

/// Emits whenever the DB worker reports writes to one of [groups].
Stream<void> dbChanges(Ref ref, Set<String> groups) => ref
    .watch(databaseProvider)
    .changes
    .where((t) => t.any(groups.contains))
    .map((_) {});

class SettingsController extends Notifier<AppSettings> {
  @override
  AppSettings build() => ref.read(initialSettingsProvider);

  Future<void> update(AppSettings Function(AppSettings) f) async {
    state = f(state);
    await ref.read(repositoryProvider).saveSettings(state);
  }
}

final settingsProvider =
    NotifierProvider<SettingsController, AppSettings>(SettingsController.new);

/// Xtream passwords live in the OS credential store, never in SQLite.
class Secrets {
  Secrets([FlutterSecureStorage? s]) : _s = s ?? const FlutterSecureStorage();
  final FlutterSecureStorage _s;
  String _key(int sourceId) => 'source_password_$sourceId';

  Future<String?> password(int sourceId) => _s.read(key: _key(sourceId));
  Future<void> setPassword(int sourceId, String value) =>
      _s.write(key: _key(sourceId), value: value);
  Future<void> delete(int sourceId) => _s.delete(key: _key(sourceId));
}

final secretsProvider = Provider<Secrets>((_) => Secrets());

/// All configured sources; reloads when sources change.
final sourcesProvider = StreamProvider<List<Source>>((ref) async* {
  final repo = ref.watch(repositoryProvider);
  yield await repo.sources();
  await for (final _ in dbChanges(ref, {'sources'})) {
    yield await repo.sources();
  }
});

/// The source currently being browsed (falls back to the first one).
final activeSourceProvider = Provider<Source?>((ref) {
  final sources = ref.watch(sourcesProvider).value ?? const [];
  if (sources.isEmpty) return null;
  final id = ref.watch(settingsProvider.select((s) => s.activeSourceId));
  return sources.where((s) => s.id == id).firstOrNull ?? sources.first;
});

/// Bumps on favorite/history/items/epg changes so lists can reload.
final dataVersionProvider = StreamProvider.family<int, String>((ref, group) async* {
  var v = 0;
  yield v;
  await for (final _ in dbChanges(ref, {group})) {
    yield ++v;
  }
});
