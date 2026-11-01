// The ledger glue (patches from the Rust core written to the Db) via dart:ffi.
// The rules themselves are tested in crates/core/src/ledger.rs.
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
    await db.edit('account', checking, {
      'name': 'Checking',
      'kind': 'checking',
    });
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

  test('transfer: add, edit one leg, lone leg, delete', () async {
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
    expect(rta(db), 1500000);

    await editTransfer(
      db,
      inn,
      date: '$month-03',
      amount: 150000,
      memo: 'rainy day',
      cleared: true,
    );
    final mirrored = db.get('transaction', out.id)!;
    expect(mirrored.data['amount'], -150000);
    expect(mirrored.data['memo'], 'rainy day');

    await db.remove('transaction', inn.id);
    expect(isUnmatched(db, db.get('transaction', out.id)!), isTrue);

    await addTransfer(
      db,
      date: '$month-02',
      from: savings,
      to: checking,
      amount: 5,
    );
    final pair = db.list('transaction').where(isTransfer).toList();
    await removeTransaction(db, pair.last);
    expect(db.list('transaction').where(isTransfer), hasLength(1));
  });

  test(
    'the core refuses a bad transfer and the message reaches the caller',
    () async {
      Future<void> add(String? from, String? to, int amount, [String? cat]) =>
          addTransfer(
            db,
            date: '$month-02',
            from: from,
            to: to,
            amount: amount,
            categoryId: cat,
          );
      expect(
        add(checking, checking, 5),
        throwsA(
          isA<CoreException>().having(
            (e) => e.message,
            'message',
            'Pick two different accounts.',
          ),
        ),
      );
      expect(add(checking, savings, 0), throwsA(isA<CoreException>()));
      expect(
        add(checking, broker, 5),
        throwsA(
          isA<CoreException>().having(
            (e) => e.message,
            'message',
            'Pick the category this money comes from.',
          ),
        ),
      );
      await add(checking, broker, 100000, rent);
      expect(activity(db, rent), -100000);
    },
  );

  test(
    'delete category: move transactions, money returns to Ready to Assign',
    () async {
      await db.edit('budget_entry', Core.instance.budgetEntryId(fun, month), {
        'category_id': fun,
        'month': month,
        'assigned': 400000,
      });
      await db.edit('transaction', newId(), {
        'account_id': checking,
        'date': '$month-05',
        'amount': -100000,
        'category_id': fun,
      });
      expect(rta(db), 1100000);
      await moveCategoryTransactions(db, fun, rent);
      expect(db.get('category', fun)!.deleted, isTrue);
      expect(activity(db, rent), -100000);
      expect(rta(db), 1500000);
    },
  );
}
