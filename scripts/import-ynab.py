#!/usr/bin/env python3
"""Import a YNAB export (the Register and Plan TSV files) into an EMPTY zero-sum server.

    python3 scripts/import-ynab.py http://127.0.0.1:8787 "<...> - Register.tsv" "<...> - Plan.tsv"

Register rows become accounts, payees, categories, transactions and transfers. Plan rows
become budget entries (assigned amounts). Amounts are whole rupiah ("Rp6000"), stored as
milliunits. Ids are deterministic, so a rerun reports duplicates instead of doubling data.
The export is personal data: pass its path, never commit it.

Mapping choices (edit the three sets below for another budget):
- KINDS: everything not listed is a checking account.
- TRACKING: off-budget accounts. Their transfers cross the budget boundary (rule D5), so a
  leg with a category gives it to both legs.
- CLOSED: closed accounts. They stay in the ledger and drop out of the sidebar.
"""
import csv
import json
import re
import sys
import urllib.request
import uuid
from datetime import datetime

NS = uuid.UUID("5a0e1c2d-0000-4000-8000-000000000002")
# Same namespace as crates/core/src/model.rs BUDGET_ENTRY_NAMESPACE.
BUDGET_NS = uuid.UUID(int=0x7A65_726F_2D73_756D_8000_0000_0000_0001)
DEVICE = "import-ynab"
TS = 1_794_000_000_000

KINDS = {
    "Cash": "cash", "Gopay": "cash", "OVO": "cash", "Flazz": "cash",
    "Tokopedia Card": "credit_card", "Kredivo": "credit_card", "Gopaylater": "credit_card",
    "Kredivo (Closed)": "credit_card", "Saving": "savings",
    "Motorcycle Installment": "other",
}
TRACKING = {"Saving", "Motorcycle Installment", "Kredivo (Closed)"}
CLOSED = {"BCA", "Permata", "Motorcycle Installment", "Kredivo (Closed)"}
HIDDEN_GROUPS = {"Hidden Categories"}
TRANSFER = "Transfer : "


def u(name):
    return str(uuid.uuid5(NS, name))


def milli(s):
    """'Rp6000' or '-Rp6000' to milliunits."""
    s = s.strip()
    n = int(re.sub(r"\D", "", s) or 0) * 1000
    return -n if s.startswith("-") else n


def read(path):
    with open(path, encoding="utf-8-sig", newline="") as f:
        return list(csv.DictReader(f, delimiter="\t"))


ops = []


