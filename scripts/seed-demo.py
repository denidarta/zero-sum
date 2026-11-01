#!/usr/bin/env python3
"""Seed an EMPTY zero-sum server with dummy data, then check the budget math.

    scripts/with-server.sh python3 scripts/seed-demo.py "$ZERO_SUM_TEST_SERVER"
    python3 scripts/seed-demo.py http://127.0.0.1:8787     # real server, must be empty

The data covers every rule in crates/core/src/budget.rs: income, carry-over,
overspending (resets to 0, reduces next month's Ready to Assign), splits,
refunds, uncategorized outflow, on-budget transfers (ignored), transfers to and
from an off-budget account, off-budget transactions and a deleted transaction.
Expected numbers below are worked out by hand, not read from the server.
Ids are deterministic, so a rerun pushes the same ops and reports duplicates.
"""
import json
import sys
import urllib.request
import uuid

NS = uuid.UUID("5a0e1c2d-0000-4000-8000-000000000001")
# Same namespace as crates/core/src/model.rs BUDGET_ENTRY_NAMESPACE.
BUDGET_NS = uuid.UUID(int=0x7A65_726F_2D73_756D_8000_0000_0000_0001)
DEVICE = "seed-demo"
TS = 1_761_900_000_000


def u(name):
    return str(uuid.uuid5(NS, name))


def mu(amount):
    """Currency units (int or decimal string) to milliunits."""
    return round(float(amount) * 1000)


ops = []


def put(etype, entity_id, /, **fields):
    n = len(ops)
    ops.append({"op_id": u(f"op:{n}"), "ts": TS + n, "kind": etype,
                "entity_id": entity_id, "fields": fields})
    return entity_id


def delete(kind, entity_id):
    n = len(ops)
    ops.append({"op_id": u(f"op:{n}"), "ts": TS + n, "kind": kind,
                "entity_id": entity_id, "fields": {}, "deleted": True})


# Accounts
checking = put("account", u("acc:checking"), name="Checking", kind="checking")
savings = put("account", u("acc:savings"), name="Savings", kind="savings")
card = put("account", u("acc:card"), name="Credit Card", kind="credit_card")
broker = put("account", u("acc:broker"), name="Brokerage", kind="other", on_budget=False)

# Category groups and categories
groups = {}
cats = {}
for gi, (gname, names) in enumerate([
    ("Bills", ["Rent", "Utilities", "Internet"]),
    ("Everyday", ["Groceries", "Dining Out", "Transport"]),
    ("Goals", ["Emergency Fund", "Vacation"]),
]):
    gid = groups[gname] = put("category_group", u(f"grp:{gname}"), name=gname, sort=gi)
    for ci, cname in enumerate(names):
        cats[cname] = put("category", u(f"cat:{cname}"), group_id=gid, name=cname, sort=ci)

payees = {}


def payee(name):
    if name not in payees:
        payees[name] = put("payee", u(f"payee:{name}"), name=name)
    return payees[name]


def tx(key, account, date, amount, who=None, cat=None, memo=None, cleared=True, **extra):
    fields = {"account_id": account, "date": date, "amount": mu(amount), "cleared": cleared}
    if who:
        fields["payee_id"] = payee(who)
    if cat:
        fields["category_id"] = cats[cat]
    if memo:
        fields["memo"] = memo
    fields.update(extra)
    return put("transaction", u(f"tx:{key}"), **fields)


def transfer(key, date, src, dst, amount, cat=None):
    """Two linked legs. Outflow in src, inflow in dst. Boundary transfers carry a category."""
    out_id, in_id = u(f"tx:{key}:out"), u(f"tx:{key}:in")
    for tid, acct, other, amt, partner in [
        (out_id, src, dst, -mu(amount), in_id),
        (in_id, dst, src, mu(amount), out_id),
    ]:
        fields = {"account_id": acct, "date": date, "amount": amt, "cleared": True,
                  "transfer_account_id": other, "transfer_transaction_id": partner}
        if cat:
            fields["category_id"] = cats[cat]
        put("transaction", tid, **fields)


def assign(month, **amounts):
    for cname, amount in amounts.items():
        cname = cname.replace("_", " ")
        cid = cats[cname]
        put("budget_entry", str(uuid.uuid5(BUDGET_NS, f"{cid}:{month}")),
            category_id=cid, month=month, assigned=mu(amount))


