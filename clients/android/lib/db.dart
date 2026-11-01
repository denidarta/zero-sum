// Local database + sync engine. Port of `clients/web/src/db.ts`.
//
// Edits apply to the local copy at once and queue in an outbox. Push sends the
// outbox, pull fetches entity state changed on the server. After a pull, still
// unsent ops are merged over the server state again, so edits made offline are
// never lost. Merge is idempotent, which makes that safe.
import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'core.dart';

enum SyncState { idle, syncing, offline }

const _pushBatch = 500;
const _timeout = Duration(seconds: 20);

typedef Json = Map<String, dynamic>;

class Entity {
  Entity(this.json);
  final Json json;
  String get kind => json['kind'] as String;
  String get id => json['id'] as String;
  bool get deleted => json['deleted'] as bool;
  Json get data => json['data'] as Json;

  String str(String field) => (data[field] as String?) ?? '';
  int get sort => (data['sort'] as int?) ?? 0;
}

String newId() => const Uuid().v4();

class Db extends ChangeNotifier {
  Db._(this._sql, this._http, this._core);

  /// Create the tables. Pass as `onCreate` with `version: 1`.
  static Future<void> create(Database db, int version) async {
    await db.execute(
      'CREATE TABLE entities (key TEXT PRIMARY KEY, json TEXT NOT NULL)',
    );
    await db.execute(
      'CREATE TABLE outbox (op_id TEXT PRIMARY KEY, ts INTEGER NOT NULL, json TEXT NOT NULL)',
    );
    await db.execute('CREATE TABLE meta (k TEXT PRIMARY KEY, v TEXT NOT NULL)');
  }

  static Future<Db> open(
    Database sql, {
    http.Client? client,
    Core? core,
  }) async {
    final db = Db._(sql, client ?? http.Client(), core ?? Core.instance);
    await db._load();
    return db;
  }

  final Database _sql;
  final http.Client _http;
  final Core _core;

  final Map<String, Entity> entities = {};
  List<Json> outbox = [];
  int cursor = 0;
  String deviceId = '';
  SyncState state = SyncState.idle;

  /// Bumped on every change so the UI knows to recompute.
  int version = 0;

  /// Server base URL without trailing slash. Empty means not configured.
  String serverUrl = '';

  int _lastTs = 0;
  Future<void>? _syncing;
  bool _again = false;
  WebSocketChannel? _ws;
  int _wsGen = 0;
  Timer? _wsTimer;
  Duration _wsDelay = const Duration(seconds: 1);
  bool _disposed = false;

  Future<void> _load() async {
    for (final r in await _sql.query('entities')) {
      final e = Entity(jsonDecode(r['json'] as String) as Json);
      entities['${e.kind}:${e.id}'] = e;
    }
    outbox = [
      for (final r in await _sql.query('outbox', orderBy: 'ts'))
        jsonDecode(r['json'] as String) as Json,
    ];
    final meta = {
      for (final r in await _sql.query('meta'))
        r['k'] as String: r['v'] as String,
    };
    cursor = int.tryParse(meta['cursor'] ?? '') ?? 0;
    serverUrl = meta['server'] ?? '';
    final device = meta['deviceId'];
    deviceId = device ?? newId();
    if (device == null) await _putMeta('deviceId', deviceId);
    _lastTs = outbox.fold(0, (m, o) => max(m, o['ts'] as int));
    _bump();
  }

  Future<void> _putMeta(String k, String v) => _sql.insert('meta', {
    'k': k,
    'v': v,
  }, conflictAlgorithm: ConflictAlgorithm.replace);

  void _bump() {
    version++;
    if (!_disposed) notifyListeners();
  }

  List<Entity> list(String kind) =>
      entities.values.where((e) => e.kind == kind && !e.deleted).toList();

  Entity? get(String kind, String id) => entities['$kind:$id'];

  Future<void> _tail = Future.value();

  /// Apply an edit locally and queue it for the server. Throws [CoreException]
  /// on invalid input and rethrows a failed disk write; nothing is queued or
  /// visible then. Edits run one at a time so each merges over the previous.
  Future<void> edit(String kind, String id, Json fields, {bool? deleted}) {
    final run = _tail.then((_) => _edit(kind, id, fields, deleted));
    _tail = run.catchError((_) {});
    return run;
  }

