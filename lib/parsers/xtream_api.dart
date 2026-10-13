import 'dart:io';

import '../core/http.dart';
import '../core/models.dart';

/// Xtream Codes "player_api.php" client.
class XtreamApi {
  XtreamApi({
    required String server,
    required this.username,
    required this.password,
    this.userAgent,
    HttpClient? client,
  })  : server = normalizeServer(server),
        _client = client ?? createHttpClient(userAgent: userAgent);

  final String server;
  final String username;
  final String password;
  final String? userAgent;
  final HttpClient _client;

  static String normalizeServer(String s) {
    var v = s.trim();
    if (!v.startsWith('http://') && !v.startsWith('https://')) v = 'http://$v';
    // Strip a pasted player_api.php / get.php path.
    final uri = Uri.parse(v);
    final base = Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
    ).toString();
    return base.endsWith('/') ? base.substring(0, base.length - 1) : base;
  }

  String get _u => Uri.encodeComponent(username);
  String get _p => Uri.encodeComponent(password);

  String apiUrl([String? action, Map<String, String> extra = const {}]) {
    final q = StringBuffer('$server/player_api.php?username=$_u&password=$_p');
    if (action != null) q.write('&action=$action');
    extra.forEach((k, v) => q.write('&$k=${Uri.encodeComponent(v)}'));
    return q.toString();
  }

  String get epgUrl => '$server/xmltv.php?username=$_u&password=$_p';

  String liveUrl(String streamId, {String ext = 'ts'}) =>
      '$server/live/$_u/$_p/$streamId.$ext';
  String movieUrl(String streamId, String ext) =>
      '$server/movie/$_u/$_p/$streamId.$ext';
  String episodeUrl(String episodeId, String ext) =>
      '$server/series/$_u/$_p/$episodeId.$ext';

  /// Catch-up / timeshift URL for a past programme.
  String timeshiftUrl(String streamId, DateTime start, int durationMinutes) {
    String two(int v) => v.toString().padLeft(2, '0');
    final s = start.toUtc();
    final t = '${s.year}-${two(s.month)}-${two(s.day)}:${two(s.hour)}-${two(s.minute)}';
    return '$server/timeshift/$_u/$_p/$durationMinutes/$t/$streamId.ts';
  }

  Future<Object?> _get(String url) =>
      getJson(url, client: _client, timeout: const Duration(minutes: 3));

  /// Validates credentials. Throws on failure.
  Future<XtreamAccount> authenticate() async {
    final json = await _get(apiUrl());
    if (json is! Map) throw HttpException2('Unexpected server response');
    final info = json['user_info'];
    if (info is! Map || '${info['auth']}' != '1') {
      throw HttpException2('Login failed: wrong username or password');
    }
    final status = '${info['status'] ?? ''}';
    if (status.isNotEmpty && status.toLowerCase() != 'active') {
      throw HttpException2('Account is $status');
    }
    return XtreamAccount(
      expiresAt: _int(info['exp_date']),
      maxConnections: _int(info['max_connections']),
      status: status,
    );
  }

  Future<List<Map<String, dynamic>>> _list(String action,
      [Map<String, String> extra = const {}]) async {
    final json = await _get(apiUrl(action, extra));
    if (json is List) return json.whereType<Map>().map((m) => m.cast<String, dynamic>()).toList();
    // Some panels return {} for empty lists.
    return const [];
  }

  Future<List<Map<String, dynamic>>> liveCategories() =>
      _list('get_live_categories');
  Future<List<Map<String, dynamic>>> vodCategories() =>
      _list('get_vod_categories');
  Future<List<Map<String, dynamic>>> seriesCategories() =>
      _list('get_series_categories');
  Future<List<Map<String, dynamic>>> liveStreams() => _list('get_live_streams');
  Future<List<Map<String, dynamic>>> vodStreams() => _list('get_vod_streams');
  Future<List<Map<String, dynamic>>> series() => _list('get_series');

  Future<Map<String, dynamic>> vodInfo(String vodId) async {
    final json = await _get(apiUrl('get_vod_info', {'vod_id': vodId}));
    return json is Map ? json.cast<String, dynamic>() : const {};
  }

  Future<SeriesInfo> seriesInfo(String seriesId) async {
    final json = await _get(apiUrl('get_series_info', {'series_id': seriesId}));
    if (json is! Map) return SeriesInfo(const {}, const []);
    final info = (json['info'] is Map)
        ? (json['info'] as Map).cast<String, dynamic>()
        : <String, dynamic>{};
    final eps = <Episode>[];
    final raw = json['episodes'];
    Iterable<MapEntry<String, dynamic>> seasons = const [];
    if (raw is Map) {
      seasons = raw.cast<String, dynamic>().entries;
    } else if (raw is List) {
      // Some panels return a list of lists.
      seasons = [
        for (var i = 0; i < raw.length; i++) MapEntry('${i + 1}', raw[i])
      ];
    }
    for (final s in seasons) {
      final list = s.value;
      if (list is! List) continue;
      for (final e in list.whereType<Map>()) {
        final id = '${e['id']}';
        final ext = '${e['container_extension'] ?? 'mp4'}';
        final epInfo = e['info'] is Map ? e['info'] as Map : const {};
        eps.add(Episode(
          id: id,
          season: _int(e['season']) ?? int.tryParse(s.key) ?? 1,
          number: _int(e['episode_num']) ?? eps.length + 1,
          title: '${e['title'] ?? 'Episode ${e['episode_num']}'}',
          url: episodeUrl(id, ext),
          plot: _str(epInfo['plot']),
          image: _str(epInfo['movie_image']) ?? _str(epInfo['cover_big']),
          duration: _str(epInfo['duration']),
        ));
      }
    }
    eps.sort((a, b) =>
        a.season != b.season ? a.season - b.season : a.number - b.number);
    return SeriesInfo(info, eps);
  }

  void close() => _client.close(force: true);
}

class XtreamAccount {
  XtreamAccount({this.expiresAt, this.maxConnections, this.status});
  final int? expiresAt;
  final int? maxConnections;
  final String? status;
}

class SeriesInfo {
  SeriesInfo(this.info, this.episodes);
  final Map<String, dynamic> info;
  final List<Episode> episodes;

  String? get plot => _str(info['plot']);
  String? get cover => _str(info['cover']);
  String? get genre => _str(info['genre']);
  String? get cast => _str(info['cast']);
  String? get releaseDate => _str(info['releaseDate']) ?? _str(info['release_date']);
}

int? _int(Object? v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is double) return v.toInt();
  return int.tryParse('$v');
}

String? _str(Object? v) {
  if (v == null) return null;
  final s = '$v'.trim();
  return s.isEmpty || s == 'null' ? null : s;
}

/// Shared helpers for importer.
int? xtInt(Object? v) => _int(v);
String? xtStr(Object? v) => _str(v);
double? xtDouble(Object? v) {
  if (v == null) return null;
  if (v is num) return v.toDouble();
  return double.tryParse('$v');
}