# ---- 2026-08 -------------------------------------------------------------
tx("aug-open-c", checking, "2026-08-01", 1000, "Opening Balance")
tx("aug-salary", checking, "2026-08-01", 4000, "Employer", memo="Salary")
tx("aug-open-s", savings, "2026-08-02", 2000, "Opening Balance")
assign("2026-08", Rent=1500, Utilities=200, Internet=80, Groceries=600, Dining_Out=200,
       Transport=150, Emergency_Fund=1000, Vacation=500)
tx("aug-rent", checking, "2026-08-01", -1500, "Landlord", "Rent")
tx("aug-power", checking, "2026-08-05", -180, "City Power", "Utilities")
tx("aug-net", checking, "2026-08-06", -80, "FiberNet", "Internet")
tx("aug-g1", card, "2026-08-03", -120, "Supermarket", "Groceries")
tx("aug-g2", checking, "2026-08-09", -95, "Farmers Market", "Groceries")
tx("aug-g3", card, "2026-08-17", -210, "Supermarket", "Groceries")
# Split: supermarket with fuel. Lines sum to the amount, no category of its own.
tx("aug-split", card, "2026-08-20", -150, "Hyper Mart", splits=[
    {"category_id": cats["Groceries"], "amount": mu(-100)},
    {"category_id": cats["Transport"], "amount": mu(-50)}])
tx("aug-fuel", checking, "2026-08-14", -60, "Gas Station", "Transport")
tx("aug-d1", card, "2026-08-08", -45, "Cafe", "Dining Out")
tx("aug-d2", card, "2026-08-22", -70, "Bistro", "Dining Out")
transfer("aug-sav", "2026-08-10", checking, savings, 500)         # on to on budget: ignored
transfer("aug-brk", "2026-08-12", checking, broker, 300, "Vacation")  # leaves the budget: spending
transfer("aug-pay", "2026-08-28", checking, card, 300)            # card payment: ignored

# ---- 2026-09 -------------------------------------------------------------
tx("sep-salary", checking, "2026-09-01", 4000, "Employer", memo="Salary")
tx("sep-free", checking, "2026-09-12", "350.25", "Client Co", memo="Freelance")
tx("sep-int", savings, "2026-09-30", "3.5", "Bank", memo="Interest")
tx("sep-atm", checking, "2026-09-08", -100, "ATM", memo="Cash, no category")  # uncategorized outflow
assign("2026-09", Rent=1500, Utilities=200, Internet=80, Groceries=600, Dining_Out=200,
       Transport=150, Emergency_Fund=500, Vacation=400)
tx("sep-rent", checking, "2026-09-01", -1500, "Landlord", "Rent")
tx("sep-power", checking, "2026-09-05", -240, "City Power", "Utilities")  # overspent by 20
tx("sep-net", checking, "2026-09-06", -80, "FiberNet", "Internet")
tx("sep-g1", card, "2026-09-04", -150, "Supermarket", "Groceries")
tx("sep-g2", checking, "2026-09-11", "-132.4", "Farmers Market", "Groceries")
tx("sep-g3", card, "2026-09-18", "-310.6", "Supermarket", "Groceries")
tx("sep-d1", card, "2026-09-06", -60, "Cafe", "Dining Out")
tx("sep-d2", card, "2026-09-20", -95, "Bistro", "Dining Out")
tx("sep-d3", checking, "2026-09-27", -130, "Steakhouse", "Dining Out")
tx("sep-t1", checking, "2026-09-02", -55, "Gas Station", "Transport")
tx("sep-t2", checking, "2026-09-16", -35, "Transit Pass", "Transport")
tx("sep-flight", card, "2026-09-25", -250, "Airline", "Vacation")
tx("sep-div", broker, "2026-09-15", 12, "Broker", memo="Dividend, off budget: ignored")
transfer("sep-sav", "2026-09-14", savings, checking, 200)
transfer("sep-pay", "2026-09-29", checking, card, 500)
# Entered by mistake, then deleted: must not count.
tx("sep-oops", checking, "2026-09-21", -999, "Oops", "Dining Out")
delete("transaction", u("tx:sep-oops"))

# ---- 2026-10 -------------------------------------------------------------
tx("oct-salary", checking, "2026-10-01", 4000, "Employer", memo="Salary")
transfer("oct-brk", "2026-10-20", broker, checking, 150)  # money in from off budget: income
assign("2026-10", Rent=1500, Utilities=220, Internet=80, Groceries=600, Dining_Out=250,
       Transport=150, Emergency_Fund=500, Vacation=400)
