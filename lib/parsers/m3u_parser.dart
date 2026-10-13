import 'dart:async';
import 'dart:convert';

import '../core/models.dart';

/// One entry from an M3U / M3U8 (extended) playlist.
class M3uEntry {
  M3uEntry({
    required this.name,
    required this.url,
    required this.attrs,
    this.group,
    this.headers = const {},
    this.duration = -1,
  });

  final String name;
  final String url;
  final Map<String, String> attrs;
  final String? group;
  final Map<String, String> headers;
  final int duration;

  String? get tvgId => _nonEmpty(attrs['tvg-id']);
  String? get tvgName => _nonEmpty(attrs['tvg-name']);
  String? get logo => _nonEmpty(attrs['tvg-logo']) ?? _nonEmpty(attrs['logo']);
  int? get channelNumber =>
      int.tryParse(attrs['tvg-chno'] ?? attrs['channel-number'] ?? '');
  int? get catchupDays =>
      int.tryParse(attrs['catchup-days'] ?? attrs['timeshift'] ?? '');

  /// Live / movie / series, guessed from Xtream-style URLs and group names.
  ItemKind get kind {
    final u = url.toLowerCase();
    if (u.contains('/movie/')) return ItemKind.movie;
    if (u.contains('/series/')) return ItemKind.series;
    final g = (group ?? '').toLowerCase();
    if (_isVodExt(u) && !u.contains('/live/')) {
      if (g.contains('series') || _episodeRe.hasMatch(name)) {
        return ItemKind.series;
      }
      return ItemKind.movie;
    }
    return ItemKind.live;
  }
}

final _episodeRe = RegExp(r'\bS\d{1,2}\s?E\d{1,3}\b', caseSensitive: false);
const _vodExts = ['.mp4', '.mkv', '.avi', '.mov', '.wmv', '.m4v', '.webm'];
bool _isVodExt(String u) {
  final q = u.indexOf('?');
  final path = q == -1 ? u : u.substring(0, q);
  for (final e in _vodExts) {
    if (path.endsWith(e)) return true;
  }
  return false;
}

String? _nonEmpty(String? s) => (s == null || s.trim().isEmpty) ? null : s.trim();

/// Streaming M3U parser: memory use is independent of playlist size.
///
/// Feed it lines (see [parseM3uStream]) and receive entries one at a time.
class M3uParser {
  M3uParser(this.onEntry);

  final void Function(M3uEntry entry) onEntry;

  /// `url-tvg` / `x-tvg-url` from the `#EXTM3U` header, if any.
  String? epgUrl;

  String? _pendingInfo;
  String? _pendingGroup;
  Map<String, String>? _pendingHeaders;
  bool _first = true;
  int count = 0;

  void addLine(String raw) {
    var line = raw;
    if (_first) {
      _first = false;
      if (line.startsWith('﻿')) line = line.substring(1);
    }
    line = line.trim();
    if (line.isEmpty) return;

    if (line.startsWith('#')) {
      if (_startsWithIgnoreCase(line, '#EXTINF')) {
        _pendingInfo = line;
        _pendingGroup = null;
        _pendingHeaders = null;
      } else if (_startsWithIgnoreCase(line, '#EXTGRP:')) {
        _pendingGroup = line.substring(8).trim();
      } else if (_startsWithIgnoreCase(line, '#EXTVLCOPT:')) {
        _addOption(line.substring(11));
      } else if (_startsWithIgnoreCase(line, '#KODIPROP:')) {
        _addOption(line.substring(10));
      } else if (_startsWithIgnoreCase(line, '#EXTM3U')) {
        final attrs = parseAttributes(line, 7, line.length);
        epgUrl = _nonEmpty(attrs['url-tvg']) ?? _nonEmpty(attrs['x-tvg-url']);
        if (epgUrl != null && epgUrl!.contains(',')) {
          epgUrl = epgUrl!.split(',').first.trim();
        }
      }
      return;
    }

    // A URL line.
    final info = _pendingInfo;
    if (info == null) {
      // Plain (non-extended) playlist: URL only.
      _emit(M3uEntry(name: _nameFromUrl(line), url: line, attrs: const {}));
    } else {
      _emit(_buildEntry(info, line));
    }
    _pendingInfo = null;
    _pendingGroup = null;
    _pendingHeaders = null;
  }

  void _emit(M3uEntry e) {
    count++;
    onEntry(e);
  }

