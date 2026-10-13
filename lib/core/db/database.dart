import 'dart:async';
import 'dart:isolate';

import 'package:sqlite3/sqlite3.dart';

import 'schema.dart';

typedef DbRow = Map<String, Object?>;

/// All UI-side database access goes through one long-lived worker isolate, so
/// no query (FTS search, EPG range, paging) ever runs on the UI thread.
///
/// Heavy imports open their own connection in their own isolate; WAL mode lets
/// the UI keep reading the previous snapshot while an import transaction runs.
class AppDatabase {
  AppDatabase._(this.path, this._send, this._isolate, this._receive);

  final String path;
  final SendPort _send;
  final Isolate _isolate;
  final ReceivePort _receive;
  final _pending = <int, Completer<Object?>>{};
  int _nextId = 0;

  final _changes = StreamController<Set<String>>.broadcast();

  /// Emits the set of table groups touched by a write ('favorites', 'items'...).
  Stream<Set<String>> get changes => _changes.stream;

  static Future<AppDatabase> open(String path) async {
    final receive = ReceivePort();
    final isolate = await Isolate.spawn(
      _workerMain,
      [receive.sendPort, path],
      debugName: 'db-worker',
    );
    final ready = Completer<SendPort>();
    AppDatabase? db;
    receive.listen((msg) {
      if (!ready.isCompleted) {
        if (msg is SendPort) {
          ready.complete(msg);
        } else {
          ready.completeError(StateError('Database failed to open: $msg'));
        }
        return;
      }
      db?._onMessage(msg as List);
    });
    final send = await ready.future;
    return db = AppDatabase._(path, send, isolate, receive);
  }

  void _onMessage(List msg) {
    final id = msg[0] as int;
    final c = _pending.remove(id);
    if (c == null) return;
    if (msg[1] == true) {
      c.complete(msg[2]);
    } else {
      c.completeError(SqliteWorkerException(msg[2] as String));
    }
  }

  Future<T> _call<T>(int op, String sql, List<Object?> params, [String? file]) {
    final id = _nextId++;
    final c = Completer<Object?>();
    _pending[id] = c;
    _send.send([id, op, sql, params, file]);
    return c.future.then((v) => v as T);
  }

  Future<List<DbRow>> select(String sql,
      [List<Object?> params = const []]) => _selectIn(null, sql, params);

  /// Runs a read-only query against another SQLite file (an EPG guide file).
  /// The connection stays open until [releaseFiles].
  Future<List<DbRow>> selectFile(String file, String sql,
          [List<Object?> params = const []]) =>
      _selectIn(file, sql, params);

  /// Closes cached read-only file connections whose path contains [match]
  /// (all when null), so the files can be deleted.
  Future<void> releaseFiles([String? match]) =>
      _call<Object?>(_opRelease, match ?? '', const []);

  Future<List<DbRow>> _selectIn(String? file, String sql, List<Object?> params) async {
    final res = await _call<List>(_opSelect, sql, params, file);
    final cols = (res[0] as List).cast<String>();
    final rows = res[1] as List;
    return [
      for (final r in rows)
        {for (var i = 0; i < cols.length; i++) cols[i]: (r as List)[i]},
    ];
  }

  Future<DbRow?> selectOne(String sql,
      [List<Object?> params = const []]) async {
    final rows = await select(sql, params);
    return rows.isEmpty ? null : rows.first;
  }

  /// Executes a write and returns the affected-row count. [touches] is
  /// broadcast on [changes] so watching UI can refresh.
  Future<int> execute(
    String sql, [
    List<Object?> params = const [],
    Set<String> touches = const {},
  ]) async {
    final n = await _call<int>(_opExecute, sql, params);
    if (touches.isNotEmpty) _changes.add(touches);
    return n;
  }

  /// Executes an INSERT and returns the new rowid.
  Future<int> insert(String sql, List<Object?> params,
      {Set<String> touches = const {}}) async {
    final id = await _call<int>(_opInsert, sql, params);
    if (touches.isNotEmpty) _changes.add(touches);
    return id;
  }

  void notify(Set<String> touches) => _changes.add(touches);

  Future<void> close() async {
    await _call<Object?>(_opClose, '', const []);
    _receive.close();
    _isolate.kill();
    await _changes.close();
  }
}

class SqliteWorkerException implements Exception {
  SqliteWorkerException(this.message);
  final String message;
  @override
  String toString() => 'Database error: $message';
}

const _opSelect = 0;
const _opExecute = 1;
const _opInsert = 2;
const _opClose = 3;
const _opRelease = 4;

Database openConnection(String path) {
  final db = sqlite3.open(path);
  configureConnection(db);
  return db;
}

void _workerMain(List args) {
  final replyTo = args[0] as SendPort;
  final path = args[1] as String;
  final Database db;
  try {
    db = openConnection(path);
    migrate(db);
  } catch (e) {
    replyTo.send('$e');
    return;
  }

  final port = ReceivePort();
  replyTo.send(port.sendPort);
  final files = <String, Database>{};

  Database fileDb(String path) => files[path] ??= () {
        final d = sqlite3.open(path, mode: OpenMode.readOnly);
        d.execute('PRAGMA cache_size = -8000;');
        return d;
      }();

  port.listen((msg) {
    final m = msg as List;
    final id = m[0] as int;
    final op = m[1] as int;
    final sql = m[2] as String;
    final params = (m[3] as List).cast<Object?>();
    final file = m[4] as String?;
    try {
      switch (op) {
        case _opSelect:
          final rs = (file == null ? db : fileDb(file)).select(sql, params);
          replyTo.send([
            id,
            true,
            [rs.columnNames, rs.rows],
          ]);
        case _opExecute:
          db.execute(sql, params);
          replyTo.send([id, true, db.updatedRows]);
        case _opInsert:
          db.execute(sql, params);
          replyTo.send([id, true, db.lastInsertRowId]);
        case _opRelease:
          files.removeWhere((path, d) {
            if (sql.isNotEmpty && !path.contains(sql)) return false;
            d.close();
            return true;
          });
          replyTo.send([id, true, null]);
        case _opClose:
          for (final d in files.values) {
            d.close();
          }
          files.clear();
          db.close();
          replyTo.send([id, true, null]);
          port.close();
      }
    } catch (e) {
      replyTo.send([id, false, '$e']);
    }
  });
}
