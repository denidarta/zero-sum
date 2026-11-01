import { useEffect, useMemo, useState } from "preact/hooks";
import { budgetEntryId, computeBudget } from "./core";
import type { Db } from "./db";
import { uuid } from "./db";
import {
  byName,
  byNewest,
  categoriesInGroup,
  deleteCategoryTransactions,
  deleteEmptyCategory,
  isTracking,
  isTransfer,
  isUnmatched,
  moveCategoryTransactions,
  removeTransaction,
  splitsOf,
  txsInCategory,
} from "./ledger";
import { fmt, parse, shiftMonth, thisMonth } from "./money";
import type { BudgetMonth, Entity } from "./types";
import { TxForm } from "./txform";

function useDb(db: Db) {
  const [, setN] = useState(0);
  useEffect(() => db.subscribe(() => setN((n) => n + 1)), [db]);
}

type View = { kind: "budget" } | { kind: "transactions"; account?: string };

export function App({ db }: { db: Db }) {
  useDb(db);
  const [view, setView] = useState<View>({ kind: "budget" });
  const [month, setMonth] = useState(thisMonth());

  const accounts = db.list("account").sort(byName);
  const balances = new Map<string, number>();
  for (const t of db.list("transaction")) {
    balances.set(t.data.account_id, (balances.get(t.data.account_id) ?? 0) + t.data.amount);
  }

  const budget = useMemo(
    () => computeBudget([...db.entities.values()], month),
    [db.version, month],
  );

  return (
    <div class="layout">
      <aside>
        <h1>zero-sum</h1>
        <nav>
          <button class={view.kind === "budget" ? "on" : ""} onClick={() => setView({ kind: "budget" })}>
            Budget
          </button>
          <button
            class={view.kind === "transactions" && !view.account ? "on" : ""}
            onClick={() => setView({ kind: "transactions" })}
          >
            All transactions
          </button>
        </nav>
        <h2>Accounts</h2>
        <ul class="accounts">
          {accounts.map((a) => (
            <li>
              <button
                class={view.kind === "transactions" && view.account === a.id ? "on" : ""}
                onClick={() => setView({ kind: "transactions", account: a.id })}
              >
                <span>
                  {a.data.name}
                  {isTracking(a) && <small> (tracking)</small>}
                </span>
                <span class="num">{fmt(balances.get(a.id) ?? 0)}</span>
              </button>
            </li>
          ))}
        </ul>
        <AddAccount db={db} />
        <SyncStatus db={db} />
      </aside>
      <main>
        {view.kind === "budget" ? (
          <BudgetView db={db} month={month} setMonth={setMonth} budget={budget} />
        ) : (
          <Transactions db={db} account={view.account} />
        )}
      </main>
    </div>
  );
}

function SyncStatus({ db }: { db: Db }) {
  const label = { idle: "Synced", syncing: "Syncing…", offline: "Offline" }[db.state];
  return (
    <div class={`sync ${db.state}`}>
      <div>
        {label}
        {db.outbox.length > 0 && ` · ${db.outbox.length} pending`}
      </div>
      <details>
        <summary>Server</summary>
        <input
          placeholder="same origin"
          value={db.serverUrl}
          onChange={(e) => db.setServer((e.target as HTMLInputElement).value.trim())}
        />
      </details>
    </div>
  );
}

function AddAccount({ db }: { db: Db }) {
  const [name, setName] = useState("");
  const [onBudget, setOnBudget] = useState(true);
  const add = (e: Event) => {
    e.preventDefault();
    if (!name.trim()) return;
    db.edit("account", uuid(), {
      name: name.trim(),
      kind: onBudget ? "checking" : "other",
      on_budget: onBudget,
    });
    setName("");
  };
  return (
    <form class="stack" onSubmit={add}>
      <input placeholder="New account" value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} />
      <label>
        <input type="checkbox" checked={onBudget} onChange={(e) => setOnBudget((e.target as HTMLInputElement).checked)} />{" "}
        On budget
      </label>
      <button>Add account</button>
    </form>
  );
}

