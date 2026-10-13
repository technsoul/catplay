import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

/// A programme as parsed from XMLTV (times in unix seconds, UTC).
class XmltvProgramme {
  XmltvProgramme({
    required this.channel,
    required this.start,
    required this.stop,
    required this.title,
    this.description,
    this.category,
  });

  final String channel;
  final int start;
  final int stop;
  final String title;
  final String? description;
  final String? category;
}

class XmltvResult {
  XmltvResult(this.channelNames, this.programmeCount, this.skipped);

  /// XMLTV channel id -> display names (used for name-based matching).
  final Map<String, List<String>> channelNames;
  final int programmeCount;
  final int skipped;
}

const _utf8 = Utf8Decoder(allowMalformed: true);

// Byte patterns.
final _pProgramme = ascii.encode('<programme');
final _pProgrammeEnd = ascii.encode('</programme>');
final _pChannel = ascii.encode('<channel');
final _pChannelEnd = ascii.encode('</channel>');
final _aChannel = ascii.encode('channel');
final _aStart = ascii.encode('start');
final _aStop = ascii.encode('stop');
final _aId = ascii.encode('id');
final _tTitle = ascii.encode('title');
final _tDesc = ascii.encode('desc');
final _tCategory = ascii.encode('category');
final _tDisplayName = ascii.encode('display-name');

/// Streaming XMLTV scanner working directly on UTF-8 bytes.
///
/// XMLTV is a flat list of `<channel>` and `<programme>` elements, so instead
/// of a general XML tokenizer this scans bytes for those elements and only
/// UTF-8-decodes the handful of fields that are stored. Programmes outside
/// the time window are rejected from their start tag alone. Memory stays
/// flat: only the unfinished tail of the current chunk is kept.
class XmltvParser {
  XmltvParser({
    required this.onProgramme,
    required this.windowStart,
    required this.windowEnd,
  });

  final void Function(XmltvProgramme) onProgramme;
  final int windowStart;
  final int windowEnd;

  final channelNames = <String, List<String>>{};
  int programmes = 0;
  int skipped = 0;

  Uint8List _buf = Uint8List(0);
  int _len = 0;
  int _pos = 0;

  /// Max bytes buffered while looking for an element's end before the element
  /// is treated as malformed and skipped.
  static const _maxElement = 4 * 1024 * 1024;

  void add(List<int> chunk) {
    final left = _len - _pos;
    final need = left + chunk.length;
    if (_pos == 0 && need <= _buf.length) {
      _buf.setRange(_len, need, chunk);
    } else {
      final nb = need <= _buf.length ? _buf : Uint8List(need * 2 > 1 << 16 ? need + (need >> 1) : 1 << 16);
      nb.setRange(0, left, _buf, _pos);
      nb.setRange(left, need, chunk);
      _buf = nb;
    }
    _len = need;
    _pos = 0;
    _scan();
  }

  void close() {
    _scan();
    _buf = Uint8List(0);
    _len = _pos = 0;
  }

  void _scan() {
    final b = _buf;
    final len = _len;
    var pos = _pos;
    while (pos < len) {
      // Next '<'.
      var lt = pos;
      while (lt < len && b[lt] != 0x3C) {
        lt++;
      }
      // Need "<programme" plus the following byte to classify the tag.
      if (lt + 11 > len) {
        pos = lt;
        break;
      }
      final c1 = b[lt + 1];
      int next;
      if (c1 == 0x70 && _startsWith(b, lt, _pProgramme) && _isBoundary(b[lt + 10])) {
        next = _element(b, len, lt, 10, _pProgrammeEnd, true);
      } else if (c1 == 0x63 && _startsWith(b, lt, _pChannel) && _isBoundary(b[lt + 8])) {
        next = _element(b, len, lt, 8, _pChannelEnd, false);
      } else {
        pos = lt + 1;
        continue;
      }
      if (next == -1) {
        pos = lt;
        break;
      }
      pos = next;
    }
    _pos = pos;
  }