tx("oct-rent", checking, "2026-10-01", -1500, "Landlord", "Rent")
tx("oct-power", checking, "2026-10-05", "-205.75", "City Power", "Utilities")
tx("oct-net", checking, "2026-10-06", -80, "FiberNet", "Internet")
tx("oct-g1", card, "2026-10-03", -180, "Supermarket", "Groceries")
tx("oct-g2", checking, "2026-10-10", "-142.3", "Farmers Market", "Groceries")
tx("oct-g3", card, "2026-10-17", -265, "Supermarket", "Groceries")
tx("oct-d1", card, "2026-10-07", -80, "Cafe", "Dining Out")
tx("oct-d2", card, "2026-10-10", 25, "Cafe", "Dining Out", memo="Refund")  # categorized inflow
tx("oct-d3", card, "2026-10-24", "-110.5", "Bistro", "Dining Out")
tx("oct-t1", checking, "2026-10-04", -48, "Gas Station", "Transport")
tx("oct-t2", checking, "2026-10-18", "-52.5", "Transit Pass", "Transport")
tx("oct-hotel", checking, "2026-10-15", -120, "Hotel", "Vacation")
transfer("oct-pay", "2026-10-30", checking, card, 800)

# Expected, by hand. Per month: ready_to_assign, then {category: (assigned, activity, available)}.
# Ready to Assign = income so far - assigned so far - overspending of earlier months.
EXPECTED = {
    "2026-08": (2_770.0, {  # income 7000; assigned 4230
        "Rent": (1500, -1500, 0), "Utilities": (200, -180, 20), "Internet": (80, -80, 0),
        "Groceries": (600, -525, 75), "Dining Out": (200, -115, 85), "Transport": (150, -110, 40),
        "Emergency Fund": (1000, 0, 1000), "Vacation": (500, -300, 200)}),
    "2026-09": (3_393.75, {  # income 7000 + 4253.75; assigned 4230 + 3630
        "Rent": (1500, -1500, 0), "Utilities": (200, -240, -20), "Internet": (80, -80, 0),
        "Groceries": (600, -593, 82), "Dining Out": (200, -285, 0), "Transport": (150, -90, 100),
        "Emergency Fund": (500, 0, 1500), "Vacation": (400, -250, 350)}),
    "2026-10": (3_823.75, {  # income 11253.75 + 4150; assigned 7860 + 3700; minus 20 overspent in Sep
        "Rent": (1500, -1500, 0), "Utilities": (220, -205.75, 14.25), "Internet": (80, -80, 0),
        "Groceries": (600, -587.3, 94.7), "Dining Out": (250, -165.5, 84.5),
        "Transport": (150, -100.5, 149.5),
        "Emergency Fund": (500, 0, 2000), "Vacation": (400, -120, 630)}),
}


def call(base, path, body=None):
    req = urllib.request.Request(
        base + path, data=None if body is None else json.dumps(body).encode(),
        headers={"content-type": "application/json"})
    with urllib.request.urlopen(req) as r:
        return json.load(r)


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    base = sys.argv[1].rstrip("/")
    if call(base, "/sync/pull?since=0&limit=1")["changes"]:
        sys.exit("server is not empty: refusing to seed")
    for i in range(0, len(ops), 100):
        out = call(base, "/sync/push", {"device_id": DEVICE, "ops": ops[i:i + 100]})
        bad = [r for r in out["results"] if r["status"] not in ("applied", "duplicate")]
        if bad:
            sys.exit(f"push rejected: {bad[0]}")
    print(f"pushed {len(ops)} ops")

    names = {cid: n for n, cid in cats.items()}
    failures = 0
    for month, (rta, rows) in EXPECTED.items():
        got = call(base, f"/budget/{month}")
        checks = [("ready_to_assign", got["ready_to_assign"], mu(rta))]
        by_cat = {names[c["category_id"]]: c for c in got["categories"]}
        for cname, (a, act, av) in rows.items():
            c = by_cat[cname]
            checks += [(f"{cname}.assigned", c["assigned"], mu(a)),
                       (f"{cname}.activity", c["activity"], mu(act)),
                       (f"{cname}.available", c["available"], mu(av))]
        for label, have, want in checks:
            if have != want:
                failures += 1
                print(f"FAIL {month} {label}: got {have}, want {want}")
    if failures:
        sys.exit(f"{failures} mismatches")
    print("budget math matches the hand-computed numbers for 2026-08, 2026-09, 2026-10")


if __name__ == "__main__":
    main()
