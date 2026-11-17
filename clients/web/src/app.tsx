import { useEffect, useMemo, useState } from "preact/hooks";
import { autoAssigns } from "./autoassign";
import { budgetEntryId, computeBudget } from "./core";
import type { Db } from "./db";
import { uuid } from "./db";
import { Icon, path } from "./icons";
import {
  byName,
  byNewest,
  categoryTxCount,
  checkDeleteGroup,
  deleteGroup,
  deleteCategoryTransactions,
  deleteEmptyCategory,
  isTracking,
  isTransfer,
  isUnmatched,
  moveCategoryTransactions,
  removeTransaction,
  splitsOf,
} from "./ledger";
import { fmt, fmtMoney, parse, plain, shiftMonth, thisMonth } from "./money";
import type { BudgetMonth, CategoryMonth, Entity } from "./types";
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

  const budget = useMemo(() => computeBudget([...db.entities.values()], month), [db.version, month]);

  const open = accounts.filter((a) => !a.data.closed);
  const credit = (a: Entity) => a.data.kind === "credit_card" || a.data.kind === "line_of_credit";
  const groups = [
    { label: "Cash", list: open.filter((a) => !isTracking(a) && !credit(a)) },
    { label: "Credit", list: open.filter((a) => !isTracking(a) && credit(a)) },
    { label: "Tracking", list: open.filter(isTracking) },
    { label: "Closed", list: accounts.filter((a) => a.data.closed) },
  ].filter((g) => g.list.length);

  const accountButton = (a: Entity) => {
    const bal = balances.get(a.id) ?? 0;
    return (
      <li>
        <button
          class={view.kind === "transactions" && view.account === a.id ? "on" : ""}
          onClick={() => setView({ kind: "transactions", account: a.id })}
        >
          <span>{a.data.name}</span>
          <span class={`num ${bal < 0 ? "debt" : ""}`}>{fmtMoney(bal)}</span>
        </button>
      </li>
    );
  };

  return (
    <div class="layout">
      <aside>
        <h1>zero-sum</h1>
        <nav>
          <button class={view.kind === "budget" ? "on" : ""} onClick={() => setView({ kind: "budget" })}>
            <Icon d={path.plan} />
            Plan
          </button>
          <button
            class={view.kind === "transactions" && !view.account ? "on" : ""}
            onClick={() => setView({ kind: "transactions" })}
          >
            <Icon d={path.accounts} />
            All transactions
          </button>
        </nav>
        {groups.map((g) => {
          const total = g.list.reduce((s, a) => s + (balances.get(a.id) ?? 0), 0);
          return (
            <details class="acc-group" open={g.label !== "Closed"}>
              <summary>
                <Icon d={path.down} size={18} />
                <span>{g.label}</span>
                <span class={`num ${total < 0 ? "debt" : ""}`}>{fmtMoney(total)}</span>
              </summary>
              <ul class="accounts">{g.list.map(accountButton)}</ul>
            </details>
          );
        })}
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
        <input
          type="checkbox"
          checked={onBudget}
          onChange={(e) => setOnBudget((e.target as HTMLInputElement).checked)}
        />{" "}
        On budget
      </label>
      <button>Add account</button>
    </form>
  );
}

type Filter = "all" | "over" | "avail";
const FILTERS: { id: Filter; label: string }[] = [
  { id: "all", label: "All" },
  { id: "over", label: "Overspent" },
  { id: "avail", label: "Money Available" },
];
const matches = (f: Filter, available: number) => f === "all" || (f === "over" ? available < 0 : available > 0);

const monthLabel = (m: string) => {
  const [y, mo] = m.split("-").map(Number) as [number, number];
  return new Date(y, mo - 1, 1).toLocaleDateString("en-US", { month: "short", year: "numeric" });
};

/** What a row says about its month, and how much of the money in it is spent. */
function progress(r: CategoryMonth | undefined) {
  if (!r) return { text: "", pct: 0, over: false };
  const funded = r.available - r.activity; // carried over plus assigned
  if (r.available < 0) return { text: `Overspent by ${fmtMoney(-r.available)}`, pct: 100, over: true };
  if (funded <= 0) return { text: "", pct: 0, over: false };
  const pct = Math.min(100, Math.round((-r.activity / funded) * 100));
  if (r.available === 0) return { text: "Fully spent", pct: 100, over: false };
  const text =
    r.activity < 0 ? `Funded. Spent ${fmtMoney(-r.activity)} of ${fmtMoney(funded)}` : `Funded ${fmtMoney(funded)}`;
  return { text, pct, over: false };
}