  /// Handles one element at [lt]; returns the index after it or -1 if more
  /// data is needed.
  int _element(Uint8List b, int len, int lt, int nameLen, List<int> close,
      bool isProgramme) {
    final tagEnd = _indexOfByte(b, 0x3E, lt + nameLen, len); // '>'
    if (tagEnd == -1) return _needMore(len, lt);
    final selfClosing = b[tagEnd - 1] == 0x2F;
    final attrsEnd = selfClosing ? tagEnd - 1 : tagEnd;
    final attrsStart = lt + nameLen;

    if (isProgramme) {
      // Reject out-of-window programmes before looking for the body.
      final start = _timeAttr(b, attrsStart, attrsEnd, _aStart);
      if (start == null || start > windowEnd) {
        return _skipTo(b, len, lt, tagEnd, selfClosing, close);
      }
      var stop = _timeAttr(b, attrsStart, attrsEnd, _aStop);
      if (stop == null || stop <= start) stop = start + 3600;
      if (stop < windowStart) {
        return _skipTo(b, len, lt, tagEnd, selfClosing, close);
      }
      final ch = _attrRange(b, attrsStart, attrsEnd, _aChannel);
      if (ch == null) return _skipTo(b, len, lt, tagEnd, selfClosing, close);

      var bodyEnd = tagEnd + 1;
      var after = tagEnd + 1;
      if (!selfClosing) {
        final end = _indexOf(b, close, tagEnd + 1, len);
        if (end == -1) return _needMore(len, lt);
        bodyEnd = end;
        after = end + close.length;
      }
      final bs = tagEnd + 1;
      final title = _childText(b, bs, bodyEnd, _tTitle);
      final desc = _childText(b, bs, bodyEnd, _tDesc);
      final cat = _childText(b, bs, bodyEnd, _tCategory);
      programmes++;
      onProgramme(XmltvProgramme(
        channel: decodeEntities(_utf8.convert(b, ch.$1, ch.$2)),
        start: start,
        stop: stop,
        title: (title == null || title.isEmpty) ? 'No title' : title,
        description: (desc == null || desc.isEmpty) ? null : desc,
        category: (cat == null || cat.isEmpty) ? null : cat,
      ));
      return after;
    }

    // <channel>
    if (selfClosing) return tagEnd + 1;
    final end = _indexOf(b, close, tagEnd + 1, len);
    if (end == -1) return _needMore(len, lt);
    final id = _attrRange(b, attrsStart, attrsEnd, _aId);
    if (id != null) {
      final names = <String>[];
      var from = tagEnd + 1;
      while (true) {
        final r = _childRange(b, from, end, _tDisplayName);
        if (r == null) break;
        final name = _decodeText(b, r.$1, r.$2);
        if (name.isNotEmpty) names.add(name);
        from = r.$3;
      }
      if (names.isNotEmpty) {
        (channelNames[decodeEntities(_utf8.convert(b, id.$1, id.$2))] ??= [])
            .addAll(names);
      }
    }
    return end + close.length;
  }

  int _skipTo(Uint8List b, int len, int lt, int tagEnd, bool selfClosing,
      List<int> close) {
    skipped++;
    if (selfClosing) return tagEnd + 1;
    final end = _indexOf(b, close, tagEnd + 1, len);
    if (end == -1) {
      skipped--; // will be counted when re-scanned
      return _needMore(len, lt);
    }
    return end + close.length;
  }

  int _needMore(int len, int lt) {
    if (len - lt > _maxElement) {
      skipped++;
      return lt + 1; // malformed: skip past this '<'
    }
    return -1;
  }

  XmltvResult get result => XmltvResult(channelNames, programmes, skipped);
}

bool _isBoundary(int c) =>
    c == 0x20 || c == 0x3E || c == 0x2F || c == 0x09 || c == 0x0A || c == 0x0D;

bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

bool _startsWith(Uint8List b, int at, List<int> p) {
  for (var k = 1; k < p.length; k++) {
    if (b[at + k] != p[k]) return false;
  }
  return true;
}

int _indexOfByte(Uint8List b, int byte, int from, int end) {
  for (var i = from; i < end; i++) {
    if (b[i] == byte) return i;
  }
  return -1;
}

