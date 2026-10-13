import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import '../core/http.dart';
import '../parsers/xmltv_parser.dart';

/// Rows per batch sent from the parser isolate (6 values per row).
const _batchRows = 2000;

/// Batches allowed in flight before the parser waits for the writer.
/// Bounds memory regardless of guide size (~8 x 2000 rows).
const _window = 8;

/// Downloads and parses an XMLTV guide in a separate isolate, delivering
/// programmes to [onBatch] as flat rows: `[channel, start, stop, title,
/// descr, category, channel, start, ...]`.
///
/// Parsing (CPU-bound XML scanning) and the caller's SQLite inserts then run
/// on two cores in parallel, with credit-based flow control so a slow writer
/// can't make the parser buffer the whole guide in memory.
Future<XmltvResult> parseEpgInParallel({
  required String url,
  String? userAgent,
  required int windowStart,
  required int windowEnd,
  required void Function(List<Object?> rows) onBatch,
  void Function(int bytes, int? total)? onProgress,
}) async {
  final inbox = ReceivePort();
  final errors = ReceivePort();
  final exit = ReceivePort();
  final done = Completer<XmltvResult>();
  SendPort? credits;

  await Isolate.spawn(
    _parserMain,
    _ParserArgs(inbox.sendPort, url, userAgent, windowStart, windowEnd),
    debugName: 'epg-parser',
    onError: errors.sendPort,
    onExit: exit.sendPort,
  );

  void fail(Object e) {
    if (!done.isCompleted) done.completeError(e);
  }

  errors.listen((e) => fail(HttpException2('${(e as List)[0]}')));
  // Messages on different ports aren't strictly ordered; give a final
  // _Done a moment to arrive before treating the exit as a crash.
  exit.listen((_) => Timer(const Duration(milliseconds: 500),
      () => fail(HttpException2('TV guide parser stopped unexpectedly'))));

  inbox.listen((msg) {
    if (done.isCompleted) return;
    try {
      switch (msg) {
        case SendPort p:
          credits = p;
        case List<Object?> rows:
          onBatch(rows);
          credits?.send(1);
        case _Progress p:
          onProgress?.call(p.bytes, p.total);
        case _Done d:
          done.complete(XmltvResult(d.channelNames, d.programmes, d.skipped));
        case _Failed f:
          fail(f.error);
      }
    } catch (e) {
      // Writer failed (e.g. disk full): stop the parser and report.
      credits?.send(-1);
      fail(e);
    }
  });

  try {
    return await done.future;
  } finally {
    inbox.close();
    errors.close();
    exit.close();
  }
}

class _ParserArgs {
  _ParserArgs(this.out, this.url, this.userAgent, this.windowStart, this.windowEnd);
  final SendPort out;
  final String url;
  final String? userAgent;
  final int windowStart;
  final int windowEnd;
}

class _Progress {
  _Progress(this.bytes, this.total);
  final int bytes;
  final int? total;
}

class _Done {
  _Done(this.channelNames, this.programmes, this.skipped);
  final Map<String, List<String>> channelNames;
  final int programmes;
  final int skipped;
}

class _Failed {
  _Failed(this.error);
  final Object error;
}

