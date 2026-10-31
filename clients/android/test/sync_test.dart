// End-to-end: real Dart sync engine + real Rust core (via dart:ffi) against the
// real Rust server. Needs ZERO_SUM_FFI and ZERO_SUM_SERVER, see tool/test.sh.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zero_sum/core.dart';
import 'package:zero_sum/db.dart';

/// Real HTTP unless switched off, which fails like a dead network.
class Net extends http.BaseClient {
  final _inner = http.Client();
  bool online = true;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest r) =>
      online ? _inner.send(r) : Future.error(http.ClientException('offline'));
}

late Process server;
late String base;
late Directory tmp;
const month = '2026-10';

Future<Db> device(Net net, {String? file}) async {
  final sql = await databaseFactoryFfi.openDatabase(file ?? inMemoryDatabasePath,
      options: OpenDatabaseOptions(version: 1, onCreate: Db.create));
  final db = await Db.open(sql, client: net);
  await db.setServer(base);
  return db;
}

Future<void> until(bool Function() ok, [String what = 'condition']) async {
  final end = DateTime.now().add(const Duration(seconds: 10));
  while (!ok()) {
    if (DateTime.now().isAfter(end)) fail('timeout waiting for $what');
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
}

Map<String, dynamic> budgetOf(Db db) =>
    Core.instance.budget([for (final e in db.entities.values) e.json], month);

Future<Map<String, dynamic>> serverBudget() async =>
    jsonDecode((await http.get(Uri.parse('$base/budget/$month'))).body) as Map<String, dynamic>;

void main() {
  setUpAll(() async {
    sqfliteFfiInit();
    final bin = Platform.environment['ZERO_SUM_SERVER'];
    if (bin == null || Platform.environment['ZERO_SUM_FFI'] == null) {
      throw StateError('set ZERO_SUM_SERVER and ZERO_SUM_FFI, or run tool/test.sh');
    }
    tmp = Directory.systemTemp.createTempSync('zs');
    final s = await ServerSocket.bind('127.0.0.1', 0);
    final port = s.port;
    await s.close();
    base = 'http://127.0.0.1:$port';
    server = await Process.start(bin, [], environment: {
      'ZERO_SUM_ADDR': '127.0.0.1:$port',
      'ZERO_SUM_DB': '${tmp.path}/server.db',
    });
    for (var i = 0; i < 100; i++) {
      try {
        if ((await http.get(Uri.parse('$base/health'))).statusCode == 200) return;
      } catch (_) {}
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    fail('server did not start');
  });

  tearDownAll(() {
    server.kill();
    tmp.deleteSync(recursive: true);
  });

  test('two devices converge and match the server budget', () async {
    final a = await device(Net()), b = await device(Net());
    final acct = newId(), group = newId(), food = newId();
    await a.edit('account', acct, {'name': 'Checking', 'kind': 'checking'});
    await a.edit('category_group', group, {'name': 'Needs'});
    await a.edit('category', food, {'group_id': group, 'name': 'Food'});
    await a.edit('transaction', newId(),
        {'account_id': acct, 'date': '2026-10-01', 'amount': 3000000});
    await a.edit('transaction', newId(),
        {'account_id': acct, 'date': '2026-10-05', 'amount': -400000, 'category_id': food});
    await a.edit('budget_entry', Core.instance.budgetEntryId(food, month),
        {'category_id': food, 'month': month, 'assigned': 500000});
    await a.sync();
    expect(a.outbox, isEmpty);

    await b.sync();
    expect(b.list('transaction'), hasLength(2));
    final want = await serverBudget();
    expect(want['ready_to_assign'], 2500000);
    expect(budgetOf(a), want);
    expect(budgetOf(b), want);
  });

  test('offline edits merge per field and converge', () async {
    final na = Net(), nb = Net();
    final a = await device(na), b = await device(nb);
    final acct = newId();
    await a.edit('account', acct, {'name': 'Cash', 'kind': 'cash'});
    await a.sync();
    await b.sync();

    na.online = nb.online = false;
    await a.edit('account', acct, {'name': 'Wallet A'});
    await a.edit('account', acct, {'note': 'from A'});
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await b.edit('account', acct, {'name': 'Wallet B'});
    await a.sync();
    expect(a.state, SyncState.offline);
    expect(a.outbox, hasLength(2));
    expect(b.outbox, hasLength(1));

    na.online = nb.online = true;
    await a.sync();
    await b.sync();
    await a.sync();

    for (final d in [a, b]) {
      expect(d.outbox, isEmpty);
      expect(d.get('account', acct)!.data['name'], 'Wallet B'); // later write wins
      expect(d.get('account', acct)!.data['note'], 'from A'); // other field kept
    }
    expect(a.get('account', acct)!.json, b.get('account', acct)!.json);
  });

  test('delete syncs as a tombstone', () async {
    final a = await device(Net()), b = await device(Net());
    final id = newId();
    await a.edit('payee', id, {'name': 'Shop'});
    await a.sync();
    await b.sync();
    expect(b.list('payee'), hasLength(1));
    await a.remove('payee', id);
    await a.sync();
    await b.sync();
    expect(b.list('payee'), isEmpty);
  });

  test('outbox and cursor survive a restart', () async {
    final file = '${tmp.path}/dev.db';
    final net = Net()..online = false;
    var d = await device(net, file: file);
    final id = newId();
    await d.edit('payee', id, {'name': 'Offline'});
    expect(d.outbox, hasLength(1));
    d.dispose();
    await (await databaseFactoryFfi.openDatabase(file)).close();

    net.online = true;
    d = await device(net, file: file);
    expect(d.outbox, hasLength(1));
    expect(d.get('payee', id)!.data['name'], 'Offline');
    await d.sync();
    expect(d.outbox, isEmpty);
    expect(d.cursor, greaterThan(0));
    final pull = jsonDecode((await http.get(Uri.parse('$base/sync/pull?since=0'))).body);
    expect((pull['changes'] as List).any((c) => c['id'] == id), isTrue);
  });

  test('invalid edit throws and queues nothing', () async {
    final d = await device(Net());
    expect(() => d.edit('account', newId(), {'nmae': 'x'}), throwsA(isA<CoreException>()));
    expect(d.outbox, isEmpty);
  });

  test('WebSocket nudge pulls without a manual sync', () async {
    final a = await device(Net()), b = await device(Net());
    a.connect();
    await until(() => a.cursor > 0 || a.state == SyncState.idle, 'ws connect');
    final id = newId();
    await b.edit('payee', id, {'name': 'Pushed'});
    await until(() => a.get('payee', id) != null, 'nudge pull');
    a.dispose();
  });
}