int _indexOf(Uint8List b, List<int> p, int from, int end) {
  final first = p[0];
  final pl = p.length;
  final last = end - pl;
  outer:
  for (var i = from; i <= last; i++) {
    if (b[i] != first) continue;
    for (var k = 1; k < pl; k++) {
      if (b[i + k] != p[k]) continue outer;
    }
    return i;
  }
  return -1;
}

/// Value range (start, end) of attribute [name] within b[from:to].
(int, int)? _attrRange(Uint8List b, int from, int to, List<int> name) {
  var i = from;
  while (true) {
    i = _indexOf(b, name, i, to);
    if (i == -1) return null;
    final before = i == from ? 0x20 : b[i - 1];
    var j = i + name.length;
    while (j < to && _isSpace(b[j])) {
      j++;
    }
    if (_isSpace(before) && j < to && b[j] == 0x3D) {
      j++;
      while (j < to && _isSpace(b[j])) {
        j++;
      }
      if (j >= to) return null;
      final q = b[j];
      if (q == 0x22 || q == 0x27) {
        final e = _indexOfByte(b, q, j + 1, to);
        return e == -1 ? null : (j + 1, e);
      }
      var e = j;
      while (e < to && !_isSpace(b[e])) {
        e++;
      }
      return (j, e);
    }
    i += name.length;
  }
}

/// Parses a time attribute straight from bytes.
int? _timeAttr(Uint8List b, int from, int to, List<int> name) {
  final r = _attrRange(b, from, to, name);
  if (r == null) return null;
  return parseXmltvTimeBytes(b, r.$1, r.$2);
}

/// Finds `<tag ...>` ... `</tag>` within b[from:to].
/// Returns (textStart, textEnd, indexAfterClose).
(int, int, int)? _childRange(Uint8List b, int from, int to, List<int> tag) {
  var i = from;
  final tl = tag.length;
  while (true) {
    i = _indexOfByte(b, 0x3C, i, to);
    if (i == -1 || i + tl + 1 >= to) return null;
    var match = true;
    for (var k = 0; k < tl; k++) {
      if (b[i + 1 + k] != tag[k]) {
        match = false;
        break;
      }
    }
    if (match && _isBoundary(b[i + 1 + tl])) break;
    i++;
  }
  final gt = _indexOfByte(b, 0x3E, i, to);
  if (gt == -1) return null;
  if (b[gt - 1] == 0x2F) return (gt + 1, gt + 1, gt + 1);
  // Closing tag: "</" + tag + ">"
  var j = gt + 1;
  while (true) {
    j = _indexOfByte(b, 0x3C, j, to);
    if (j == -1 || j + tl + 2 >= to + 1) return null;
    if (b[j + 1] == 0x2F) {
      var match = true;
      for (var k = 0; k < tl; k++) {
        if (b[j + 2 + k] != tag[k]) {
          match = false;
          break;
        }
      }
      if (match && j + 2 + tl < to && b[j + 2 + tl] == 0x3E) {
        return (gt + 1, j, j + 3 + tl);
      }
    }
    j++;
  }
}

String? _childText(Uint8List b, int from, int to, List<int> tag) {
  final r = _childRange(b, from, to, tag);
  if (r == null) return null;
  return _decodeText(b, r.$1, r.$2);
}

String _decodeText(Uint8List b, int s, int e) {
  if (s >= e) return '';
  var text = _utf8.convert(b, s, e);
  if (text.contains('<![CDATA[')) {
    final out = StringBuffer();
    var i = 0;
    while (true) {
      final cs = text.indexOf('<![CDATA[', i);
      if (cs == -1) {
        out.write(decodeEntities(text.substring(i)));
        break;
      }
      out.write(decodeEntities(text.substring(i, cs)));
      final ce = text.indexOf(']]>', cs + 9);
      if (ce == -1) {
        out.write(text.substring(cs + 9));
        break;
      }
      out.write(text.substring(cs + 9, ce));
      i = ce + 3;
    }
    text = out.toString();
  } else {
    text = decodeEntities(text);
  }
  return text.trim();
}

