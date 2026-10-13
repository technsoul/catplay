import 'dart:convert';

enum ItemKind {
  live,
  movie,
  series;

  static ItemKind fromInt(int v) => ItemKind.values[v];
}

enum SourceType {
  m3uUrl('m3u_url'),
  m3uFile('m3u_file'),
  xtream('xtream');

  const SourceType(this.id);
  final String id;

  static SourceType parse(String v) =>
      SourceType.values.firstWhere((e) => e.id == v);
}

class Source {
  Source({
    required this.id,
    required this.name,
    required this.type,
    required this.url,
    this.username,
    this.epgUrl,
    this.userAgent,
    this.lastRefresh,
    this.lastEpg,
    this.status = 'new',
    this.error,
    this.liveCount = 0,
    this.movieCount = 0,
    this.seriesCount = 0,
    this.expiresAt,
    this.maxConnections,
  });

  final int id;
  final String name;
  final SourceType type;
  final String url;
  final String? username;
  final String? epgUrl;
  final String? userAgent;
  final DateTime? lastRefresh;
  final DateTime? lastEpg;
  final String status;
  final String? error;
  final int liveCount;
  final int movieCount;
  final int seriesCount;
  final DateTime? expiresAt;
  final int? maxConnections;

  factory Source.fromRow(Map<String, Object?> r) => Source(
        id: r['id'] as int,
        name: r['name'] as String,
        type: SourceType.parse(r['type'] as String),
        url: r['url'] as String,
        username: r['username'] as String?,
        epgUrl: r['epg_url'] as String?,
        userAgent: r['user_agent'] as String?,
        lastRefresh: _date(r['last_refresh']),
        lastEpg: _date(r['last_epg']),
        status: r['status'] as String,
        error: r['error'] as String?,
        liveCount: r['live_count'] as int,
        movieCount: r['movie_count'] as int,
        seriesCount: r['series_count'] as int,
        expiresAt: _date(r['expires_at']),
        maxConnections: r['max_connections'] as int?,
      );
}

DateTime? _date(Object? secs) => secs == null
    ? null
    : DateTime.fromMillisecondsSinceEpoch((secs as int) * 1000);

class Category {
  Category({
    required this.id,
    required this.sourceId,
    required this.kind,
    required this.name,
    required this.itemCount,
  });

  final int id;
  final int sourceId;
  final ItemKind kind;
  final String name;
  final int itemCount;

  factory Category.fromRow(Map<String, Object?> r) => Category(
        id: r['id'] as int,
        sourceId: r['source_id'] as int,
        kind: ItemKind.fromInt(r['kind'] as int),
        name: r['name'] as String,
        itemCount: r['item_count'] as int,
      );
}

/// A live channel, a movie or a series.
class MediaItem {
  MediaItem({
    required this.id,
    required this.sourceId,
    required this.kind,
    required this.key,
    required this.name,
    this.categoryId,
    this.logo,
    this.url,
    this.epgId,
    this.number,
    this.extId,
    this.container,
    this.rating,
    this.year,
    this.catchupDays,
    this.headers = const {},
    this.isFavorite = false,
  });

  final int id;
  final int sourceId;
  final ItemKind kind;
  final String key;
  final String name;
  final int? categoryId;
  final String? logo;
  final String? url;
  final String? epgId;
  final int? number;
  final String? extId;
  final String? container;
  final double? rating;
  final String? year;
  final int? catchupDays;
  final Map<String, String> headers;
  final bool isFavorite;

  factory MediaItem.fromRow(Map<String, Object?> r) => MediaItem(
        id: r['id'] as int,
        sourceId: r['source_id'] as int,
        kind: ItemKind.fromInt(r['kind'] as int),
        key: r['key'] as String,
        name: r['name'] as String,
        categoryId: r['category_id'] as int?,
        logo: r['logo'] as String?,
        url: r['url'] as String?,
        epgId: r['epg_id'] as String?,
        number: r['num'] as int?,
        extId: r['ext_id'] as String?,
        container: r['container'] as String?,
        rating: (r['rating'] as num?)?.toDouble(),
        year: r['year'] as String?,
        catchupDays: r['catchup_days'] as int?,
        headers: decodeHeaders(r['headers'] as String?),
        isFavorite: (r['fav'] as int? ?? 0) == 1,
      );