def put(kind, entity_id, /, **fields):
    n = len(ops)
    ops.append({"op_id": u(f"op:{n}"), "ts": TS + n, "kind": kind,
                "entity_id": entity_id, "fields": fields})
    return entity_id


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    base, register_path, plan_path = sys.argv[1].rstrip("/"), sys.argv[2], sys.argv[3]
    register, plan = read(register_path), read(plan_path)

    accounts = {}
    for name in sorted({r["Account"] for r in register}):
        fields = {"name": name, "kind": KINDS.get(name, "checking")}
        if name in TRACKING:
            fields["on_budget"] = False
        if name in CLOSED:
            fields["closed"] = True
        accounts[name] = put("account", u(f"acc:{name}"), **fields)

    groups, cats = {}, {}

    def category(group, name):
        if group not in groups:
            hidden = {"hidden": True} if group in HIDDEN_GROUPS else {}
            groups[group] = put("category_group", u(f"grp:{group}"), name=group, **hidden)
        if (group, name) not in cats:
            hidden = {"hidden": True} if group in HIDDEN_GROUPS else {}
            cats[(group, name)] = put("category", u(f"cat:{group}:{name}"),
                                      group_id=groups[group], name=name, **hidden)
        return cats[(group, name)]

    def has_category(r):
        return r["Category Group"] not in ("", "Inflow") and r["Category"]

    payees = {}

    def payee(name):
        if name not in payees:
            payees[name] = put("payee", u(f"payee:{name}"), name=name)
        return payees[name]

    # Pair the legs of each transfer: the outflow row and the inflow row of the same
    # date, accounts and amount. Rows are numbered by position, which keeps ids stable.
    rows = [(i, r) for i, r in enumerate(register)]
    inflows = {}
    for i, r in rows:
        if r["Payee"].startswith(TRANSFER) and milli(r["Inflow"]) > 0:
            key = (r["Date"], r["Account"], r["Payee"][len(TRANSFER):], milli(r["Inflow"]))
            inflows.setdefault(key, []).append(i)
    partner = {}
    for i, r in rows:
        if r["Payee"].startswith(TRANSFER) and milli(r["Outflow"]) > 0:
            key = (r["Date"], r["Payee"][len(TRANSFER):], r["Account"], milli(r["Outflow"]))
            if inflows.get(key):
                j = inflows[key].pop()
                partner[i], partner[j] = j, i

    skipped = {"zero": 0, "unmatched transfer": 0}
    counts = {"transactions": 0, "transfers": 0}
    for i, r in rows:
        amount = milli(r["Inflow"]) - milli(r["Outflow"])
        if amount == 0:
            skipped["zero"] += 1
            continue
        date = datetime.strptime(r["Date"], "%m/%d/%Y").strftime("%Y-%m-%d")
        fields = {"account_id": accounts[r["Account"]], "date": date, "amount": amount,
                  "cleared": r["Cleared"] != "Uncleared"}
        if r["Memo"]:
            fields["memo"] = r["Memo"]
        is_transfer = r["Payee"].startswith(TRANSFER)
        if is_transfer and i in partner:
            other = register[partner[i]]
            fields["transfer_account_id"] = accounts[r["Payee"][len(TRANSFER):]]
            fields["transfer_transaction_id"] = u(f"tx:{partner[i]}")
            boundary = (r["Account"] in TRACKING) != (other["Account"] in TRACKING)
            src = r if has_category(r) else other
            if boundary and has_category(src):
                fields["category_id"] = category(src["Category Group"], src["Category"])
            counts["transfers"] += 1
        else:
            if is_transfer:
                skipped["unmatched transfer"] += 1  # kept as a plain transaction
            elif r["Payee"]:
                fields["payee_id"] = payee(r["Payee"])
            if has_category(r):
                fields["category_id"] = category(r["Category Group"], r["Category"])
            counts["transactions"] += 1
        put("transaction", u(f"tx:{i}"), **fields)

    entries = 0
    for r in plan:
        assigned = milli(r["Assigned"])
        if assigned == 0:
            continue
        month = datetime.strptime(r["Month"], "%b %Y").strftime("%Y-%m")
        cid = category(r["Category Group"], r["Category"])
        put("budget_entry", str(uuid.uuid5(BUDGET_NS, f"{cid}:{month}")),
            category_id=cid, month=month, assigned=assigned)
        entries += 1

    def call(path, body=None):
        req = urllib.request.Request(
            base + path, data=None if body is None else json.dumps(body).encode(),
            headers={"content-type": "application/json"})
        with urllib.request.urlopen(req) as resp:
            return json.load(resp)

    if call("/sync/pull?since=0&limit=1")["changes"]:
        sys.exit("server is not empty: refusing to import")
    for i in range(0, len(ops), 100):
        out = call("/sync/push", {"device_id": DEVICE, "ops": ops[i:i + 100]})
        bad = [x for x in out["results"] if x["status"] not in ("applied", "duplicate")]
        if bad:
            sys.exit(f"push rejected: {bad[0]}")
    print(f"pushed {len(ops)} ops: {len(accounts)} accounts, {len(groups)} groups, "
          f"{len(cats)} categories, {len(payees)} payees, {counts['transactions']} transactions, "
          f"{counts['transfers']} transfer legs, {entries} budget entries; skipped {skipped}")
    month = max(datetime.strptime(r["Date"], "%m/%d/%Y") for r in register).strftime("%Y-%m")
    print(f"Ready to Assign in {month}: {call(f'/budget/{month}')['ready_to_assign'] / 1000:,.0f}")


if __name__ == "__main__":
    main()