function Pill({ available }: { available: number }) {
  const [cls, d] =
    available < 0 ? ["over", path.warn] : available > 0 ? ["ok", path.check] : ["zero", path.checkOutline];
  return (
    <span class={`pill ${cls}`}>
      <Icon d={d} size={16} />
      {fmtMoney(available)}
    </span>
  );
}

function BudgetView(p: { db: Db; month: string; setMonth: (m: string) => void; budget: BudgetMonth }) {
  const { db, month, budget } = p;
  const rows = new Map(budget.categories.map((c) => [c.category_id, c]));
  const groups = db.list("category_group").sort(byName);
  const categories = db.list("category").sort(byName);
  const orphaned = new Set(budget.orphaned_category_ids);
  const [newGroup, setNewGroup] = useState("");
  const [deleting, setDeleting] = useState<Entity | null>(null);
  const [filter, setFilter] = useState<Filter>("all");
  const [collapsed, setCollapsed] = useState<Set<string>>(new Set());
  const filtered = filter !== "all";

  const toggle = (id: string) =>
    setCollapsed((s) => {
      const n = new Set(s);
      n.has(id) ? n.delete(id) : n.add(id);
      return n;
    });

  // D1: the core refuses to delete a group that still has categories.
  const removeGroup = (g: Entity) => {
    try {
      checkDeleteGroup(db, g.id);
    } catch (e) {
      return alert((e as Error).message);
    }
    if (confirm(`Delete group ${g.data.name}?`)) deleteGroup(db, g.id);
  };

  const deleteCategory = (c: Entity) => {
    if (categoryTxCount(db, c.id)) return setDeleting(c);
    if (confirm(`Delete category ${c.data.name}? Money assigned to it returns to Ready to Assign.`)) {
      deleteEmptyCategory(db, c.id);
    }
  };

  const assign = (categoryId: string) => (v: number) =>
    db.edit("budget_entry", budgetEntryId(categoryId, month), { category_id: categoryId, month, assigned: v });

  const categoryRow = (c: Entity) => {
    const r = rows.get(c.id);
    if (!matches(filter, r?.available ?? 0)) return null;
    const pr = progress(r);
    return (
      <tr class="cat" data-cat={c.data.name}>
        <td>
          <div class="cn">
            <div class="l1">
              <span>
                {c.data.name}
                <button
                  class="link"
                  title="Delete category"
                  aria-label={`Delete category ${c.data.name}`}
                  onClick={() => deleteCategory(c)}
                >
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
              </span>
              <span class="sub">{pr.text}</span>
            </div>
            {pr.pct > 0 && (
              <div class="meter" aria-hidden="true">
                <i class={pr.over ? "over" : ""} style={{ width: `${pr.pct}%` }} />
              </div>
            )}
          </div>
        </td>
        <td class="num">
          <AssignInput
            key={`${c.id}:${month}:${r?.assigned ?? 0}`}
            label={`Assigned to ${c.data.name}`}
            value={r?.assigned ?? 0}
            onCommit={assign(c.id)}
          />
        </td>
        <td class="num">{fmtMoney(r?.activity ?? 0)}</td>
        <td class="num avail">
          <Pill available={r?.available ?? 0} />
        </td>
      </tr>
    );
  };

  const total = (ids: string[], f: (r: CategoryMonth) => number) =>
    ids.reduce((s, id) => s + (rows.get(id) ? f(rows.get(id)!) : 0), 0);

  const cards = budget.card_payments ?? [];

  return (
    <>
      <header class="bar">
        <div class="months">
          <button class="icon" onClick={() => p.setMonth(shiftMonth(month, -1))} aria-label="Previous month">
            <Icon d={path.left} />
          </button>
          <strong data-testid="month" title={month}>
            {monthLabel(month)}
          </strong>
          <button class="icon" onClick={() => p.setMonth(shiftMonth(month, 1))} aria-label="Next month">
            <Icon d={path.right} />
          </button>
        </div>
        <div class={`rta ${budget.ready_to_assign < 0 ? "neg" : ""}`}>
          <strong data-testid="rta">{fmtMoney(budget.ready_to_assign)}</strong>
          <small>Ready to Assign</small>
        </div>
      </header>
      <div class="chips" role="group" aria-label="Filter categories">
        {FILTERS.map((f) => (
          <button
            class={`chip ${filter === f.id ? "on" : ""}`}
            aria-pressed={filter === f.id}
            onClick={() => setFilter(f.id)}
          >
            {filter === f.id && <Icon d="M9 16.17L4.83 12l-1.42 1.41L9 19 21 7l-1.41-1.41z" size={18} />}
            {f.label}
          </button>
        ))}
      </div>
      {deleting && <DeleteCategory db={db} category={deleting} onDone={() => setDeleting(null)} />}
      <div class="plan">
        <section class="plan-main">
          <form
            class="toolbar"
            onSubmit={(e) => {
              e.preventDefault();
              if (!newGroup.trim()) return;
              db.edit("category_group", uuid(), { name: newGroup.trim(), sort: groups.length });
              setNewGroup("");
            }}
          >
            <Icon d={path.add} size={20} />
            <input
              placeholder="New category group"
              value={newGroup}
              onInput={(e) => setNewGroup((e.target as HTMLInputElement).value)}
            />
            <button>Add group</button>
          </form>
          <div class="scroll">
            <table class="budget">
              <thead>
                <tr>
                  <th>Category</th>
                  <th class="num">Assigned</th>
                  <th class="num">Activity</th>
                  <th class="num">Available</th>
                </tr>
              </thead>
              {groups.map((g) => {
                const mine = categories.filter((c) => c.data.group_id === g.id);
                const ids = mine.map((c) => c.id);
                if (filtered && !mine.some((c) => matches(filter, rows.get(c.id)?.available ?? 0))) return null;
                const shut = collapsed.has(g.id);
                return (
                  <tbody>
                    <tr class="group">
                      <th>
                        <button
                          class="link chev"
                          aria-expanded={!shut}
                          aria-label={`${shut ? "Expand" : "Collapse"} ${g.data.name}`}
                          onClick={() => toggle(g.id)}
                        >
                          <span class={shut ? "shut" : ""}>
                            <Icon d={path.down} size={22} />
                          </span>
                        </button>
                        {g.data.name}
                        <button
                          class="link"
                          title="Delete group"
                          aria-label={`Delete group ${g.data.name}`}
                          onClick={() => removeGroup(g)}
                        >
                          ×
                        </button>
                      </th>
                      <td class="num">{fmtMoney(total(ids, (r) => r.assigned))}</td>
                      <td class="num">{fmtMoney(total(ids, (r) => r.activity))}</td>
                      <td class="num">{fmtMoney(total(ids, (r) => r.available))}</td>
                    </tr>
                    {!shut && mine.map(categoryRow)}
                    {!shut && !filtered && <AddCategory db={db} groupId={g.id} />}
                  </tbody>
                );
              })}
              {cards.length > 0 && !filtered && (
                <tbody data-testid="card-payments">
                  <tr class="group">
                    <th>Credit Card Payments</th>
                    <td class="num">{fmtMoney(cards.reduce((s, r) => s + r.assigned, 0))}</td>
                    <td class="num">{fmtMoney(cards.reduce((s, r) => s + r.activity, 0))}</td>
                    <td class="num">{fmtMoney(cards.reduce((s, r) => s + r.available, 0))}</td>
                  </tr>
                  {cards.map((r) => {
                    const name = db.get("account", r.account_id)?.data.name ?? "Card";
                    return (
                      <tr class="cat" data-cat={`card:${name}`}>
                        <td>{name}</td>
                        <td class="num">
                          <AssignInput
                            key={`${r.category_id}:${month}:${r.assigned}`}
                            label={`Assigned to ${name} payment`}
                            value={r.assigned}
                            onCommit={assign(r.category_id)}
                          />
                        </td>
                        <td class="num">{fmtMoney(r.activity)}</td>
                        <td class="num avail">
                          <Pill available={r.available} />
                        </td>
                      </tr>
                    );
                  })}
                </tbody>
              )}
              {orphaned.size > 0 && !filtered && (
                <tbody data-testid="orphaned">
                  <tr class="group">
                    <th colSpan={4}>Orphaned (group was deleted)</th>
                  </tr>
                  {categories.filter((c) => orphaned.has(c.id)).map(categoryRow)}
                </tbody>
              )}
            </table>
          </div>
        </section>
        <aside class="plan-side">
          <Summary budget={budget} month={month} />
          <AutoAssignPanel db={db} month={month} budget={budget} />
        </aside>
      </div>
    </>
  );
}

