use super::*;
use crate::{
    budget::{compute, Snapshot},
    model::budget_entry_id,
};

const MONTH: &str = "2026-10";

fn id(n: u8) -> Uuid {
    Uuid::from_u128(0x1000 + n as u128)
}
const CHECKING: u8 = 1;
const SAVINGS: u8 = 2;
const HOUSE: u8 = 3; // tracking account
const GROUP: u8 = 10;
const RENT: u8 = 11;
const FOOD: u8 = 12;

fn entity(kind: Kind, id: Uuid, data: Value) -> EntityState {
    let Value::Object(data) = data else { panic!() };
    EntityState {
        kind,
        id,
        data,
        stamps: Default::default(),
        deleted: false,
    }
}

/// Checking, Savings, tracking House; one group with Rent and Food; 3,000.00 income.
fn world() -> Vec<EntityState> {
    let mut v = vec![];
    for (n, on) in [(CHECKING, true), (SAVINGS, true), (HOUSE, false)] {
        v.push(entity(
            Kind::Account,
            id(n),
            json!({"name": "A", "kind": "checking", "on_budget": on}),
        ));
    }
    v.push(entity(
        Kind::CategoryGroup,
        id(GROUP),
        json!({"name": "Bills"}),
    ));
    for n in [RENT, FOOD] {
        v.push(entity(
            Kind::Category,
            id(n),
            json!({"group_id": id(GROUP), "name": "C"}),
        ));
    }
    v.push(entity(
        Kind::Transaction,
        id(50),
        json!({"account_id": id(CHECKING), "date": "2026-10-01", "amount": 3_000_000}),
    ));
    v
}

/// Apply patches the way a client does: write fields, or tombstone.
fn apply(world: &mut Vec<EntityState>, patches: &[Patch]) {
    for p in patches {
        match world.iter_mut().find(|e| e.kind == p.kind && e.id == p.id) {
            Some(e) if p.deleted => e.deleted = true,
            Some(e) => e.data.extend(p.fields.clone()),
            None => world.push(entity(p.kind, p.id, Value::Object(p.fields.clone()))),
        }
    }
}

fn run(world: &mut Vec<EntityState>, cmd: Value) -> Result<Vec<Patch>, String> {
    let cmd: Command = serde_json::from_value(cmd).unwrap();
    let patches = plan(world, &cmd)?;
    apply(world, &patches);
    Ok(patches)
}

fn budget(world: &[EntityState]) -> crate::budget::BudgetMonth {
    compute(&Snapshot::from_entities(world).unwrap(), MONTH).unwrap()
}

fn activity(world: &[EntityState], cat: u8) -> Option<i64> {
    let b = budget(world);
    b.categories
        .iter()
        .find(|c| c.category_id == id(cat))
        .map(|c| c.activity)
}

fn add_transfer(
    world: &mut Vec<EntityState>,
    from: u8,
    to: u8,
    cat: Option<u8>,
) -> Result<(), String> {
    run(
        world,
        json!({
            "command": "add_transfer", "ids": [id(60), id(61)], "date": "2026-10-02",
            "from": id(from), "to": id(to), "amount": 500_000, "category_id": cat.map(id),
        }),
    )
    .map(drop)
}

fn tx(world: &[EntityState], n: u8) -> &EntityState {
    world.iter().find(|e| e.id == id(n)).unwrap()
}

fn spend(world: &mut Vec<EntityState>, n: u8, cat: u8, amount: i64) {
    apply(
        world,
        &[edit(
            Kind::Transaction,
            id(n),
            json!({"account_id": id(CHECKING), "date": "2026-10-05", "amount": -amount, "category_id": id(cat)}),
        )],
    );
}

fn assign(world: &mut Vec<EntityState>, cat: u8, amount: i64) {
    let entry = budget_entry_id(id(cat), MONTH);
    apply(
        world,
        &[edit(
            Kind::BudgetEntry,
            entry,
            json!({"category_id": id(cat), "month": MONTH, "assigned": amount}),
        )],
    );
}

#[test]
fn transfer_creates_linked_pair_and_on_budget_transfer_is_neutral() {
    let mut w = world();
    add_transfer(&mut w, CHECKING, SAVINGS, None).unwrap();
    let (out, inn) = (tx(&w, 60), tx(&w, 61));
    assert_eq!(out.data["amount"], -500_000);
    assert_eq!(inn.data["amount"], 500_000);
    assert_eq!(out.data["account_id"], json!(id(CHECKING)));
    assert_eq!(out.data["transfer_transaction_id"], json!(id(61)));
    assert_eq!(inn.data["transfer_transaction_id"], json!(id(60)));
    assert_eq!(budget(&w).ready_to_assign, 3_000_000);
}

