// Ledger helpers for the UI. The rules (transfer pairs, splits, deleting categories) live in
// the Rust core: `planLedger` turns an action into patches and `run` writes them.
// Spec: docs/ledger-edits-spec.md.
import { planLedger } from "./core";
import type { Db } from "./db";
import { uuid } from "./db";
import type { Entity, Split } from "./types";

export const splitsOf = (t: Entity): Split[] => (t.data.splits as Split[] | undefined) ?? [];

/** The other leg of a transfer, if it still exists. */
export function partnerOf(db: Db, t: Entity): Entity | undefined {
  const id = t.data.transfer_transaction_id as string | undefined;
  const p = id ? db.get("transaction", id) : undefined;
  return p && !p.deleted ? p : undefined;
}

export const isTransfer = (t: Entity) => !!t.data.transfer_account_id;

/** A transfer leg whose partner is gone, for example after a concurrent delete. */
export const isUnmatched = (db: Db, t: Entity) => isTransfer(t) && !partnerOf(db, t);

/** Same test as the core: the account exists and `on_budget` is not explicitly false. */
export const isTracking = (a: Entity) => a.data.on_budget === false;
const onBudget = (db: Db, id: string) => {
  const a = db.get("account", id);
  return !!a && !isTracking(a);
};

/** Order by `sort`, then name (case-insensitive). Used for accounts, groups and categories. */
export const byName = (a: Entity, b: Entity) =>
  (a.data.sort ?? 0) - (b.data.sort ?? 0) ||
  String(a.data.name).localeCompare(String(b.data.name), undefined, { sensitivity: "base" });

/** Newest first: date, then when the date was last edited, then id. */
export const byNewest = (a: Entity, b: Entity) =>
  b.data.date.localeCompare(a.data.date) ||
  (b.stamps.date?.ts ?? 0) - (a.stamps.date?.ts ?? 0) ||
  (a.id < b.id ? -1 : 1);

/** Whether the form shows a category picker. The core enforces D5 when the transfer is saved. */
export const transferNeedsCategory = (db: Db, from: string, to: string) =>
  onBudget(db, from) && !onBudget(db, to);

export interface TransferInput {
  date: string;
  from: string;
  to: string;
  /** Positive milliunits. */
  amount: number;
  memo: string | null;
  cleared: boolean;
  categoryId: string | null;
}

const plan = (db: Db, command: Record<string, unknown>) =>
  planLedger([...db.entities.values()], command);

/** Plan an action in the core, then write each patch. Throws the core's message when not allowed. */
function run(db: Db, command: Record<string, unknown>) {
  for (const p of plan(db, command)) {
    if (p.deleted) db.remove(p.kind, p.id);
    else db.edit(p.kind, p.id, p.fields);
  }
}

export const addTransfer = (db: Db, i: TransferInput) =>
  run(db, {
    command: "add_transfer",
    ids: [uuid(), uuid()],
    date: i.date,
    from: i.from,
    to: i.to,
    amount: i.amount,
    memo: i.memo,
    cleared: i.cleared,
    category_id: i.categoryId,
  });

/** D8: every edit to one leg is written to both legs, amount sign flipped. */
export const editTransfer = (
  db: Db,
  t: Entity,
  i: { date: string; amount: number; memo: string | null; cleared: boolean; categoryId: string | null },
) =>
  run(db, {
    command: "edit_transfer",
    id: t.id,
    date: i.date,
    amount: i.amount,
    memo: i.memo,
    cleared: i.cleared,
    category_id: i.categoryId,
  });

/** Delete a transaction. A transfer takes its other leg with it. */
export const removeTransaction = (db: Db, t: Entity) =>
  run(db, { command: "remove_transaction", id: t.id });

/** How many transactions deleting this category would remove, as the core counts them. */
export const categoryTxCount = (db: Db, categoryId: string) =>
  plan(db, { command: "delete_category_transactions", category_id: categoryId }).filter(
    (p) => p.kind === "transaction",
  ).length;

/** D1: the core refuses while the group has categories. Both throw its message. */
const groupDelete = (groupId: string) => ({ command: "delete_group", group_id: groupId });
export const checkDeleteGroup = (db: Db, groupId: string) => void plan(db, groupDelete(groupId));
export const deleteGroup = (db: Db, groupId: string) => run(db, groupDelete(groupId));

/** D3, move: re-point every transaction at `target`, then delete the category. */
export const moveCategoryTransactions = (db: Db, categoryId: string, target: string) =>
  run(db, { command: "move_category_transactions", category_id: categoryId, target });

/** D3, delete: remove the category's transactions, then the category. */
export const deleteCategoryTransactions = (db: Db, categoryId: string) =>
  run(db, { command: "delete_category_transactions", category_id: categoryId });

/** Remove a category. Its budget entries go with it, so the money returns to Ready to Assign. */
export const deleteEmptyCategory = (db: Db, categoryId: string) =>
  run(db, { command: "delete_empty_category", category_id: categoryId });
