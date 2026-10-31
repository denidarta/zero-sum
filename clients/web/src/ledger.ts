// Ledger rules shared by the UI: transfer pairs, splits, deleting categories.
// Spec: docs/ledger-edits-spec.md. Budget math itself stays in the Rust core.
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

const onBudget = (db: Db, id: string) => !!db.get("account", id)?.data.on_budget;

/** D5: money leaving the budget for a tracking account must come from a category. */
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

export function addTransfer(db: Db, i: TransferInput) {
  const a = uuid();
  const b = uuid();
  const common = { date: i.date, memo: i.memo, cleared: i.cleared, category_id: i.categoryId };
  db.edit("transaction", a, {
    ...common,
    account_id: i.from,
    amount: -i.amount,
    transfer_account_id: i.to,
    transfer_transaction_id: b,
  });
  db.edit("transaction", b, {
    ...common,
    account_id: i.to,
    amount: i.amount,
    transfer_account_id: i.from,
    transfer_transaction_id: a,
  });
}

/** D8: every edit to one leg is written to both legs, amount sign flipped. */
export function editTransfer(
  db: Db,
  t: Entity,
  i: { date: string; amount: number; memo: string | null; cleared: boolean; categoryId: string | null },
) {
  const sign = (t.data.amount as number) < 0 ? -1 : 1;
  const common = { date: i.date, memo: i.memo, cleared: i.cleared, category_id: i.categoryId };
  db.edit("transaction", t.id, { ...common, amount: sign * i.amount });
  const p = partnerOf(db, t);
  if (p) db.edit("transaction", p.id, { ...common, amount: -sign * i.amount });
}

/** Delete a transaction. A transfer takes its other leg with it. */
export function removeTransaction(db: Db, t: Entity) {
  const p = partnerOf(db, t);
  db.remove("transaction", t.id);
  if (p) db.remove("transaction", p.id);
}

/** Live transactions that use a category, directly or in a split line. */
export const txsInCategory = (db: Db, categoryId: string) =>
  db
    .list("transaction")
    .filter(
      (t) => t.data.category_id === categoryId || splitsOf(t).some((l) => l.category_id === categoryId),
    );

export const categoriesInGroup = (db: Db, groupId: string) =>
  db.list("category").filter((c) => c.data.group_id === groupId);

/** Remove a category. Its budget entries go with it, so the money returns to Ready to Assign. */
function dropCategory(db: Db, categoryId: string) {
  for (const e of db.list("budget_entry")) {
    if (e.data.category_id === categoryId) db.remove("budget_entry", e.id);
  }
  db.remove("category", categoryId);
}

/** D3, move: re-point every transaction at `target`, then delete the category. */
export function moveCategoryTransactions(db: Db, categoryId: string, target: string) {
  for (const t of txsInCategory(db, categoryId)) {
    if (splitsOf(t).length) {
      const splits = splitsOf(t).map((l) => (l.category_id === categoryId ? { ...l, category_id: target } : l));
      db.edit("transaction", t.id, { splits });
    } else {
      db.edit("transaction", t.id, { category_id: target });
    }
  }
  dropCategory(db, categoryId);
}

/** D3, delete: remove the category's transactions, then the category. */
export function deleteCategoryTransactions(db: Db, categoryId: string) {
  for (const t of txsInCategory(db, categoryId)) {
    const lines = splitsOf(t);
    if (!lines.length) {
      removeTransaction(db, t);
      continue;
    }
    // Only the lines in this category go. The rest of the split stays.
    const keep = lines.filter((l) => l.category_id !== categoryId);
    if (!keep.length) {
      db.remove("transaction", t.id);
      continue;
    }
    const amount = keep.reduce((s, l) => s + l.amount, 0);
    db.edit("transaction", t.id, { splits: keep, amount });
  }
  dropCategory(db, categoryId);
}

export const deleteEmptyCategory = dropCategory;