Future<void> _parserMain(_ParserArgs a) async {
  final creditPort = ReceivePort();
  a.out.send(creditPort.sendPort);

  var available = _window;
  var cancelled = false;
  Completer<void>? waiting;
  creditPort.listen((v) {
    if (v == -1) cancelled = true;
    available++;
    waiting?.complete();
    waiting = null;
  });

  final client = createHttpClient(userAgent: a.userAgent);
  try {
    var bytes = 0;
    int? total;
    final stream = await openStream(a.url, client: client, onProgress: (r, t) {
      bytes = r;
      total = t;
    });

    var batch = <Object?>[];
    final pendingBatches = <List<Object?>>[];
    final parser = XmltvParser(
      windowStart: a.windowStart,
      windowEnd: a.windowEnd,
      onProgramme: (p) {
        batch
          ..add(p.channel)
          ..add(p.start)
          ..add(p.stop)
          ..add(p.title)
          ..add(p.description)
          ..add(p.category);
        if (batch.length >= _batchRows * 6) {
          pendingBatches.add(batch);
          batch = <Object?>[];
        }
      },
    );

    final progress = Stopwatch()..start();
    // First bytes of the (decompressed) body, kept to explain an empty result.
    final head = BytesBuilder(copy: true);
    var bodyBytes = 0;
    await for (final chunk in stream) {
      if (cancelled) return;
      bodyBytes += chunk.length;
      if (head.length < _headBytes) {
        head.add(chunk.length > _headBytes ? chunk.sublist(0, _headBytes) : chunk);
      }
      parser.add(chunk);
      // Hand over full batches, waiting for credits (backpressure).
      for (final b in pendingBatches) {
        while (available <= 0 && !cancelled) {
          await (waiting ??= Completer<void>()).future;
        }
        if (cancelled) return;
        available--;
        a.out.send(b);
      }
      pendingBatches.clear();
      if (progress.elapsedMilliseconds > 200) {
        progress.reset();
        a.out.send(_Progress(bytes, total));
      }
    }
    parser.close();
    for (final b in [...pendingBatches, if (batch.isNotEmpty) batch]) {
      while (available <= 0 && !cancelled) {
        await (waiting ??= Completer<void>()).future;
      }
      if (cancelled) return;
      available--;
      a.out.send(b);
    }
    a.out.send(_Progress(bytes, total));
    final r = parser.result;
    if (r.programmeCount == 0 && r.channelNames.isEmpty) {
      throw HttpException2(
          describeEmptyGuide(head.takeBytes(), bodyBytes, r.skipped));
    }
    a.out.send(_Done(r.channelNames, r.programmeCount, r.skipped));
  } catch (e) {
    a.out.send(_Failed(e is HttpException2 ? e : HttpException2(_describe(e))));
  } finally {
    client.close(force: true);
    creditPort.close();
  }
}

const _headBytes = 512;

/// Explains why a download produced no channels and no programmes, from the
/// first bytes of the body, so the user sees what the server actually sent.
String describeEmptyGuide(List<int> head, int bodyBytes, int skipped) {
  if (bodyBytes == 0) {
    return 'The TV guide server returned nothing — the provider may not '
        'include a TV guide (EPG) with this subscription';
  }
  if (head.length >= 2 &&
      ((head[0] == 0xFF && head[1] == 0xFE) || (head[0] == 0xFE && head[1] == 0xFF))) {
    return 'The TV guide is UTF-16 encoded, which is not supported (UTF-8 expected)';
  }
  if (head.length >= 4 && head[0] == 0x50 && head[1] == 0x4B && head[2] == 3 && head[3] == 4) {
    return 'The TV guide is a .zip archive — use the .xml or .xml.gz link instead';
  }
  final text = const Utf8Decoder(allowMalformed: true)
      .convert(head)
      .replaceFirst('﻿', '')
      .trimLeft();
  final lower = text.toLowerCase();
  String snippet() {
    final s = text.replaceAll(RegExp(r'\s+'), ' ');
    return s.length > 120 ? '${s.substring(0, 120)}…' : s;
  }

  if (text.isEmpty) {
    return 'The TV guide server returned an empty document — the provider may '
        'not include a TV guide (EPG) with this subscription';
  }
  if (text.startsWith('{') || text.startsWith('[')) {
    if (lower.contains('"auth":0') || lower.contains('"auth":"0"')) {
      return 'The TV guide server rejected the login (check username/password)';
    }
    return 'The TV guide server returned JSON instead of XMLTV: ${snippet()}';
  }
  if (lower.startsWith('<!doctype html') || lower.startsWith('<html')) {
    return 'The TV guide link returned a web page instead of XMLTV — check the URL';
  }
  if (skipped > 0) {
    return 'The TV guide only has programmes outside the shown time range '
        '($skipped skipped) — the provider\'s guide is out of date';
  }
  if (lower.contains('<tv')) return 'The TV guide contains no channels or programmes';
  return 'The TV guide is not valid XMLTV. It starts with: ${snippet()}';
}

String _describe(Object e) {
  final s = '$e';
  if (s.contains('SocketException')) return 'Network error while downloading the TV guide';
  if (s.contains('TimeoutException')) return 'The TV guide server took too long to respond';
  return s;
}
