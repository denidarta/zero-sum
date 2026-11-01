//! Ledger edit rules: transfers (two linked transactions), deleting transactions and
//! categories, trimming split lines. Spec: `docs/ledger-edits-spec.md`.
//!
//! [`plan`] turns one user action into patches. A client applies each patch with the
//! edit call it already has, so the outbox and sync do not change. Every client runs
//! the same plan, so the rules cannot drift between them.

use crate::{model::Kind, sync::EntityState};
use serde::{Deserialize, Serialize};
use serde_json::{json, Map, Value};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

#[derive(Debug, Clone, PartialEq, Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
pub enum Command {
    /// D4: an outflow leg in `from` and an inflow leg in `to`. `amount` is a positive
    /// magnitude. `ids` are the new ids of the outflow and inflow leg.
    AddTransfer {
        ids: [Uuid; 2],
        date: String,
        from: String,
        to: String,
        amount: i64,
        #[serde(default)]
        memo: Option<String>,
        #[serde(default)]
        cleared: bool,
        #[serde(default)]
        category_id: Option<Uuid>,
    },
    /// D8: write the edit to both legs, amount sign flipped on the partner.
    /// `id` is either leg. The accounts of a pair cannot change.
    EditTransfer {
        id: Uuid,
        date: String,
        amount: i64,
        #[serde(default)]
        memo: Option<String>,
        #[serde(default)]
        cleared: bool,
        #[serde(default)]
        category_id: Option<Uuid>,
    },
    /// A transfer takes its other leg with it.
    RemoveTransaction { id: Uuid },
    /// D3, move: re-point every transaction at `target`, then delete the category.
    MoveCategoryTransactions { category_id: Uuid, target: Uuid },
    /// D3, delete: remove the category's transactions (only its lines of a split), then the category.
    DeleteCategoryTransactions { category_id: Uuid },
    /// Remove a category and its budget entries, so the money returns to Ready to Assign.
    DeleteEmptyCategory { category_id: Uuid },
}

/// One entity write. `deleted` is a tombstone, otherwise `fields` is a field patch.
#[derive(Debug, Clone, PartialEq, Serialize)]
pub struct Patch {
    pub kind: Kind,
    pub id: Uuid,
    pub fields: Map<String, Value>,
    pub deleted: bool,
}

fn edit(kind: Kind, id: Uuid, fields: Value) -> Patch {
    let Value::Object(fields) = fields else {
        unreachable!("patch fields are an object")
    };
    Patch {
        kind,
        id,
        fields,
        deleted: false,
    }
}

fn remove(kind: Kind, id: Uuid) -> Patch {
    Patch {
        kind,
        id,
        fields: Map::new(),
        deleted: true,
    }
}

/// The live entities of a snapshot, by id and in input order.
struct Live<'a> {
    list: Vec<&'a EntityState>,
    by_id: HashMap<(Kind, Uuid), &'a EntityState>,
}

fn uuid_field(e: &EntityState, field: &str) -> Option<Uuid> {
    e.data.get(field)?.as_str()?.parse().ok()
}

fn splits(t: &EntityState) -> &[Value] {
    match t.data.get("splits") {
        Some(Value::Array(lines)) => lines,
        _ => &[],
    }
}

fn line_category(line: &Value) -> Option<Uuid> {
    line.get("category_id")?.as_str()?.parse().ok()
}

impl<'a> Live<'a> {
    fn new(entities: &'a [EntityState]) -> Self {
        let list: Vec<_> = entities.iter().filter(|e| !e.deleted).collect();
        let by_id = list.iter().map(|e| ((e.kind, e.id), *e)).collect();
        Live { list, by_id }
    }

