import { useState } from "preact/hooks";
import type { Db } from "./db";
import { uuid } from "./db";
import { addTransfer, editTransfer, isTransfer, splitsOf, transferNeedsCategory } from "./ledger";
import { fmt, parse, today } from "./money";
import type { Entity, Split } from "./types";

const byName = (a: Entity, b: Entity) =>
  (a.data.sort ?? 0) - (b.data.sort ?? 0) || String(a.data.name).localeCompare(String(b.data.name));

interface Line {
  category: string;
  amount: string;
}

/** Add a transaction or transfer, or edit an existing one. */
export function TxForm(p: { db: Db; account?: string; editing?: Entity; onDone?: () => void }) {
  const { db, editing } = p;
  const accounts = db.list("account").sort(byName);
  const categories = db.list("category").sort(byName);
  const payees = db.list("payee");
  const editingTransfer = !!editing && isTransfer(editing);
  // Default to an on-budget account: that is where most transactions go.
  const firstAccount = (accounts.find((a) => a.data.on_budget) ?? accounts[0])?.id ?? "";
  const out = editing ? (editing.data.amount as number) < 0 : true;

  const [f, setF] = useState(() => ({
    mode: (editingTransfer ? "transfer" : "tx") as "tx" | "transfer",
    date: editing?.data.date ?? today(),
    account: editing?.data.account_id ?? p.account ?? firstAccount,
    to: editingTransfer
      ? (editing!.data.transfer_account_id as string)
      : accounts.find((a) => a.id !== (p.account ?? firstAccount))?.id ?? "",
    payee: (editing && db.get("payee", editing.data.payee_id)?.data.name) ?? "",
    category: (editing?.data.category_id as string | null) ?? "",
    memo: editing?.data.memo ?? "",
    amount: editing ? fmt(Math.abs(editing.data.amount)) : "",
    inflow: editing ? !out : false,
    cleared: !!editing?.data.cleared,
    split: !!editing && splitsOf(editing).length > 0,
  }));
  const [lines, setLines] = useState<Line[]>(() =>
    editing
      ? splitsOf(editing).map((l) => ({ category: l.category_id, amount: fmt(Math.abs(l.amount)) }))
      : [{ category: "", amount: "" }],
  );
  const [error, setError] = useState("");

  const set = (k: keyof typeof f) => (e: Event) => {
    const t = e.target as HTMLInputElement;
    setF((s) => ({ ...s, [k]: t.type === "checkbox" ? t.checked : t.value }));
  };

  // For an edited transfer leg the pair's direction is fixed: from is the outflow side.
  const from = editingTransfer ? (out ? editing!.data.account_id : editing!.data.transfer_account_id) : f.account;
  const to = editingTransfer ? (out ? editing!.data.transfer_account_id : editing!.data.account_id) : f.to;
  const needsCategory = f.mode === "transfer" && !!from && !!to && transferNeedsCategory(db, from, to);

  const nameOf = (id: string) => String(db.get("account", id)?.data.name ?? "");
  const total = parse(f.amount);
  const lineMs = lines.map((l) => parse(l.amount));
  const lineSum = lineMs.reduce<number>((s, v) => s + Math.abs(v ?? 0), 0);

  const submit = (e: Event) => {
    e.preventDefault();
    setError("");
    if (total === null) return setError("Enter an amount.");
    const mag = Math.abs(total);

    if (f.mode === "transfer") {
      if (!from || !to || from === to) return setError("Pick two different accounts.");
      if (mag === 0) return setError("A transfer needs an amount.");
      if (needsCategory && !f.category) return setError("Pick the category this money comes from.");
      const categoryId = needsCategory ? f.category : null;
      const memo = f.memo.trim() || null;
      if (editing) editTransfer(db, editing, { date: f.date, amount: mag, memo, cleared: f.cleared, categoryId });
      else addTransfer(db, { date: f.date, from, to, amount: mag, memo, cleared: f.cleared, categoryId });
      return done();
    }

    if (!f.account) return setError("Pick an account.");
    let splits: Split[] = [];
    if (f.split) {
      if (lines.some((l, i) => !l.category || lineMs[i] === null || lineMs[i] === 0))
        return setError("Every split line needs a category and an amount.");
      if (lineSum !== mag)
        return setError(`Split lines add up to ${fmt(lineSum)}, but the amount is ${fmt(mag)}.`);
      splits = lines.map((l, i) => ({
        category_id: l.category,
        amount: f.inflow ? Math.abs(lineMs[i]!) : -Math.abs(lineMs[i]!),
      }));
    }

    let payeeId: string | null = null;
    const name = f.payee.trim();
    if (name) {
      const hit = payees.find((x) => String(x.data.name).toLowerCase() === name.toLowerCase());
      payeeId = hit?.id ?? uuid();
      if (!hit) db.edit("payee", payeeId, { name });
    }
    const fields: Record<string, unknown> = {
      account_id: f.account,
      date: f.date,
      amount: f.inflow ? mag : -mag,
      payee_id: payeeId,
      category_id: f.split ? null : f.category || null,
      memo: f.memo.trim() || null,
      cleared: f.cleared,
    };
    if (editing) {
      // Send only what changed, so edits made elsewhere to other fields survive the merge.
      const changed: Record<string, unknown> = {};
      for (const [k, v] of Object.entries(fields)) {
        if (JSON.stringify(v ?? null) !== JSON.stringify(editing.data[k] ?? null)) changed[k] = v;
      }
      if (JSON.stringify(splits) !== JSON.stringify(splitsOf(editing))) changed.splits = splits;
      if (Object.keys(changed).length) db.edit("transaction", editing.id, changed);
    } else {
      db.edit("transaction", uuid(), f.split ? { ...fields, splits } : fields);
    }
    done();
  };

  const done = () => {
    if (editing) return p.onDone?.();
    setF((s) => ({ ...s, payee: "", amount: "", memo: "", split: false }));
    setLines([{ category: "", amount: "" }]);
  };

  const catSelect = (value: string, onChange: (e: Event) => void, blank: string) => (
    <select value={value} onChange={onChange}>
      <option value="">{blank}</option>
      {categories.map((c) => (
        <option value={c.id}>{c.data.name}</option>
      ))}
    </select>
  );

  const accountSelect = (value: string, key: "account" | "to", disabled = false) => (
    <select value={value} onChange={set(key)} disabled={disabled}>
      {accounts.map((a) => (
        <option value={a.id}>{a.data.name}</option>
      ))}
    </select>
  );

  return (
    <form class="txform" onSubmit={submit}>
      {!editing && (
        <div class="modes">
          <button type="button" class={f.mode === "tx" ? "on" : ""} onClick={() => setF((s) => ({ ...s, mode: "tx" }))}>
            Transaction
          </button>
          <button
            type="button"
            class={f.mode === "transfer" ? "on" : ""}
            onClick={() => setF((s) => ({ ...s, mode: "transfer" }))}
          >
            Transfer
          </button>
        </div>
      )}
      <input type="date" value={f.date} onInput={set("date")} required />
      {f.mode === "tx" ? (
        <>
          {!p.account && accountSelect(f.account, "account")}
          <input list="payees" placeholder="Payee" value={f.payee} onInput={set("payee")} />
          <datalist id="payees">
            {payees.map((x) => (
              <option value={x.data.name} />
            ))}
          </datalist>
          {!f.split && catSelect(f.category, set("category"), "Income (Ready to Assign)")}
          <button type="button" class={f.split ? "on" : ""} onClick={() => setF((s) => ({ ...s, split: !s.split }))}>
            Split
          </button>
        </>
      ) : (
        <>
          <label>
            From {accountSelect(from, "account", editingTransfer)}
          </label>
          <label>
            To {accountSelect(to, "to", editingTransfer)}
          </label>
          {needsCategory && catSelect(f.category, set("category"), "Category (required)")}
        </>
      )}
      <input placeholder="Memo" value={f.memo} onInput={set("memo")} />
      <input class="num" inputMode="decimal" placeholder="Amount" value={f.amount} onInput={set("amount")} required />
      {f.mode === "tx" && (
        <label>
          <input type="checkbox" checked={f.inflow} onChange={set("inflow")} /> Inflow
        </label>
      )}
      <label>
        <input type="checkbox" checked={f.cleared} onChange={set("cleared")} /> Cleared
      </label>
      <button>{editing ? "Save" : "Add"}</button>
      {editing && (
        <button type="button" onClick={() => p.onDone?.()}>
          Cancel
        </button>
      )}
      {f.mode === "transfer" && !editing && from && to && (
        <small class="memo">
          {nameOf(from)} to {nameOf(to)}
        </small>
      )}
      {f.mode === "tx" && f.split && (
        <div class="splits">
          {lines.map((l, i) => (
            <div class="inline" data-split-line={i}>
              {catSelect(l.category, (e) => setLines((ls) => ls.map((x, j) => (j === i ? { ...x, category: (e.target as HTMLSelectElement).value } : x))), "Category")}
              <input
                class="num"
                inputMode="decimal"
                placeholder="Line amount"
                value={l.amount}
                onInput={(e) => setLines((ls) => ls.map((x, j) => (j === i ? { ...x, amount: (e.target as HTMLInputElement).value } : x)))}
              />
              {lines.length > 1 && (
                <button type="button" class="link" title="Remove line" onClick={() => setLines((ls) => ls.filter((_, j) => j !== i))}>
                  ×
                </button>
              )}
            </div>
          ))}
          <button type="button" onClick={() => setLines((ls) => [...ls, { category: "", amount: "" }])}>
            Add split line
          </button>
          <small class="memo" data-testid="split-left">
            Left to split: {fmt(Math.abs(total ?? 0) - lineSum)}
          </small>
        </div>
      )}
      {error && <p class="err">{error}</p>}
    </form>
  );
}
