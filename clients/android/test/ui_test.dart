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

  /// Open the app on a fresh db with Checking, group Needs, categories Food and Rent.
  Future<(Db, Map<String, String>)> seed(WidgetTester tester) async {
    late Db db;
    final ids = <String, String>{};
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
      for (final k in ['acct', 'group', 'food', 'rent']) {
        ids[k] = newId();
      }
      await db.edit('account', ids['acct']!, {
        'name': 'Checking',
        'kind': 'checking',
      });
      await db.edit('category_group', ids['group']!, {'name': 'Needs'});
      await db.edit('category', ids['food']!, {
        'group_id': ids['group'],
        'name': 'Food',
      });
      await db.edit('category', ids['rent']!, {
        'group_id': ids['group'],
        'name': 'Rent',
      });
      await db.edit('transaction', newId(), {
        'account_id': ids['acct'],
        'date': '$month-01',
        'amount': 1000000,
      });
      await db.edit('transaction', newId(), {
        'account_id': ids['acct'],
        'date': '$month-02',
        'amount': -50000,
        'category_id': ids['food'],
      });
    });
    await tester.pumpWidget(ZeroSumApp(db: db));
    await tester.pump();
    await tester.tap(find.text('Cancel')); // server URL prompt
    await tester.pumpAndSettle();
    return (db, ids);
  }

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a group with categories cannot be deleted', (tester) async {
    final (db, ids) = await seed(tester);
    await tester.tap(find.byTooltip('Delete group').first);
    await tester.pumpAndSettle();
    expect(find.text('Move or delete the categories in Needs first.'), findsOneWidget);
    expect(db.get('category_group', ids['group']!)!.deleted, isFalse);
  });

  testWidgets('categories of a deleted group show under Orphaned', (tester) async {
    final (db, ids) = await seed(tester);
    expect(find.byKey(const Key('orphaned')), findsNothing);
    await tester.runAsync(() => db.remove('category_group', ids['group']!));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('orphaned')), findsOneWidget);
    expect(find.text('Food'), findsOneWidget);

    // Move Food to a new group.
    await tester.runAsync(
      () => db.edit('category_group', newId(), {'name': 'Wants'}),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move to group…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Wants').last);
    await settle(tester);
    expect(db.get('category', ids['food']!)!.data['group_id'], isNot(ids['group']));
  });

  testWidgets('deleting a category with transactions can move them', (tester) async {
    final (db, ids) = await seed(tester);
    await tester.tap(find.byKey(const Key('menu-Food')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Delete category'));
    await tester.pumpAndSettle();
    expect(find.text('Delete category Food'), findsOneWidget);
    await tester.tap(find.byKey(const Key('move-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rent').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Move and delete'));
    await settle(tester);
    expect(db.get('category', ids['food']!)!.deleted, isTrue);
    final rent = db
        .list('transaction')
        .where((t) => t.data['category_id'] == ids['rent']);
    expect(rent, hasLength(1));
  });

  testWidgets('add a transfer between two accounts', (tester) async {
    final (db, _) = await seed(tester);
    await tester.runAsync(
      () => db.edit('account', newId(), {'name': 'Savings', 'kind': 'savings'}),
    );
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transaction').last); // FAB
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transfer'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('amount')), '100');
    await tester.tap(find.text('Add'));
    await settle(tester);
    final legs = db.list('transaction').where((t) => t.data['transfer_account_id'] != null);
    expect(legs, hasLength(2));
    expect(legs.map((t) => t.data['amount']).toSet(), {100000, -100000});
    expect(find.text('Transfer to Savings'), findsOneWidget);
  });

  testWidgets('split must add up, then saves', (tester) async {
    final (db, ids) = await seed(tester);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Transaction').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('amount')), '90');
    await tester.tap(find.byKey(const Key('split')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Category').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rent').last);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('line-amount-0')), '60');
    await tester.tap(find.text('Add'));
    await tester.pumpAndSettle();
    expect(
      find.text('Split lines add up to 60.00, but the amount is 90.00.'),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const Key('line-amount-0')), '90');
    await tester.tap(find.text('Add'));
    await settle(tester);
    final split = db.list('transaction').where((t) => t.data['splits'] != null);
    expect(split, hasLength(1));
    expect(split.first.data['amount'], -90000);
    expect((split.first.data['splits'] as List).first['category_id'], ids['rent']);
  });

  testWidgets('tapping a transaction edits it', (tester) async {
    final (db, ids) = await seed(tester);
    await tester.tap(find.text('Transactions'));
    await tester.pumpAndSettle();
    final food = db
        .list('transaction')
        .firstWhere((t) => t.data['category_id'] == ids['food']);
    await tester.tap(find.byKey(Key('row-${food.id}')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('amount')), '80');
    await tester.tap(find.text('Save'));
    await settle(tester);
    expect(db.get('transaction', food.id)!.data['amount'], -80000);
  });
}
