// Ledger rules (docs/ledger-edits-spec.md) against the real Rust core via dart:ffi.
// Needs ZERO_SUM_FFI, see tool/test.sh.
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:zero_sum/core.dart';
import 'package:zero_sum/db.dart';
import 'package:zero_sum/ledger.dart';

const month = '2026-10';

Future<Db> open() async {
  final sql = await databaseFactoryFfi.openDatabase(
    inMemoryDatabasePath,
    options: OpenDatabaseOptions(
      version: 1,
      onCreate: Db.create,
      singleInstance: false,
    ),
  );
  return Db.open(sql);
}

Map<String, dynamic> budget(Db db) =>
    Core.instance.budget([for (final e in db.entities.values) e.json], month);

int rta(Db db) => budget(db)['ready_to_assign'] as int;

int activity(Db db, String cat) =>
    (budget(db)['categories'] as List).firstWhere(
          (c) => c['category_id'] == cat,
        )['activity']
        as int;

void main() {
  sqfliteFfiInit();

  late Db db;
  late String checking, savings, broker, group, rent, fun;

  setUp(() async {
    db = await open();
    checking = newId();
    savings = newId();
    broker = newId();
    group = newId();
    rent = newId();
    fun = newId();
    await db.edit('account', checking, {'name': 'Checking', 'kind': 'checking'});
    await db.edit('account', savings, {'name': 'Savings', 'kind': 'savings'});
    await db.edit('account', broker, {
      'name': 'Brokerage',
      'kind': 'other',
      'on_budget': false,
    });
    await db.edit('category_group', group, {'name': 'Bills'});
    await db.edit('category', rent, {'group_id': group, 'name': 'Rent'});
    await db.edit('category', fun, {'group_id': group, 'name': 'Fun'});
    await db.edit('transaction', newId(), {
      'account_id': checking,
      'date': '$month-01',
      'amount': 1500000,
    });
  });

  test('transfer between on-budget accounts is a linked pair that budget ignores', () async {
    await addTransfer(
      db,
      date: '$month-02',
      from: checking,
      to: savings,
      amount: 100000,
    );
    final legs = db.list('transaction').where(isTransfer).toList();
    expect(legs, hasLength(2));
    final out = legs.firstWhere((t) => (t.data['amount'] as int) < 0);
    final inn = partnerOf(db, out)!;
    expect(inn.data['amount'], 100000);
    expect(inn.data['account_id'], savings);
    expect(partnerOf(db, inn)!.id, out.id);
    expect(rta(db), 1500000);
  });

  test('editing one leg mirrors to the other with the sign flipped', () async {
    await addTransfer(
      db,
      date: '$month-02',
      from: checking,
      to: savings,
      amount: 100000,
    );
    final inn = db
        .list('transaction')
        .firstWhere((t) => isTransfer(t) && (t.data['amount'] as int) > 0);
    await editTransfer(
      db,
      inn,
      date: '$month-03',
      amount: 150000,
      memo: 'rainy day',
      cleared: true,
    );
    final out = partnerOf(db, db.get('transaction', inn.id)!)!;
    expect(out.data['amount'], -150000);
    expect(out.data['date'], '$month-03');
    expect(out.data['memo'], 'rainy day');
    expect(out.data['cleared'], true);
    expect(db.get('transaction', inn.id)!.data['amount'], 150000);
  });

  test('deleting one leg deletes both', () async {
    await addTransfer(
      db,
      date: '$month-02',
      from: checking,
      to: savings,
      amount: 100000,
    );
    await removeTransaction(db, db.list('transaction').firstWhere(isTransfer));
    expect(db.list('transaction').where(isTransfer), isEmpty);
  });

  test('a lone leg is unmatched', () async {
    await addTransfer(
      db,
      date: '$month-02',
      from: checking,
      to: savings,
      amount: 100000,
    );
    final out = db
        .list('transaction')
        .firstWhere((t) => isTransfer(t) && (t.data['amount'] as int) < 0);
    final inn = partnerOf(db, out)!;
    await db.remove('transaction', inn.id);
    expect(isUnmatched(db, db.get('transaction', out.id)!), isTrue);
  });

  test('transfer to a tracking account needs a category and counts as spending', () async {
    expect(transferNeedsCategory(db, checking, broker), isTrue);
    expect(transferNeedsCategory(db, broker, checking), isFalse);
    expect(transferNeedsCategory(db, checking, savings), isFalse);
    await addTransfer(
      db,
      date: '$month-02',
      from: checking,
      to: broker,
      amount: 100000,
      categoryId: rent,
    );
    expect(activity(db, rent), -100000);
    expect(rta(db), 1500000);
    // Coming back from a tracking account is income.
    await addTransfer(
      db,
      date: '$month-03',
      from: broker,
      to: checking,
      amount: 100000,
    );
    expect(rta(db), 1600000);
  });

  test('split lines hit their categories and must sum to the amount', () async {
    await db.edit('transaction', newId(), {
      'account_id': checking,
      'date': '$month-05',
      'amount': -90000,
      'splits': [
        {'category_id': rent, 'amount': -60000},
        {'category_id': fun, 'amount': -30000},
      ],
    });
    expect(activity(db, rent), -60000);
    expect(activity(db, fun), -30000);
    expect(
      () => db.edit('transaction', newId(), {
        'account_id': checking,
        'date': '$month-05',
        'amount': -90000,
        'splits': [
          {'category_id': rent, 'amount': -60000},
        ],
      }),
      throwsA(isA<CoreException>()),
    );
  });

  test('delete category: move transactions, money returns to Ready to Assign', () async {
    await db.edit('transaction', newId(), {
      'account_id': checking,
      'date': '$month-05',
      'amount': -50000,
      'category_id': fun,
    });
    await db.edit('transaction', newId(), {
      'account_id': checking,
      'date': '$month-06',
      'amount': -40000,
      'splits': [
        {'category_id': fun, 'amount': -10000},
        {'category_id': rent, 'amount': -30000},
      ],
    });
    await db.edit('budget_entry', Core.instance.budgetEntryId(fun, month), {
      'category_id': fun,
      'month': month,
      'assigned': 200000,
    });
    expect(rta(db), 1300000);
    expect(txsInCategory(db, fun), hasLength(2));

    await moveCategoryTransactions(db, fun, rent);
    expect(db.get('category', fun)!.deleted, isTrue);
    expect(activity(db, rent), -90000);
    expect(rta(db), 1500000); // the 200 assigned to Fun is free again
  });

  test('delete category: deleting transactions keeps the rest of a split', () async {
    await db.edit('transaction', newId(), {
      'account_id': checking,
      'date': '$month-05',
      'amount': -50000,
      'category_id': fun,
    });
    final split = newId();
    await db.edit('transaction', split, {
      'account_id': checking,
      'date': '$month-06',
      'amount': -40000,
      'splits': [
        {'category_id': fun, 'amount': -10000},
        {'category_id': rent, 'amount': -30000},
      ],
    });
    await deleteCategoryTransactions(db, fun);
    expect(db.get('category', fun)!.deleted, isTrue);
    expect(db.list('transaction'), hasLength(2));
    expect(db.get('transaction', split)!.data['amount'], -30000);
    expect(activity(db, rent), -30000);
  });

  test('group delete leaves orphans that the core reports', () async {
    expect(categoriesInGroup(db, group), hasLength(2));
    await db.remove('category_group', group); // another device can still do this
    expect(
      (budget(db)['orphaned_category_ids'] as List).toSet(),
      {rent, fun},
    );
    final other = newId();
    await db.edit('category_group', other, {'name': 'New'});
    await db.edit('category', rent, {'group_id': other});
    expect(budget(db)['orphaned_category_ids'], [fun]);
  });
}