#[test]
fn transfer_to_tracking_account_needs_a_category_and_counts_as_spending() {
    let mut w = world();
    assert_eq!(
        add_transfer(&mut w, CHECKING, HOUSE, None).unwrap_err(),
        "Pick the category this money comes from."
    );
    add_transfer(&mut w, CHECKING, HOUSE, Some(RENT)).unwrap();
    assert_eq!(activity(&w, RENT), Some(-500_000));

    // The other direction, and on-budget pairs, need no category and store none.
    let mut w = world();
    add_transfer(&mut w, HOUSE, CHECKING, Some(RENT)).unwrap();
    assert_eq!(tx(&w, 60).data["category_id"], Value::Null);
}

#[test]
fn missing_on_budget_field_counts_as_on_budget_and_missing_account_does_not() {
    let mut w = world();
    w[0].data.remove("on_budget");
    w[2].data.remove("on_budget"); // House is now on budget too
    add_transfer(&mut w, CHECKING, HOUSE, None).unwrap();
    let w = world();
    let ghost = Uuid::from_u128(0xdead);
    let cmd = |from: Uuid, to: Uuid| {
        serde_json::from_value::<Command>(json!({
            "command": "add_transfer", "ids": [id(60), id(61)], "date": "2026-10-02",
            "from": from, "to": to, "amount": 1,
        }))
        .unwrap()
    };
    // An unknown account is off budget, like in budget math.
    assert!(plan(&w, &cmd(id(CHECKING), ghost)).is_err());
    assert!(plan(&w, &cmd(ghost, id(CHECKING))).is_ok());
}

#[test]
fn transfer_input_errors() {
    let w = world();
    let bad = |from: String, to: String, amount: i64| {
        serde_json::from_value::<Command>(json!({
            "command": "add_transfer", "ids": [id(60), id(61)], "date": "2026-10-02",
            "from": from, "to": to, "amount": amount,
        }))
        .unwrap()
    };
    let (c, s) = (id(CHECKING).to_string(), id(SAVINGS).to_string());
    assert_eq!(
        plan(&w, &bad(c.clone(), c.clone(), 5)).unwrap_err(),
        SAME_ACCOUNT
    );
    assert_eq!(
        plan(&w, &bad("".into(), s.clone(), 5)).unwrap_err(),
        SAME_ACCOUNT
    );
    assert_eq!(
        plan(&w, &bad(c.clone(), s.clone(), 0)).unwrap_err(),
        NO_AMOUNT
    );
}

#[test]
fn editing_one_leg_mirrors_the_other_with_flipped_sign() {
    let mut w = world();
    add_transfer(&mut w, CHECKING, SAVINGS, None).unwrap();
    run(
        &mut w,
        json!({
            "command": "edit_transfer", "id": id(61), "date": "2026-10-09",
            "amount": 700_000, "memo": "move", "cleared": true,
        }),
    )
    .unwrap();
    let (out, inn) = (tx(&w, 60), tx(&w, 61));
    assert_eq!(out.data["amount"], -700_000);
    assert_eq!(inn.data["amount"], 700_000);
    assert_eq!(out.data["date"], "2026-10-09");
    assert_eq!(out.data["memo"], "move");
    assert_eq!(out.data["cleared"], true);
}

#[test]
fn editing_a_transfer_leg_without_its_partner_edits_only_that_leg() {
    let mut w = world();
    add_transfer(&mut w, CHECKING, SAVINGS, None).unwrap();
    w.iter_mut().find(|e| e.id == id(60)).unwrap().deleted = true;
    let p = run(
        &mut w,
        json!({"command": "edit_transfer", "id": id(61), "date": "2026-10-09", "amount": 1}),
    )
    .unwrap();
    assert_eq!(p.len(), 1);
}

#[test]
fn editing_checks_the_transfer_rules() {
    let mut w = world();
    add_transfer(&mut w, CHECKING, HOUSE, Some(RENT)).unwrap();
    let edit = |amount: i64, category: Option<u8>| {
        serde_json::from_value::<Command>(json!({
            "command": "edit_transfer", "id": id(60), "date": "2026-10-02",
            "amount": amount, "category_id": category.map(id),
        }))
        .unwrap()
    };
    assert_eq!(plan(&w, &edit(0, Some(RENT))).unwrap_err(), NO_AMOUNT);
    assert!(plan(&w, &edit(5, None)).is_err());
    assert!(plan(&w, &edit(5, Some(FOOD))).is_ok());
    // A regular transaction is not a transfer.
    let cmd = Command::EditTransfer {
        id: id(50),
        date: "2026-10-02".into(),
        amount: 5,
        memo: None,
        cleared: false,
        category_id: None,
    };
    assert_eq!(plan(&w, &cmd).unwrap_err(), "not a transfer");
}