function BudgetView(p: {
  db: Db;
  month: string;
  setMonth: (m: string) => void;
  budget: BudgetMonth;
}) {
  const { db, month, budget } = p;
  const rows = new Map(budget.categories.map((c) => [c.category_id, c]));
  const groups = db.list("category_group").sort(byName);
  const categories = db.list("category").sort(byName);
  const orphaned = new Set(budget.orphaned_category_ids);
  const [newGroup, setNewGroup] = useState("");
  const [deleting, setDeleting] = useState<Entity | null>(null);

  // D1: a group with categories cannot be deleted, so no money is ever hidden.
  const deleteGroup = (g: Entity) => {
    if (categoriesInGroup(db, g.id).length) {
      return alert(`Move or delete the categories in ${g.data.name} first.`);
    }
    if (confirm(`Delete group ${g.data.name}?`)) db.remove("category_group", g.id);
  };

  const deleteCategory = (c: Entity) => {
    if (txsInCategory(db, c.id).length) return setDeleting(c);
    if (confirm(`Delete category ${c.data.name}? Money assigned to it returns to Ready to Assign.`)) {
      deleteEmptyCategory(db, c.id);
    }
  };

  const categoryRow = (c: Entity) => {
    const r = rows.get(c.id);
    return (
      <tr data-cat={c.data.name}>
        <td>
          {c.data.name}
          <button class="link" title="Delete category" aria-label={`Delete category ${c.data.name}`} onClick={() => deleteCategory(c)}>
            ×
          </button>
          {orphaned.has(c.id) && (
            <select
              class="move"
              aria-label={`Move ${c.data.name} to a group`}
              value=""
              onChange={(e) => db.edit("category", c.id, { group_id: (e.target as HTMLSelectElement).value })}
            >
              <option value="">Move to group…</option>
              {groups.map((g) => (
                <option value={g.id}>{g.data.name}</option>
              ))}
            </select>
          )}
        </td>
        <td class="num">
          <AssignInput
            key={`${c.id}:${month}:${r?.assigned ?? 0}`}
            value={r?.assigned ?? 0}
            onCommit={(v) =>
              db.edit("budget_entry", budgetEntryId(c.id, month), {
                category_id: c.id,
                month,
                assigned: v,
              })
            }
          />
        </td>
        <td class="num">{fmt(r?.activity ?? 0)}</td>
        <td class={`num avail ${(r?.available ?? 0) < 0 ? "neg" : ""}`}>{fmt(r?.available ?? 0)}</td>
      </tr>
    );
  };

  return (
    <>
      <header class="bar">
        <div class="months">
          <button onClick={() => p.setMonth(shiftMonth(month, -1))} aria-label="Previous month">‹</button>
          <strong data-testid="month">{month}</strong>
          <button onClick={() => p.setMonth(shiftMonth(month, 1))} aria-label="Next month">›</button>
        </div>
        <div class={`rta ${budget.ready_to_assign < 0 ? "neg" : ""}`}>
          <small>Ready to Assign</small>
          <strong data-testid="rta">{fmt(budget.ready_to_assign)}</strong>
        </div>
      </header>
      {deleting && <DeleteCategory db={db} category={deleting} onDone={() => setDeleting(null)} />}
      <table class="budget">
        <thead>
          <tr>
            <th>Category</th>
            <th class="num">Assigned</th>
            <th class="num">Activity</th>
            <th class="num">Available</th>
          </tr>
        </thead>
        {groups.map((g) => (
          <tbody>
            <tr class="group">
              <th colSpan={3}>{g.data.name}</th>
              <td class="num">
                <button class="link" title="Delete group" aria-label={`Delete group ${g.data.name}`} onClick={() => deleteGroup(g)}>
                  ×
                </button>
              </td>
            </tr>
            {categories.filter((c) => c.data.group_id === g.id).map(categoryRow)}
            <AddCategory db={db} groupId={g.id} />
          </tbody>
        ))}
        {(budget.card_payments ?? []).length > 0 && (
          <tbody data-testid="card-payments">
            <tr class="group">
              <th colSpan={4}>Credit Card Payments</th>
            </tr>
            {(budget.card_payments ?? []).map((r) => (
              <tr data-cat={`card:${db.get("account", r.account_id)?.data.name ?? r.account_id}`}>
                <td>{db.get("account", r.account_id)?.data.name ?? "Card"}</td>
                <td class="num">
                  <AssignInput
                    key={`${r.category_id}:${month}:${r.assigned}`}
                    value={r.assigned}
                    onCommit={(v) =>
                      db.edit("budget_entry", budgetEntryId(r.category_id, month), {
                        category_id: r.category_id,
                        month,
                        assigned: v,
                      })
                    }
                  />
                </td>
                <td class="num">{fmt(r.activity)}</td>
                <td class={`num avail ${r.available < 0 ? "neg" : ""}`}>{fmt(r.available)}</td>
              </tr>
            ))}
          </tbody>
        )}
        {orphaned.size > 0 && (
          <tbody data-testid="orphaned">
            <tr class="group">
              <th colSpan={4}>Orphaned (group was deleted)</th>
            </tr>
            {categories.filter((c) => orphaned.has(c.id)).map(categoryRow)}
          </tbody>
        )}
      </table>
      <form
        class="inline"
        onSubmit={(e) => {
          e.preventDefault();
          if (!newGroup.trim()) return;
          db.edit("category_group", uuid(), { name: newGroup.trim(), sort: groups.length });
          setNewGroup("");
        }}
      >
        <input placeholder="New category group" value={newGroup} onInput={(e) => setNewGroup((e.target as HTMLInputElement).value)} />
        <button>Add group</button>
      </form>
    </>
  );
}

