import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../core/models.dart';
import '../parsers/xtream_api.dart';
import 'providers.dart';

/// Xtream API client for a source (null for M3U sources).
final xtreamApiProvider = FutureProvider.family<XtreamApi?, int>((ref, sourceId) async {
  final source = await ref.watch(repositoryProvider).source(sourceId);
  if (source == null || source.type != SourceType.xtream) return null;
  final password = await ref.read(secretsProvider).password(sourceId) ?? '';
  final settings = ref.read(settingsProvider);
  final api = XtreamApi(
    server: source.url,
    username: source.username ?? '',
    password: password,
    userAgent: (source.userAgent?.isNotEmpty ?? false)
        ? source.userAgent
        : (settings.userAgent.isNotEmpty ? settings.userAgent : null),
  );
  ref.onDispose(api.close);
  return api;
});