#[test]
fn deleting_one_leg_deletes_both() {
    let mut w = world();
    add_transfer(&mut w, CHECKING, SAVINGS, None).unwrap();
    let p = run(
        &mut w,
        json!({"command": "remove_transaction", "id": id(61)}),
    )
    .unwrap();
    assert_eq!(p.len(), 2);
    assert!(tx(&w, 60).deleted && tx(&w, 61).deleted);
    assert!(run(
        &mut w,
        json!({"command": "remove_transaction", "id": id(61)})
    )
    .is_err());
}

#[test]
fn moving_transactions_keeps_activity_and_frees_assigned_money() {
    let mut w = world();
    assign(&mut w, FOOD, 400_000);
    spend(&mut w, 70, FOOD, 100_000);
    assert_eq!(budget(&w).ready_to_assign, 2_600_000);
    run(
        &mut w,
        json!({"command": "move_category_transactions", "category_id": id(FOOD), "target": id(RENT)}),
    )
    .unwrap();
    assert_eq!(activity(&w, FOOD), None);
    assert_eq!(activity(&w, RENT), Some(-100_000));
    assert_eq!(budget(&w).ready_to_assign, 3_000_000);
}

#[test]
fn moving_needs_another_live_category() {
    let w = world();
    let move_to = |target: Uuid| Command::MoveCategoryTransactions {
        category_id: id(FOOD),
        target,
    };
    assert!(plan(&w, &move_to(id(FOOD))).is_err());
    assert!(plan(&w, &move_to(Uuid::from_u128(0xdead))).is_err());
    assert!(plan(&w, &move_to(id(RENT))).is_ok());
}

#[test]
fn deleting_transactions_frees_assigned_money() {
    let mut w = world();
    assign(&mut w, FOOD, 400_000);
    spend(&mut w, 70, FOOD, 100_000);
    run(
        &mut w,
        json!({"command": "delete_category_transactions", "category_id": id(FOOD)}),
    )
    .unwrap();
    assert!(tx(&w, 70).deleted);
    assert_eq!(activity(&w, FOOD), None);
    assert_eq!(budget(&w).ready_to_assign, 3_000_000);
}

fn split_world() -> Vec<EntityState> {
    let mut w = world();
    apply(
        &mut w,
        &[edit(
            Kind::Transaction,
            id(70),
            json!({
                "account_id": id(CHECKING), "date": "2026-10-05", "amount": -300_000,
                "splits": [
                    {"category_id": id(RENT), "amount": -100_000},
                    {"category_id": id(FOOD), "amount": -200_000, "memo": "lunch"},
                ],
            }),
        )],
    );
    w
}

#[test]
fn deleting_a_category_trims_only_its_split_lines() {
    let mut w = split_world();
    run(
        &mut w,
        json!({"command": "delete_category_transactions", "category_id": id(FOOD)}),
    )
    .unwrap();
    let t = tx(&w, 70);
    assert_eq!(t.data["amount"], -100_000);
    assert_eq!(
        t.data["splits"],
        json!([{"category_id": id(RENT), "amount": -100_000}])
    );
    // A split with no line left is deleted.
    run(
        &mut w,
        json!({"command": "delete_category_transactions", "category_id": id(RENT)}),
    )
    .unwrap();
    assert!(tx(&w, 70).deleted);
}

#[test]
fn moving_repoints_split_lines_and_keeps_their_memos() {
    let mut w = split_world();
    run(
        &mut w,
        json!({"command": "move_category_transactions", "category_id": id(FOOD), "target": id(RENT)}),
    )
    .unwrap();
    let lines = &tx(&w, 70).data["splits"];
    assert_eq!(lines[0]["category_id"], json!(id(RENT)));
    assert_eq!(lines[1]["category_id"], json!(id(RENT)));
    assert_eq!(lines[1]["memo"], "lunch");
    assert_eq!(activity(&w, RENT), Some(-300_000));
}