  void _addOption(String opt) {
    final eq = opt.indexOf('=');
    if (eq <= 0) return;
    final k = opt.substring(0, eq).trim().toLowerCase();
    final v = opt.substring(eq + 1).trim();
    final h = _pendingHeaders ??= {};
    switch (k) {
      case 'http-user-agent':
        h['User-Agent'] = v;
      case 'http-referrer':
      case 'http-referer':
        h['Referer'] = v;
      case 'http-origin':
        h['Origin'] = v;
    }
  }

  M3uEntry _buildEntry(String info, String url) {
    // #EXTINF:<duration> <attrs...>,<title>
    var i = 8; // past "#EXTINF:"
    final n = info.length;
    final durStart = i;
    while (i < n && info.codeUnitAt(i) != 0x20 && info.codeUnitAt(i) != 0x2C) {
      i++;
    }
    final duration = int.tryParse(info.substring(durStart, i).trim()) ?? -1;

    // Find title separator: first comma outside quotes.
    var inQuote = false;
    var comma = -1;
    for (var j = i; j < n; j++) {
      final c = info.codeUnitAt(j);
      if (c == 0x22) {
        inQuote = !inQuote;
      } else if (c == 0x2C && !inQuote) {
        comma = j;
        break;
      }
    }
    final attrs = parseAttributes(info, i, comma == -1 ? n : comma);
    var name = comma == -1 ? '' : info.substring(comma + 1).trim();
    if (name.isEmpty) name = attrs['tvg-name'] ?? _nameFromUrl(url);

    final headers = <String, String>{...?_pendingHeaders};
    final ua = attrs['user-agent'] ?? attrs['http-user-agent'];
    if (ua != null && ua.isNotEmpty) headers['User-Agent'] = ua;
    final ref = attrs['http-referrer'] ?? attrs['referer'];
    if (ref != null && ref.isNotEmpty) headers['Referer'] = ref;

    // Inline "url|User-Agent=...&Referer=..." (Kodi style).
    var cleanUrl = url;
    final pipe = url.indexOf('|');
    if (pipe != -1) {
      cleanUrl = url.substring(0, pipe);
      for (final part in url.substring(pipe + 1).split('&')) {
        final eq = part.indexOf('=');
        if (eq > 0) {
          headers[part.substring(0, eq)] =
              Uri.decodeComponent(part.substring(eq + 1));
        }
      }
    }

    return M3uEntry(
      name: name,
      url: cleanUrl,
      attrs: attrs,
      group: _nonEmpty(attrs['group-title']) ?? _nonEmpty(_pendingGroup),
      headers: headers,
      duration: duration,
    );
  }
}

/// Parses `key="value"` / `key=value` pairs in `s[start:end]`.
Map<String, String> parseAttributes(String s, int start, int end) {
  final out = <String, String>{};
  var i = start;
  while (i < end) {
    // skip spaces
    while (i < end && s.codeUnitAt(i) == 0x20) {
      i++;
    }
    final keyStart = i;
    while (i < end && s.codeUnitAt(i) != 0x3D && s.codeUnitAt(i) != 0x20) {
      i++;
    }
    if (i >= end || s.codeUnitAt(i) != 0x3D) {
      // token without value
      i++;
      continue;
    }
    final key = s.substring(keyStart, i).toLowerCase();
    i++; // '='
    String value;
    if (i < end && s.codeUnitAt(i) == 0x22) {
      i++;
      final vs = i;
      while (i < end && s.codeUnitAt(i) != 0x22) {
        i++;
      }
      value = s.substring(vs, i);
      i++; // closing quote
    } else {
      final vs = i;
      while (i < end && s.codeUnitAt(i) != 0x20) {
        i++;
      }
      value = s.substring(vs, i);
    }
    if (key.isNotEmpty) out[key] = value;
  }
  return out;
}

bool _startsWithIgnoreCase(String s, String prefix) {
  if (s.length < prefix.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    var a = s.codeUnitAt(i);
    var b = prefix.codeUnitAt(i);
    if (a >= 0x61 && a <= 0x7A) a -= 0x20;
    if (b >= 0x61 && b <= 0x7A) b -= 0x20;
    if (a != b) return false;
  }
  return true;
}

String _nameFromUrl(String url) {
  final uri = Uri.tryParse(url);
  final seg = uri?.pathSegments.where((s) => s.isNotEmpty).lastOrNull;
  return seg ?? url;
}

/// Parses a byte stream (file or HTTP body) and calls [onEntry] per entry.
Future<M3uParser> parseM3uStream(
  Stream<List<int>> bytes,
  void Function(M3uEntry) onEntry,
) async {
  final parser = M3uParser(onEntry);
  await for (final line in const LineSplitter()
      .bind(const Utf8Decoder(allowMalformed: true).bind(bytes))) {
    parser.addLine(line);
  }
  return parser;
}
