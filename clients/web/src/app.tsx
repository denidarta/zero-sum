import { useEffect, useMemo, useState } from "preact/hooks";
import { budgetEntryId, computeBudget } from "./core";
import type { Db } from "./db";
import { uuid } from "./db";
import { fmt, parse, shiftMonth, thisMonth, today } from "./money";
import type { BudgetMonth, Entity } from "./types";

function useDb(db: Db) {
  const [, setN] = useState(0);
  useEffect(() => db.subscribe(() => setN((n) => n + 1)), [db]);
}

const byName = (a: Entity, b: Entity) =>
  (a.data.sort ?? 0) - (b.data.sort ?? 0) || String(a.data.name).localeCompare(String(b.data.name));

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
                  {!a.data.on_budget && <small> (tracking)</small>}
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
  const [newGroup, setNewGroup] = useState("");

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
                <button class="link" title="Delete group" onClick={() => confirm(`Delete group ${g.data.name}?`) && db.remove("category_group", g.id)}>
                  ×
                </button>
              </td>
            </tr>
            {categories
              .filter((c) => c.data.group_id === g.id)
              .map((c) => {
                const r = rows.get(c.id);
                return (
                  <tr data-cat={c.data.name}>
                    <td>{c.data.name}</td>
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
              })}
            <AddCategory db={db} groupId={g.id} />
          </tbody>
        ))}
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
  const nameOf = (list: Entity[], id?: string | null) =>
    list.find((e) => e.id === id)?.data.name ?? "";

  const txs = db
    .list("transaction")
    .filter((t) => !account || t.data.account_id === account)
    .sort((a, b) => b.data.date.localeCompare(a.data.date));

  const [form, setForm] = useState({
    date: today(),
    account: account ?? "",
    payee: "",
    category: "",
    amount: "",
    inflow: false,
    memo: "",
  });
  const set = (k: keyof typeof form) => (e: Event) => {
    const t = e.target as HTMLInputElement;
    setForm((f) => ({ ...f, [k]: t.type === "checkbox" ? t.checked : t.value }));
  };
  const acct = account ?? (form.account || accounts[0]?.id);

  const add = (e: Event) => {
    e.preventDefault();
    const v = parse(form.amount);
    if (v === null || !acct) return;
    let payeeId: string | null = null;
    const name = form.payee.trim();
    if (name) {
      const hit = payees.find((p) => String(p.data.name).toLowerCase() === name.toLowerCase());
      payeeId = hit?.id ?? uuid();
      if (!hit) db.edit("payee", payeeId, { name });
    }
    db.edit("transaction", uuid(), {
      account_id: acct,
      date: form.date,
      amount: form.inflow ? Math.abs(v) : -Math.abs(v),
      payee_id: payeeId,
      category_id: form.category || null,
      memo: form.memo.trim() || null,
    });
    setForm((f) => ({ ...f, payee: "", amount: "", memo: "" }));
  };

  if (!accounts.length) return <p class="empty">Add an account to start.</p>;

  return (
    <>
      <h2>{account ? nameOf(accounts, account) : "All transactions"}</h2>
      <form class="txform" onSubmit={add}>
        <input type="date" value={form.date} onInput={set("date")} required />
        {!account && (
          <select value={acct} onChange={set("account")}>
            {accounts.map((a) => (
              <option value={a.id}>{a.data.name}</option>
            ))}
          </select>
        )}
        <input list="payees" placeholder="Payee" value={form.payee} onInput={set("payee")} />
        <datalist id="payees">
          {payees.map((p) => (
            <option value={p.data.name} />
          ))}
        </datalist>
        <select value={form.category} onChange={set("category")}>
          <option value="">Income (Ready to Assign)</option>
          {categories.map((c) => (
            <option value={c.id}>{c.data.name}</option>
          ))}
        </select>
        <input placeholder="Memo" value={form.memo} onInput={set("memo")} />
        <input class="num" inputMode="decimal" placeholder="Amount" value={form.amount} onInput={set("amount")} required />
        <label>
          <input type="checkbox" checked={form.inflow} onChange={set("inflow")} /> Inflow
        </label>
        <button>Add</button>
      </form>
      <table class="tx">
        <tbody>
          {txs.map((t) => (
            <tr data-tx={t.id}>
              <td>{t.data.date}</td>
              {!account && <td>{nameOf(accounts, t.data.account_id)}</td>}
              <td>{nameOf(payees, t.data.payee_id)}</td>
              <td>{nameOf(categories, t.data.category_id) || <em>Income</em>}</td>
              <td class="memo">{t.data.memo}</td>
              <td class={`num ${t.data.amount < 0 ? "neg" : "pos"}`}>{fmt(t.data.amount)}</td>
              <td>
                <button class="link" title="Delete" onClick={() => db.remove("transaction", t.id)}>
                  ×
                </button>
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </>
  );
}
