// Ledger rules shared by the UI: transfer pairs, splits, deleting categories.
// Port of `clients/web/src/ledger.ts`. Spec: docs/ledger-edits-spec.md. Budget
// math itself stays in the Rust core.
import 'db.dart';

/// Split lines of a transaction. Empty for an unsplit one.
List<Json> splitsOf(Entity t) => [
  for (final l in (t.data['splits'] as List?) ?? const []) l as Json,
];

/// The other leg of a transfer, if it still exists.
Entity? partnerOf(Db db, Entity t) {
  final id = t.data['transfer_transaction_id'] as String?;
  final p = id == null ? null : db.get('transaction', id);
  return p != null && !p.deleted ? p : null;
}

bool isTransfer(Entity t) => t.data['transfer_account_id'] != null;

/// A transfer leg whose partner is gone, for example after a concurrent delete.
bool isUnmatched(Db db, Entity t) => isTransfer(t) && partnerOf(db, t) == null;

bool _onBudget(Db db, String id) =>
    db.get('account', id)?.data['on_budget'] != false;

/// D5: money leaving the budget for a tracking account must come from a category.
bool transferNeedsCategory(Db db, String from, String to) =>
    _onBudget(db, from) && !_onBudget(db, to);

/// Add a transfer: an outflow leg in [from] and an inflow leg in [to]. [amount]
/// is positive milliunits.
Future<void> addTransfer(
  Db db, {
  required String date,
  required String from,
  required String to,
  required int amount,
  String? memo,
  bool cleared = false,
  String? categoryId,
}) async {
  final a = newId(), b = newId();
  final common = {
    'date': date,
    'memo': memo,
    'cleared': cleared,
    'category_id': categoryId,
  };
  await db.edit('transaction', a, {
    ...common,
    'account_id': from,
    'amount': -amount,
    'transfer_account_id': to,
    'transfer_transaction_id': b,
  });
  await db.edit('transaction', b, {
    ...common,
    'account_id': to,
    'amount': amount,
    'transfer_account_id': from,
    'transfer_transaction_id': a,
  });
}

/// D8: every edit to one leg is written to both legs, amount sign flipped.
Future<void> editTransfer(
  Db db,
  Entity t, {
  required String date,
  required int amount,
  String? memo,
  required bool cleared,
  String? categoryId,
}) async {
  final sign = (t.data['amount'] as int) < 0 ? -1 : 1;
  final common = {
    'date': date,
    'memo': memo,
    'cleared': cleared,
    'category_id': categoryId,
  };
  final p = partnerOf(db, t);
  await db.edit('transaction', t.id, {...common, 'amount': sign * amount});
  if (p != null) {
    await db.edit('transaction', p.id, {...common, 'amount': -sign * amount});
  }
}

/// Delete a transaction. A transfer takes its other leg with it.
Future<void> removeTransaction(Db db, Entity t) async {
  final p = partnerOf(db, t);
  await db.remove('transaction', t.id);
  if (p != null) await db.remove('transaction', p.id);
}

/// Live transactions that use a category, directly or in a split line.
List<Entity> txsInCategory(Db db, String categoryId) => [
  for (final t in db.list('transaction'))
    if (t.data['category_id'] == categoryId ||
        splitsOf(t).any((l) => l['category_id'] == categoryId))
      t,
];

List<Entity> categoriesInGroup(Db db, String groupId) => [
  for (final c in db.list('category'))
    if (c.data['group_id'] == groupId) c,
];

/// Remove a category. Its budget entries go with it, so the money returns to
/// Ready to Assign.
Future<void> deleteEmptyCategory(Db db, String categoryId) async {
  for (final e in db.list('budget_entry')) {
    if (e.data['category_id'] == categoryId) {
      await db.remove('budget_entry', e.id);
    }
  }
  await db.remove('category', categoryId);
}

/// D3, move: re-point every transaction at [target], then delete the category.
Future<void> moveCategoryTransactions(
  Db db,
  String categoryId,
  String target,
) async {
  for (final t in txsInCategory(db, categoryId)) {
    final lines = splitsOf(t);
    if (lines.isEmpty) {
      await db.edit('transaction', t.id, {'category_id': target});
    } else {
      await db.edit('transaction', t.id, {
        'splits': [
          for (final l in lines)
            l['category_id'] == categoryId ? {...l, 'category_id': target} : l,
        ],
      });
    }
  }
  await deleteEmptyCategory(db, categoryId);
}

/// D3, delete: remove the category's transactions, then the category.
Future<void> deleteCategoryTransactions(Db db, String categoryId) async {
  for (final t in txsInCategory(db, categoryId)) {
    final lines = splitsOf(t);
    if (lines.isEmpty) {
      await removeTransaction(db, t);
      continue;
    }
    // Only the lines in this category go. The rest of the split stays.
    final keep = [
      for (final l in lines)
        if (l['category_id'] != categoryId) l,
    ];
    if (keep.isEmpty) {
      await db.remove('transaction', t.id);
      continue;
    }
    final amount = keep.fold<int>(0, (s, l) => s + (l['amount'] as int));
    await db.edit('transaction', t.id, {'splits': keep, 'amount': amount});
  }
  await deleteEmptyCategory(db, categoryId);
}
