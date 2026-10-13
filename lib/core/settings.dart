import 'dart:convert';

/// User preferences, persisted as one JSON blob in the `settings` table.
class AppSettings {
  const AppSettings({
    this.hardwareDecoding = true,
    this.cacheSeconds = 20,
    this.liveFormat = 'ts',
    this.userAgent = '',
    this.epgPastHours = 24,
    this.epgFutureDays = 3,
    this.autoRefreshHours = 24,
    this.epgRefreshHours = 12,
    this.epgOffsetMinutes = 0,
    this.volume = 100,
    this.activeSourceId,
    this.lastChannelKey,
    this.autoplayLastChannel = false,
  });

  final bool hardwareDecoding;
  final int cacheSeconds;
  final String liveFormat; // ts | m3u8
  final String userAgent;
  final int epgPastHours;
  final int epgFutureDays;
  final int autoRefreshHours; // 0 = off
  final int epgRefreshHours; // 0 = off
  final int epgOffsetMinutes;
  final double volume;
  final int? activeSourceId;
  final String? lastChannelKey;
  final bool autoplayLastChannel;

  AppSettings copyWith({
    bool? hardwareDecoding,
    int? cacheSeconds,
    String? liveFormat,
    String? userAgent,
    int? epgPastHours,
    int? epgFutureDays,
    int? autoRefreshHours,
    int? epgRefreshHours,
    int? epgOffsetMinutes,
    double? volume,
    int? activeSourceId,
    bool clearActiveSource = false,
    String? lastChannelKey,
    bool? autoplayLastChannel,
  }) =>
      AppSettings(
        hardwareDecoding: hardwareDecoding ?? this.hardwareDecoding,
        cacheSeconds: cacheSeconds ?? this.cacheSeconds,
        liveFormat: liveFormat ?? this.liveFormat,
        userAgent: userAgent ?? this.userAgent,
        epgPastHours: epgPastHours ?? this.epgPastHours,
        epgFutureDays: epgFutureDays ?? this.epgFutureDays,
        autoRefreshHours: autoRefreshHours ?? this.autoRefreshHours,
        epgRefreshHours: epgRefreshHours ?? this.epgRefreshHours,
        epgOffsetMinutes: epgOffsetMinutes ?? this.epgOffsetMinutes,
        volume: volume ?? this.volume,
        activeSourceId:
            clearActiveSource ? null : (activeSourceId ?? this.activeSourceId),
        lastChannelKey: lastChannelKey ?? this.lastChannelKey,
        autoplayLastChannel: autoplayLastChannel ?? this.autoplayLastChannel,
      );

  Map<String, Object?> toJson() => {
        'hardwareDecoding': hardwareDecoding,
        'cacheSeconds': cacheSeconds,
        'liveFormat': liveFormat,
        'userAgent': userAgent,
        'epgPastHours': epgPastHours,
        'epgFutureDays': epgFutureDays,
        'autoRefreshHours': autoRefreshHours,
        'epgRefreshHours': epgRefreshHours,
        'epgOffsetMinutes': epgOffsetMinutes,
        'volume': volume,
        'activeSourceId': activeSourceId,
        'lastChannelKey': lastChannelKey,
        'autoplayLastChannel': autoplayLastChannel,
      };

  factory AppSettings.fromJson(Map<String, Object?> j) {
    const d = AppSettings();
    T v<T>(String k, T fallback) {
      final x = j[k];
      if (x is T) return x;
      if (T == double && x is num) return x.toDouble() as T;
      return fallback;
    }

    return AppSettings(
      hardwareDecoding: v('hardwareDecoding', d.hardwareDecoding),
      cacheSeconds: v('cacheSeconds', d.cacheSeconds),
      liveFormat: v('liveFormat', d.liveFormat),
      userAgent: v('userAgent', d.userAgent),
      epgPastHours: v('epgPastHours', d.epgPastHours),
      epgFutureDays: v('epgFutureDays', d.epgFutureDays),
      autoRefreshHours: v('autoRefreshHours', d.autoRefreshHours),
      epgRefreshHours: v('epgRefreshHours', d.epgRefreshHours),
      epgOffsetMinutes: v('epgOffsetMinutes', d.epgOffsetMinutes),
      volume: v('volume', d.volume),
      activeSourceId: j['activeSourceId'] as int?,
      lastChannelKey: j['lastChannelKey'] as String?,
      autoplayLastChannel: v('autoplayLastChannel', d.autoplayLastChannel),
    );
  }

  String encode() => jsonEncode(toJson());
  static AppSettings decode(String? s) {
    if (s == null) return const AppSettings();
    try {
      return AppSettings.fromJson((jsonDecode(s) as Map).cast<String, Object?>());
    } catch (_) {
      return const AppSettings();
    }
  }
}