  Future<void> _edit(String kind, String id, Json fields, bool? deleted) async {
    // Strictly increasing so a later local edit always beats an earlier one.
    final ts = max(DateTime.now().millisecondsSinceEpoch, _lastTs + 1);
    final op = <String, dynamic>{
      'op_id': newId(),
      'ts': ts,
      'kind': kind,
      'entity_id': id,
      'fields': fields,
      'deleted': ?deleted,
    };
    final e = Entity(_core.merge(get(kind, id)?.json, op)['state'] as Json);
    // Disk first: memory changes only once the edit is durable.
    await _sql.transaction((t) async {
      await t.insert('entities', {
        'key': '$kind:$id',
        'json': jsonEncode(e.json),
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await t.insert('outbox', {
        'op_id': op['op_id'],
        'ts': ts,
        'json': jsonEncode(op),
      });
    });
    _lastTs = ts;
    entities['$kind:$id'] = e;
    outbox.add(op);
    _bump();
    unawaited(sync());
  }

  Future<void> remove(String kind, String id) =>
      edit(kind, id, {}, deleted: true);

  // ---- sync ----

  Uri _url(String path) => Uri.parse(serverUrl + path);

  /// Push then pull. Calls made while a sync runs are folded into one rerun.
  /// Never throws: a failure sets [SyncState.offline].
  Future<void> sync() {
    if (serverUrl.isEmpty) return Future.value();
    if (_syncing != null) {
      _again = true;
      return _syncing!;
    }
    return _syncing = () async {
      try {
        do {
          _again = false;
          _setState(SyncState.syncing);
          await _push();
          await _pull();
          _setState(SyncState.idle);
        } while (_again);
      } catch (e) {
        debugPrint('sync failed: $e');
        _setState(SyncState.offline);
      } finally {
        _syncing = null;
      }
    }();
  }

  void _setState(SyncState s) {
    if (state != s) {
      state = s;
      _bump();
    }
  }

  Future<void> _push() async {
    while (outbox.isNotEmpty) {
      final batch = outbox.take(_pushBatch).toList();
      final res = await _http
          .post(
            _url('/sync/push'),
            headers: {'content-type': 'application/json'},
            body: jsonEncode({'device_id': deviceId, 'ops': batch}),
          )
          .timeout(_timeout);
      if (res.statusCode != 200) throw Exception('push ${res.statusCode}');
      final results = (jsonDecode(res.body) as Json)['results'] as List;
      for (final r in results) {
        if (r['status'] == 'rejected') {
          debugPrint('op rejected: ${r['reason']}');
        }
      }
      // Every status is final, including rejected: resending cannot help.
      final done = {for (final r in results) r['op_id'] as String};
      outbox = outbox.where((o) => !done.contains(o['op_id'])).toList();
      final b = _sql.batch();
      for (final id in done) {
        b.delete('outbox', where: 'op_id = ?', whereArgs: [id]);
      }
      await b.commit(noResult: true);
      _bump();
    }
  }

  Future<void> _pull() async {
    for (;;) {
      final res = await _http
          .get(_url('/sync/pull?since=$cursor'))
          .timeout(_timeout);
      if (res.statusCode != 200) throw Exception('pull ${res.statusCode}');
      final page = jsonDecode(res.body) as Json;
      final b = _sql.batch();
      for (final c in page['changes'] as List) {
        var server = Map<String, dynamic>.of(c as Json)..remove('seq');
        for (final op in outbox) {
          if (op['kind'] == server['kind'] && op['entity_id'] == server['id']) {
            try {
              server = _core.merge(server, op)['state'] as Json;
            } on CoreException {
              // Invalid against server state; the push will reject it.
            }
          }
        }
        final e = Entity(server);
        entities['${e.kind}:${e.id}'] = e;
        b.insert('entities', {
          'key': '${e.kind}:${e.id}',
          'json': jsonEncode(server),
        }, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      cursor = page['cursor'] as int;
      b.insert('meta', {
        'k': 'cursor',
        'v': '$cursor',
      }, conflictAlgorithm: ConflictAlgorithm.replace);
      await b.commit(noResult: true);
      _bump();
      if (page['has_more'] != true) break;
    }
  }

  // ---- realtime nudge ----

  /// Open the WebSocket. A message only means "pull now".
  void connect() {
    _wsTimer?.cancel();
    final old = _ws;
    _ws = null;
    final gen = ++_wsGen;
    old?.sink.close();
    if (serverUrl.isEmpty || _disposed) return;

    void retry() {
      if (gen != _wsGen || _disposed) return;
      _wsTimer = Timer(_wsDelay, connect);
      _wsDelay = Duration(
        milliseconds: min(_wsDelay.inMilliseconds * 2, 30000),
      );
    }

    try {
      final ch = WebSocketChannel.connect(
        Uri.parse('${serverUrl.replaceFirst(RegExp('^http'), 'ws')}/sync/ws'),
      );
      _ws = ch;
      ch.ready.then(
        (_) => _wsDelay = const Duration(seconds: 1),
        onError: (_) {},
      );
      ch.stream.listen(
        (_) => unawaited(sync()),
        onDone: retry,
        onError: (_) => retry(),
        cancelOnError: true,
      );
    } on FormatException {
      _setState(SyncState.offline);
    }
  }

  Future<void> setServer(String url) async {
    var u = url.trim().replaceAll(RegExp(r'/+$'), '');
    if (u.isNotEmpty && !u.startsWith(RegExp('https?://'))) u = 'https://$u';
    serverUrl = u;
    await _putMeta('server', u);
    _bump();
    connect();
    unawaited(sync());
  }

  @override
  void dispose() {
    _disposed = true;
    _wsTimer?.cancel();
    _ws?.sink.close();
    super.dispose();
  }
}