function Summary({ budget, month }: { budget: BudgetMonth; month: string }) {
  const all = [...budget.categories, ...(budget.card_payments ?? [])];
  const sum = (f: (r: CategoryMonth) => number) => all.reduce((s, r) => s + f(r), 0);
  const assigned = sum((r) => r.assigned);
  const activity = sum((r) => r.activity);
  const available = sum((r) => r.available);
  const name = new Date(Number(month.slice(0, 4)), Number(month.slice(5)) - 1, 1).toLocaleDateString("en-US", {
    month: "long",
  });
  return (
    <section class="card">
      <h2>{name}'s Summary</h2>
      <div class="kv">
        <span>Left Over from Last Month</span>
        <span>{fmtMoney(available - assigned - activity)}</span>
      </div>
      <div class="kv">
        <span>Assigned in {name}</span>
        <span>{fmtMoney(assigned)}</span>
      </div>
      <div class="kv">
        <span>Activity</span>
        <span>{fmtMoney(activity)}</span>
      </div>
      <div class="kv total">
        <span>Available</span>
        <span>{fmtMoney(available)}</span>
      </div>
    </section>
  );
}

function AutoAssignPanel({ db, month, budget }: { db: Db; month: string; budget: BudgetMonth }) {
  const options = useMemo(() => {
    const entities = [...db.entities.values()];
    const prev = [1, 2, 3].map((k) => computeBudget(entities, shiftMonth(month, -k)));
    return autoAssigns(prev, budget);
  }, [db.version, month]);
  const have = new Map(budget.categories.map((c) => [c.category_id, c.assigned]));

  const apply = (o: (typeof options)[number]) => {
    if (!confirm(`${o.label}: replace this month's assigned amounts?`)) return;
    for (const [id, v] of o.amounts) {
      if (have.get(id) !== v)
        db.edit("budget_entry", budgetEntryId(id, month), { category_id: id, month, assigned: v });
    }
  };

  const item = (o: (typeof options)[number], cls: string) => (
    <li>
      <button class={`li ${cls}`} onClick={() => apply(o)}>
        <span>{o.label}</span>
        <span class="num">{fmtMoney(o.total)}</span>
      </button>
    </li>
  );
  const [lastAssigned, lastSpent, avgAssigned, avgSpent, reset] = options as [
    (typeof options)[number],
    (typeof options)[number],
    (typeof options)[number],
    (typeof options)[number],
    (typeof options)[number],
  ];

  return (
    <section class="card">
      <h2>
        <Icon d={path.bolt} size={22} />
        Auto-Assign
      </h2>
      <ul class="li-list">
        {item(lastAssigned, "t")}
        {item(lastSpent, "")}
        {item(avgAssigned, "")}
        {item(avgSpent, "")}
      </ul>
      <ul class="li-list gap">{item(reset, "s")}</ul>
    </section>
  );
}

