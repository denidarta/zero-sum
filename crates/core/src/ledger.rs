//! Ledger edit rules: transfers (two linked transactions), deleting transactions and
//! categories, trimming split lines. Spec: `docs/ledger-edits-spec.md`.
//!
//! [`plan`] turns one user action into patches. A client applies each patch with the
//! edit call it already has, so the outbox and sync do not change. Every client runs
//! the same plan, so the rules cannot drift between them.

use crate::{
    model::{parse_data, Account, Kind},
    sync::EntityState,
};
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
    /// D1: remove a group. Fails while it still has live categories.
    DeleteGroup { group_id: Uuid },
    /// Match an account to the real money. `balance` is what the account really holds.
    /// The plan is one adjustment transaction (`id`) for the difference, or nothing when
    /// the balances already match. Its amount is the delta, so a client can preview the
    /// delta by planning without applying. `category_id` is only kept for an on-budget
    /// account; without it the adjustment is income (inflow) or Ready to Assign spending.
    ReconcileAccount {
        id: Uuid,
        account_id: Uuid,
        balance: i64,
        date: String,
        #[serde(default)]
        category_id: Option<Uuid>,
    },
}

pub const ADJUSTMENT_MEMO: &str = "Reconciliation Balance Adjustment";

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

    /// An account counts as on budget when it exists and its typed `on_budget` is set,
    /// the same reading `budget::compute` uses.
    fn on_budget(&self, id: Uuid) -> bool {
        self.get(Kind::Account, id)
            .is_some_and(|a| parse_data::<Account>(&a.data).is_ok_and(|a| a.on_budget))
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

    /// What the ledger says an account holds: the sum of its live transactions.
    fn balance(&self, account: Uuid) -> i64 {
        self.of_kind(Kind::Transaction)
            .filter(|t| uuid_field(t, "account_id") == Some(account))
            .filter_map(|t| t.data.get("amount")?.as_i64())
            .sum()
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

        Command::DeleteGroup { group_id } => {
            let group = live
                .get(Kind::CategoryGroup, *group_id)
                .ok_or("group not found")?;
            let has_categories = live
                .of_kind(Kind::Category)
                .any(|c| uuid_field(c, "group_id") == Some(*group_id));
            if has_categories {
                let name = group.data.get("name").and_then(Value::as_str);
                return Err(format!(
                    "Move or delete the categories in {} first.",
                    name.unwrap_or("this group")
                ));
            }
            Ok(vec![remove(Kind::CategoryGroup, *group_id)])
        }

        Command::ReconcileAccount {
            id,
            account_id,
            balance,
            date,
            category_id,
        } => {
            live.get(Kind::Account, *account_id)
                .ok_or("account not found")?;
            let delta = balance
                .checked_sub(live.balance(*account_id))
                .ok_or("balance out of range")?;
            if delta == 0 {
                return Ok(vec![]);
            }
            let category = category_id.filter(|_| live.on_budget(*account_id));
            Ok(vec![edit(
                Kind::Transaction,
                *id,
                json!({
                    "account_id": account_id, "date": date, "amount": delta,
                    "category_id": category, "memo": ADJUSTMENT_MEMO, "cleared": true,
                }),
            )])
        }
    }
}

#[cfg(test)]
mod tests;