#[test]
fn deleting_a_transfer_category_deletes_each_leg_once() {
    let mut w = world();
    add_transfer(&mut w, CHECKING, HOUSE, Some(RENT)).unwrap();
    // House is off budget, so the partner leg is in House and carries the category too.
    w.iter_mut()
        .find(|e| e.id == id(61))
        .unwrap()
        .data
        .insert("category_id".into(), json!(id(RENT)));
    let p = run(
        &mut w,
        json!({"command": "delete_category_transactions", "category_id": id(RENT)}),
    )
    .unwrap();
    let tombstones: Vec<_> = p.iter().filter(|p| p.kind == Kind::Transaction).collect();
    assert_eq!(tombstones.len(), 2);
}

#[test]
fn deleting_a_category_removes_its_budget_entries_only() {
    let mut w = world();
    assign(&mut w, FOOD, 400_000);
    assign(&mut w, RENT, 100_000);
    let p = run(
        &mut w,
        json!({"command": "delete_empty_category", "category_id": id(FOOD)}),
    )
    .unwrap();
    assert_eq!(p.len(), 2);
    assert_eq!(budget(&w).ready_to_assign, 2_900_000);
}

#[test]
fn group_delete_is_blocked_while_it_has_categories() {
    let mut w = world();
    w[3].data.insert("name".into(), json!("Needs"));
    let cmd = |g: u8| json!({"command": "delete_group", "group_id": id(g)});
    assert_eq!(
        run(&mut w, cmd(GROUP)).unwrap_err(),
        "Move or delete the categories in Needs first."
    );
    assert_eq!(run(&mut w, cmd(99)).unwrap_err(), "group not found");
    for c in [RENT, FOOD] {
        run(
            &mut w,
            json!({"command": "delete_empty_category", "category_id": id(c)}),
        )
        .unwrap();
    }
    let p = run(&mut w, cmd(GROUP)).unwrap();
    assert_eq!((p[0].kind, p[0].deleted), (Kind::CategoryGroup, true));
}

fn reconcile(
    world: &mut Vec<EntityState>,
    account: u8,
    balance: i64,
    cat: Option<u8>,
) -> Vec<Patch> {
    run(
        world,
        json!({
            "command": "reconcile_account", "id": id(90), "account_id": id(account),
            "balance": balance, "date": "2026-10-20", "category_id": cat.map(id),
        }),
    )
    .unwrap()
}

#[test]
fn reconcile_matching_balance_plans_nothing() {
    let mut w = world();
    assert!(reconcile(&mut w, CHECKING, 3_000_000, None).is_empty());
}

#[test]
fn reconcile_inflow_delta_adds_income() {
    let mut w = world();
    let p = reconcile(&mut w, CHECKING, 3_200_000, None);
    assert_eq!(p.len(), 1);
    let t = tx(&w, 90);
    assert_eq!(t.data["amount"], 200_000);
    assert_eq!(t.data["memo"], ADJUSTMENT_MEMO);
    assert_eq!(t.data["cleared"], true);
    assert_eq!(budget(&w).ready_to_assign, 3_200_000);
    // Reconciled: planning again finds no difference.
    assert!(reconcile(&mut w, CHECKING, 3_200_000, None).is_empty());
}

#[test]
fn reconcile_outflow_delta_takes_the_picked_category() {
    let mut w = world();
    reconcile(&mut w, CHECKING, 2_900_000, Some(FOOD));
    assert_eq!(tx(&w, 90).data["amount"], -100_000);
    assert_eq!(activity(&w, FOOD), Some(-100_000));

    let mut w = world();
    reconcile(&mut w, CHECKING, 2_900_000, None);
    assert_eq!(budget(&w).ready_to_assign, 2_900_000);
}

#[test]
fn reconcile_ignores_deleted_transactions_and_off_budget_category() {
    let mut w = world();
    w.iter_mut().find(|e| e.id == id(50)).unwrap().deleted = true; // the 3,000.00 income
    reconcile(&mut w, HOUSE, 500_000, Some(FOOD));
    assert_eq!(tx(&w, 90).data["amount"], 500_000);
    assert_eq!(tx(&w, 90).data["category_id"], Value::Null);
}

#[test]
fn reconcile_unknown_account_is_an_error() {
    let w = world();
    let cmd = Command::ReconcileAccount {
        id: id(90),
        account_id: Uuid::from_u128(0xdead),
        balance: 1,
        date: "2026-10-20".into(),
        category_id: None,
    };
    assert_eq!(plan(&w, &cmd).unwrap_err(), "account not found");
}

#[test]
fn unknown_command_is_an_error() {
    assert!(serde_json::from_value::<Command>(json!({"command": "nope"})).is_err());
}