/** D3: a category with transactions is deleted only after they are deleted or moved. */
function DeleteCategory({ db, category, onDone }: { db: Db; category: Entity; onDone: () => void }) {
  const n = categoryTxCount(db, category.id);
  const others = db
    .list("category")
    .filter((c) => c.id !== category.id)
    .sort(byName);
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
            if (!confirm(`Delete ${n} transaction${n === 1 ? "" : "s"} and the category? This cannot be undone.`))
              return;
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

/** Reads as money ("Rp1.200.000"). While focused it edits as a plain number ("1200000"). */
function AssignInput({ value, label, onCommit }: { value: number; label: string; onCommit: (v: number) => void }) {
  const [text, setText] = useState<string | null>(null);
  const commit = () => {
    if (text === null) return;
    const v = parse(text);
    setText(null);
    if (v !== null && v !== value) onCommit(v);
  };
  return (
    <input
      class="num"
      aria-label={label}
      inputMode="decimal"
      value={text ?? fmtMoney(value)}
      onInput={(e) => setText((e.target as HTMLInputElement).value)}
      onBlur={commit}
      onKeyDown={(e) => e.key === "Enter" && (e.target as HTMLInputElement).blur()}
      onFocus={(e) => {
        const el = e.target as HTMLInputElement;
        setText(plain(value));
        setTimeout(() => el.select());
      }}
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
          <input
            placeholder="Add category"
            value={name}
            onInput={(e) => setName((e.target as HTMLInputElement).value)}
          />
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
  const nameOf = (list: Entity[], id?: string | null) => list.find((e) => e.id === id)?.data.name ?? "";

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
        {isUnmatched(db, t) && (
          <em class="neg" title="The other leg is missing">
            {" "}
            (unmatched)
          </em>
        )}
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
    <div class="page">
      <h2>{account ? nameOf(accounts, account) : "All transactions"}</h2>
      <TxForm db={db} account={account} />
      <div class="scroll">
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
                  <td class={`num ${t.data.amount < 0 ? "neg" : "pos"}`}>{fmtMoney(t.data.amount)}</td>
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
      </div>
    </div>
  );
}