  MediaItem copyWith({bool? isFavorite}) => MediaItem(
        id: id,
        sourceId: sourceId,
        kind: kind,
        key: key,
        name: name,
        categoryId: categoryId,
        logo: logo,
        url: url,
        epgId: epgId,
        number: number,
        extId: extId,
        container: container,
        rating: rating,
        year: year,
        catchupDays: catchupDays,
        headers: headers,
        isFavorite: isFavorite ?? this.isFavorite,
      );
}

Map<String, String> decodeHeaders(String? json) {
  if (json == null || json.isEmpty) return const {};
  try {
    return (jsonDecode(json) as Map).cast<String, String>();
  } catch (_) {
    return const {};
  }
}

class Programme {
  Programme({
    required this.channel,
    required this.start,
    required this.stop,
    required this.title,
    this.description,
    this.category,
  });

  final String channel;
  final DateTime start;
  final DateTime stop;
  final String title;
  final String? description;
  final String? category;

  bool isLiveAt(DateTime t) => !t.isBefore(start) && t.isBefore(stop);

  double progressAt(DateTime t) {
    final total = stop.difference(start).inSeconds;
    if (total <= 0) return 0;
    return (t.difference(start).inSeconds / total).clamp(0.0, 1.0);
  }

  factory Programme.fromRow(Map<String, Object?> r) => Programme(
        channel: r['channel'] as String,
        start: DateTime.fromMillisecondsSinceEpoch((r['start'] as int) * 1000),
        stop: DateTime.fromMillisecondsSinceEpoch((r['stop'] as int) * 1000),
        title: r['title'] as String,
        description: r['descr'] as String?,
        category: r['category'] as String?,
      );
}

class HistoryEntry {
  HistoryEntry({
    required this.sourceId,
    required this.key,
    required this.kind,
    required this.name,
    required this.url,
    required this.position,
    required this.duration,
    required this.updatedAt,
    this.logo,
  });

  final int sourceId;
  final String key;
  final ItemKind kind;
  final String name;
  final String? logo;
  final String url;
  final Duration position;
  final Duration duration;
  final DateTime updatedAt;

  double get progress => duration.inMilliseconds == 0
      ? 0
      : (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0);

  factory HistoryEntry.fromRow(Map<String, Object?> r) => HistoryEntry(
        sourceId: r['source_id'] as int,
        key: r['key'] as String,
        kind: ItemKind.fromInt(r['kind'] as int),
        name: r['name'] as String,
        logo: r['logo'] as String?,
        url: r['url'] as String,
        position: Duration(milliseconds: r['position_ms'] as int),
        duration: Duration(milliseconds: r['duration_ms'] as int),
        updatedAt:
            DateTime.fromMillisecondsSinceEpoch((r['updated_at'] as int) * 1000),
      );
}

/// Something the player can open: a channel, a movie or a series episode.
class Playable {
  Playable({
    required this.sourceId,
    required this.key,
    required this.kind,
    required this.title,
    required this.url,
    this.subtitle,
    this.logo,
    this.headers = const {},
    this.epgId,
    this.resumeFrom,
  });

  final int sourceId;
  final String key;
  final ItemKind kind;
  final String title;
  final String? subtitle;
  final String url;
  final String? logo;
  final Map<String, String> headers;
  final String? epgId;
  final Duration? resumeFrom;

  bool get isLive => kind == ItemKind.live;
}

/// Series episode, fetched on demand from Xtream (`get_series_info`).
class Episode {
  Episode({
    required this.id,
    required this.season,
    required this.number,
    required this.title,
    required this.url,
    this.plot,
    this.image,
    this.duration,
  });

  final String id;
  final int season;
  final int number;
  final String title;
  final String url;
  final String? plot;
  final String? image;
  final String? duration;
}
