// Ledger helpers for the UI. The rules (transfer pairs, splits, deleting
// categories) live in the Rust core: `_run` asks it for patches and writes them.
// Spec: docs/ledger-edits-spec.md.
import 'core.dart';
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

/// Same test as the core: the account exists and `on_budget` is not explicitly false.
/// Only decides whether the form shows a category picker; the core enforces D5.
bool _onBudget(Db db, String id) {
  final a = db.get('account', id);
  return a != null && a.data['on_budget'] != false;
}

/// D5: money leaving the budget for a tracking account must come from a category.
bool transferNeedsCategory(Db db, String from, String to) =>
    _onBudget(db, from) && !_onBudget(db, to);

/// Plan an action in the core, then write each patch. Throws a [CoreException]
/// with the core's message when the action is not allowed.
Future<void> _run(Db db, Map<String, dynamic> command) async {
  final patches = Core.instance.plan([
    for (final e in db.entities.values) e.json,
  ], command);
  for (final p in patches) {
    final kind = p['kind'] as String, id = p['id'] as String;
    if (p['deleted'] as bool) {
      await db.remove(kind, id);
    } else {
      await db.edit(kind, id, p['fields'] as Json);
    }
  }
}

/// Add a transfer: an outflow leg in [from] and an inflow leg in [to]. [amount]
/// is positive milliunits.
Future<void> addTransfer(
  Db db, {
  required String date,
  required String? from,
  required String? to,
  required int amount,
  String? memo,
  bool cleared = false,
  String? categoryId,
}) => _run(db, {
  'command': 'add_transfer',
  'ids': [newId(), newId()],
  'date': date,
  'from': from ?? '',
  'to': to ?? '',
  'amount': amount,
  'memo': memo,
  'cleared': cleared,
  'category_id': categoryId,
});

/// D8: every edit to one leg is written to both legs, amount sign flipped.
Future<void> editTransfer(
  Db db,
  Entity t, {
  required String date,
  required int amount,
  String? memo,
  required bool cleared,
  String? categoryId,
}) => _run(db, {
  'command': 'edit_transfer',
  'id': t.id,
  'date': date,
  'amount': amount,
  'memo': memo,
  'cleared': cleared,
  'category_id': categoryId,
});

/// Delete a transaction. A transfer takes its other leg with it.
Future<void> removeTransaction(Db db, Entity t) =>
    _run(db, {'command': 'remove_transaction', 'id': t.id});

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
Future<void> deleteEmptyCategory(Db db, String categoryId) =>
    _run(db, {'command': 'delete_empty_category', 'category_id': categoryId});

/// D3, move: re-point every transaction at [target], then delete the category.
Future<void> moveCategoryTransactions(
  Db db,
  String categoryId,
  String target,
) => _run(db, {
  'command': 'move_category_transactions',
  'category_id': categoryId,
  'target': target,
});

/// D3, delete: remove the category's transactions, then the category.
Future<void> deleteCategoryTransactions(Db db, String categoryId) => _run(db, {
  'command': 'delete_category_transactions',
  'category_id': categoryId,
});