/** D3: a category with transactions is deleted only after they are deleted or moved. */
function DeleteCategory({ db, category, onDone }: { db: Db; category: Entity; onDone: () => void }) {
  const n = txsInCategory(db, category.id).length;
  const others = db.list("category").filter((c) => c.id !== category.id).sort(byName);
  const [target, setTarget] = useState("");
  return (
    <div class="modal" role="dialog" aria-label={`Delete category ${category.data.name}`}>
      <p>
        <strong>{category.data.name}</strong> has {n} transaction{n === 1 ? "" : "s"}. Move them to another category or
        delete them. Money assigned to it returns to Ready to Assign.
      </p>
      <div class="inline">
        <select value={target} onChange={(e) => setTarget((e.target as HTMLSelectElement).value)}>
          <option value="">Move transactions to…</option>
          {others.map((c) => (
            <option value={c.id}>{c.data.name}</option>
          ))}
        </select>
        <button
          disabled={!target}
          onClick={() => {
            moveCategoryTransactions(db, category.id, target);
            onDone();
          }}
        >
          Move and delete category
        </button>
      </div>
      <div class="inline">
        <button
          onClick={() => {
            if (!confirm(`Delete ${n} transaction${n === 1 ? "" : "s"} and the category? This cannot be undone.`)) return;
            deleteCategoryTransactions(db, category.id);
            onDone();
          }}
        >
          Delete transactions and category
        </button>
        <button onClick={onDone}>Cancel</button>
      </div>
    </div>
  );
}

function AssignInput({ value, onCommit }: { value: number; onCommit: (v: number) => void }) {
  const [text, setText] = useState(fmt(value));
  const commit = () => {
    const v = parse(text);
    if (v === null) return setText(fmt(value));
    if (v !== value) onCommit(v);
  };
  return (
    <input
      class="num"
      inputMode="decimal"
      value={text}
      onInput={(e) => setText((e.target as HTMLInputElement).value)}
      onBlur={commit}
      onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
      onFocus={(e) => (e.target as HTMLInputElement).select()}
    />
  );
}

function AddCategory({ db, groupId }: { db: Db; groupId: string }) {
  const [name, setName] = useState("");
  return (
    <tr class="add">
      <td colSpan={4}>
        <form
          class="inline"
          onSubmit={(e) => {
            e.preventDefault();
            if (!name.trim()) return;
            db.edit("category", uuid(), { group_id: groupId, name: name.trim() });
            setName("");
          }}
        >
          <input placeholder="Add category" value={name} onInput={(e) => setName((e.target as HTMLInputElement).value)} />
        </form>
      </td>
    </tr>
  );
}

function Transactions({ db, account }: { db: Db; account?: string }) {
  const accounts = db.list("account").sort(byName);
  const categories = db.list("category").sort(byName);
  const payees = db.list("payee");
  const [editing, setEditing] = useState<string | null>(null);
  const nameOf = (list: Entity[], id?: string | null) =>
    list.find((e) => e.id === id)?.data.name ?? "";

  const txs = db
    .list("transaction")
    .filter((t) => !account || t.data.account_id === account)
    .sort(byNewest);

  if (!accounts.length) return <p class="empty">Add an account to start.</p>;

  const payeeCell = (t: Entity) => {
    if (!isTransfer(t)) return nameOf(payees, t.data.payee_id);
    const other = nameOf(accounts, t.data.transfer_account_id);
    return (
      <>
        {t.data.amount < 0 ? `Transfer to ${other}` : `Transfer from ${other}`}
        {isUnmatched(db, t) && <em class="neg" title="The other leg is missing"> (unmatched)</em>}
      </>
    );
  };

  const categoryCell = (t: Entity) => {
    const lines = splitsOf(t);
    if (lines.length) {
      const title = lines.map((l) => `${nameOf(categories, l.category_id) || "(deleted)"} ${fmt(l.amount)}`).join("\n");
      return <span title={title}>Split ({lines.length})</span>;
    }
    if (isTransfer(t)) return nameOf(categories, t.data.category_id);
    return nameOf(categories, t.data.category_id) || <em>Income</em>;
  };

  return (
    <>
      <h2>{account ? nameOf(accounts, account) : "All transactions"}</h2>
      <TxForm db={db} account={account} />
      <table class="tx">
        <tbody>
          {txs.map((t) =>
            editing === t.id ? (
              <tr data-tx={t.id}>
                <td colSpan={8}>
                  <TxForm db={db} account={account} editing={t} onDone={() => setEditing(null)} />
                </td>
              </tr>
            ) : (
              <tr data-tx={t.id}>
                <td>{t.data.date}</td>
                {!account && <td>{nameOf(accounts, t.data.account_id)}</td>}
                <td>{payeeCell(t)}</td>
                <td>{categoryCell(t)}</td>
                <td class="memo">{t.data.memo}</td>
                <td class={`num ${t.data.amount < 0 ? "neg" : "pos"}`}>{fmt(t.data.amount)}</td>
                <td title="Cleared">{t.data.cleared ? "✓" : ""}</td>
                <td>
                  <button class="link" title="Edit" aria-label="Edit transaction" onClick={() => setEditing(t.id)}>
                    ✎
                  </button>
                  <button
                    class="link"
                    title="Delete"
                    aria-label="Delete transaction"
                    onClick={() =>
                      (!isTransfer(t) || confirm("Delete both legs of this transfer?")) && removeTransaction(db, t)
                    }
                  >
                    ×
                  </button>
                </td>
              </tr>
            ),
          )}
        </tbody>
      </table>
    </>
  );
}