/// Decodes the five XML entities plus numeric character references.
String decodeEntities(String s) {
  if (!s.contains('&')) return s;
  final b = StringBuffer();
  var i = 0;
  while (i < s.length) {
    final amp = s.indexOf('&', i);
    if (amp == -1) {
      b.write(s.substring(i));
      break;
    }
    b.write(s.substring(i, amp));
    final semi = s.indexOf(';', amp);
    if (semi == -1 || semi - amp > 10) {
      b.write('&');
      i = amp + 1;
      continue;
    }
    final ent = s.substring(amp + 1, semi);
    String? rep;
    switch (ent) {
      case 'amp':
        rep = '&';
      case 'lt':
        rep = '<';
      case 'gt':
        rep = '>';
      case 'quot':
        rep = '"';
      case 'apos':
        rep = "'";
      default:
        if (ent.startsWith('#')) {
          final code = ent.length > 1 && (ent[1] == 'x' || ent[1] == 'X')
              ? int.tryParse(ent.substring(2), radix: 16)
              : int.tryParse(ent.substring(1));
          if (code != null && code > 0 && code <= 0x10FFFF) {
            rep = String.fromCharCode(code);
          }
        }
    }
    if (rep == null) {
      b.write('&');
      i = amp + 1;
    } else {
      b.write(rep);
      i = semi + 1;
    }
  }
  return b.toString();
}

/// Parses XMLTV time `YYYYMMDDhhmm[ss][ ±hhmm]` from bytes b[s:e].
/// Returns unix seconds UTC, or null if malformed.
int? parseXmltvTimeBytes(List<int> b, int s, int e) {
  while (s < e && _isSpace(b[s])) {
    s++;
  }
  if (e - s < 12) return null;
  int d(int at, int n) {
    var v = 0;
    for (var i = at; i < at + n; i++) {
      final c = b[i] - 0x30;
      if (c < 0 || c > 9) return -1;
      v = v * 10 + c;
    }
    return v;
  }

  final year = d(s, 4), month = d(s + 4, 2), day = d(s + 6, 2);
  final hour = d(s + 8, 2), minute = d(s + 10, 2);
  if (year < 0 || month < 1 || month > 12 || day < 1 || day > 31 ||
      hour < 0 || hour > 23 || minute < 0 || minute > 59) {
    return null;
  }
  var second = 0;
  var i = s + 12;
  if (e - s >= 14) {
    final sec = d(s + 12, 2);
    if (sec >= 0) {
      second = sec;
      i = s + 14;
    }
  }
  while (i < e && _isSpace(b[i])) {
    i++;
  }
  var offset = 0;
  if (e - i >= 5 && (b[i] == 0x2B || b[i] == 0x2D)) {
    final oh = d(i + 1, 2), om = d(i + 3, 2);
    if (oh >= 0 && om >= 0) {
      offset = (oh * 3600 + om * 60) * (b[i] == 0x2D ? -1 : 1);
    }
  }
  return _daysFromCivil(year, month, day) * 86400 +
      hour * 3600 +
      minute * 60 +
      second -
      offset;
}

/// Days since 1970-01-01 (Howard Hinnant's algorithm; avoids DateTime cost).
int _daysFromCivil(int y, int m, int d) {
  y -= m <= 2 ? 1 : 0;
  final era = (y >= 0 ? y : y - 399) ~/ 400;
  final yoe = y - era * 400;
  final doy = (153 * (m + (m > 2 ? -3 : 9)) + 2) ~/ 5 + d - 1;
  final doe = yoe * 365 + yoe ~/ 4 - yoe ~/ 100 + doy;
  return era * 146097 + doe - 719468;
}

/// String convenience wrapper around [parseXmltvTimeBytes].
int? parseXmltvTime(String? s) {
  if (s == null) return null;
  final bytes = utf8.encode(s);
  return parseXmltvTimeBytes(bytes, 0, bytes.length);
}

/// Parses an XMLTV byte stream (already gunzipped if needed).
Future<XmltvResult> parseXmltvStream(
  Stream<List<int>> bytes, {
  required void Function(XmltvProgramme) onProgramme,
  required int windowStart,
  required int windowEnd,
}) async {
  final parser = XmltvParser(
    onProgramme: onProgramme,
    windowStart: windowStart,
    windowEnd: windowEnd,
  );
  await for (final chunk in bytes) {
    parser.add(chunk);
  }
  parser.close();
  return parser.result;
}