    fn get(&self, kind: Kind, id: Uuid) -> Option<&'a EntityState> {
        self.by_id.get(&(kind, id)).copied()
    }

    fn of_kind(&self, kind: Kind) -> impl Iterator<Item = &'a EntityState> + '_ {
        self.list.iter().copied().filter(move |e| e.kind == kind)
    }

    fn transaction(&self, id: Uuid) -> Result<&'a EntityState, String> {
        self.get(Kind::Transaction, id)
            .ok_or_else(|| "transaction not found".to_string())
    }

    /// The other leg of a transfer, if it still exists.
    fn partner(&self, t: &EntityState) -> Option<&'a EntityState> {
        self.get(Kind::Transaction, uuid_field(t, "transfer_transaction_id")?)
    }

    /// An account counts as on budget when it exists and `on_budget` is not explicitly false.
    fn on_budget(&self, id: Uuid) -> bool {
        self.get(Kind::Account, id)
            .is_some_and(|a| a.data.get("on_budget") != Some(&Value::Bool(false)))
    }

    /// D5: money leaving the budget for a tracking account must come from a category.
    /// Returns the `category_id` value to store on both legs.
    fn transfer_category(
        &self,
        from: Uuid,
        to: Uuid,
        picked: Option<Uuid>,
    ) -> Result<Value, String> {
        if !self.on_budget(from) || self.on_budget(to) {
            return Ok(Value::Null);
        }
        picked
            .map(|c| json!(c))
            .ok_or_else(|| "Pick the category this money comes from.".into())
    }

    /// Live transactions that use a category, directly or in a split line.
    fn in_category(&self, category: Uuid) -> impl Iterator<Item = &'a EntityState> + '_ {
        self.of_kind(Kind::Transaction).filter(move |t| {
            uuid_field(t, "category_id") == Some(category)
                || splits(t).iter().any(|l| line_category(l) == Some(category))
        })
    }

    /// Remove a category. Its budget entries go with it, so the money returns to Ready to Assign.
    fn drop_category(&self, category: Uuid, out: &mut Vec<Patch>) {
        for e in self.of_kind(Kind::BudgetEntry) {
            if uuid_field(e, "category_id") == Some(category) {
                out.push(remove(Kind::BudgetEntry, e.id));
            }
        }
        out.push(remove(Kind::Category, category));
    }
}

const SAME_ACCOUNT: &str = "Pick two different accounts.";
const NO_AMOUNT: &str = "A transfer needs an amount.";

fn account_id(s: &str) -> Result<Uuid, String> {
    if s.is_empty() {
        return Err(SAME_ACCOUNT.into());
    }
    s.parse().map_err(|_| format!("bad account id {s:?}"))
}

/// Fields both legs of a transfer share.
fn common(date: &str, memo: &Option<String>, cleared: bool, category: Value) -> Value {
    json!({ "date": date, "memo": memo, "cleared": cleared, "category_id": category })
}

fn with(common: &Value, extra: Value) -> Value {
    let mut fields = common.clone();
    fields
        .as_object_mut()
        .unwrap()
        .extend(extra.as_object().unwrap().clone());
    fields
}

