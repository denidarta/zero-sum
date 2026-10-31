import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zero_sum/app.dart';
import 'package:zero_sum/core.dart';
import 'package:zero_sum/db.dart';
import 'package:zero_sum/money.dart';

void main() {
  sqfliteFfiInit();

  testWidgets('budget: assign money to a category', (tester) async {
    late Db db;
    final month = thisMonth();
    await tester.runAsync(() async {
      final sql = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(
          version: 1,
          onCreate: Db.create,
          singleInstance: false,
        ),
      );
      db = await Db.open(sql);
      final acct = newId(), group = newId(), food = newId();
      await db.edit('account', acct, {'name': 'Checking', 'kind': 'checking'});
      await db.edit('category_group', group, {'name': 'Needs'});
      await db.edit('category', food, {'group_id': group, 'name': 'Food'});
      await db.edit('transaction', newId(), {
        'account_id': acct,
        'date': '$month-01',
        'amount': 1000000,
      });
    });

    await tester.pumpWidget(ZeroSumApp(db: db));
    await tester.pump();
    // No server configured: the app asks for one on first launch.
    expect(find.text('Server URL'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(find.byKey(const Key('rta'))).data, '1,000.00');
    expect(find.text('Food'), findsOneWidget);

    await tester.tap(find.byKey(const Key('cat-Food')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '250');
    await tester.tap(find.text('OK'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();

    expect(tester.widget<Text>(find.byKey(const Key('rta'))).data, '750.00');
    expect(find.text('250.00'), findsWidgets); // available in the Food row

    // Same numbers as the Rust core gives directly.
    final b = Core.instance.budget([
      for (final e in db.entities.values) e.json,
    ], month);
    expect(b['ready_to_assign'], 750000);
  });
}