/// Turn one user action into entity writes. Fails with a message fit for the user.
pub fn plan(entities: &[EntityState], command: &Command) -> Result<Vec<Patch>, String> {
    let live = Live::new(entities);
    match command {
        Command::AddTransfer {
            ids,
            date,
            from,
            to,
            amount,
            memo,
            cleared,
            category_id,
        } => {
            let (from, to) = (account_id(from)?, account_id(to)?);
            if from == to {
                return Err(SAME_ACCOUNT.into());
            }
            if *amount <= 0 {
                return Err(NO_AMOUNT.into());
            }
            let category = live.transfer_category(from, to, *category_id)?;
            let c = common(date, memo, *cleared, category);
            let [a, b] = *ids;
            Ok(vec![
                edit(
                    Kind::Transaction,
                    a,
                    with(
                        &c,
                        json!({
                            "account_id": from, "amount": -amount,
                            "transfer_account_id": to, "transfer_transaction_id": b,
                        }),
                    ),
                ),
                edit(
                    Kind::Transaction,
                    b,
                    with(
                        &c,
                        json!({
                            "account_id": to, "amount": amount,
                            "transfer_account_id": from, "transfer_transaction_id": a,
                        }),
                    ),
                ),
            ])
        }

        Command::EditTransfer {
            id,
            date,
            amount,
            memo,
            cleared,
            category_id,
        } => {
            let t = live.transaction(*id)?;
            let (Some(account), Some(other)) = (
                uuid_field(t, "account_id"),
                uuid_field(t, "transfer_account_id"),
            ) else {
                return Err("not a transfer".into());
            };
            if *amount <= 0 {
                return Err(NO_AMOUNT.into());
            }
            let sign: i64 = if t.data.get("amount").and_then(Value::as_i64) < Some(0) {
                -1
            } else {
                1
            };
            let (from, to) = if sign < 0 {
                (account, other)
            } else {
                (other, account)
            };
            let category = live.transfer_category(from, to, *category_id)?;
            let c = common(date, memo, *cleared, category);
            let mut out = vec![edit(
                Kind::Transaction,
                t.id,
                with(&c, json!({ "amount": sign * amount })),
            )];
            if let Some(p) = live.partner(t) {
                out.push(edit(
                    Kind::Transaction,
                    p.id,
                    with(&c, json!({ "amount": -sign * amount })),
                ));
            }
            Ok(out)
        }

        Command::RemoveTransaction { id } => {
            let t = live.transaction(*id)?;
            let mut out = vec![remove(Kind::Transaction, t.id)];
            if let Some(p) = live.partner(t) {
                out.push(remove(Kind::Transaction, p.id));
            }
            Ok(out)
        }

        Command::MoveCategoryTransactions {
            category_id,
            target,
        } => {
            if category_id == target || live.get(Kind::Category, *target).is_none() {
                return Err("Pick another category to move the transactions to.".into());
            }
            let mut out = vec![];
            for t in live.in_category(*category_id) {
                let lines = splits(t);
                if lines.is_empty() {
                    out.push(edit(
                        Kind::Transaction,
                        t.id,
                        json!({ "category_id": target }),
                    ));
                    continue;
                }
                let moved: Vec<Value> = lines
                    .iter()
                    .map(|l| {
                        let mut l = l.clone();
                        if line_category(&l) == Some(*category_id) {
                            l["category_id"] = json!(target);
                        }
                        l
                    })
                    .collect();
                out.push(edit(Kind::Transaction, t.id, json!({ "splits": moved })));
            }
            live.drop_category(*category_id, &mut out);
            Ok(out)
        }

        Command::DeleteCategoryTransactions { category_id } => {
            let mut out = vec![];
            let mut gone = HashSet::new();
            for t in live.in_category(*category_id) {
                let lines = splits(t);
                if lines.is_empty() {
                    // Both legs of a transfer can carry the category; delete each once.
                    for e in [Some(t), live.partner(t)].into_iter().flatten() {
                        if gone.insert(e.id) {
                            out.push(remove(Kind::Transaction, e.id));
                        }
                    }
                    continue;
                }
                // Only the lines in this category go. The rest of the split stays.
                let keep: Vec<&Value> = lines
                    .iter()
                    .filter(|l| line_category(l) != Some(*category_id))
                    .collect();
                if keep.is_empty() {
                    out.push(remove(Kind::Transaction, t.id));
                    continue;
                }
                let amount: i64 = keep
                    .iter()
                    .map(|l| l.get("amount").and_then(Value::as_i64).unwrap_or(0))
                    .sum();
                out.push(edit(
                    Kind::Transaction,
                    t.id,
                    json!({ "splits": keep, "amount": amount }),
                ));
            }
            live.drop_category(*category_id, &mut out);
            Ok(out)
        }

        Command::DeleteEmptyCategory { category_id } => {
            let mut out = vec![];
            live.drop_category(*category_id, &mut out);
            Ok(out)
        }
    }
}

#[cfg(test)]
mod tests {
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
    fn unknown_command_is_an_error() {
        assert!(serde_json::from_value::<Command>(json!({"command": "nope"})).is_err());
    }
}
