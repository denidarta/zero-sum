//! Entity types. Money is `i64` milliunits (1000 = 1.00), like YNAB.
//!
//! Every struct denies unknown fields so a typo in a client patch is rejected
//! instead of silently stored.

use serde::{de::DeserializeOwned, Deserialize, Serialize};
use serde_json::{Map, Value};
use std::str::FromStr;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Account,
    CategoryGroup,
    Category,
    Payee,
    Transaction,
    BudgetEntry,
}

impl Kind {
    pub fn as_str(self) -> &'static str {
        match self {
            Kind::Account => "account",
            Kind::CategoryGroup => "category_group",
            Kind::Category => "category",
            Kind::Payee => "payee",
            Kind::Transaction => "transaction",
            Kind::BudgetEntry => "budget_entry",
        }
    }
}

impl FromStr for Kind {
    type Err = String;
    /// Same names as the serde rename, so a new kind needs no edit here.
    fn from_str(s: &str) -> Result<Self, String> {
        serde_json::from_value(Value::String(s.into())).map_err(|_| format!("unknown kind {s:?}"))
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum AccountKind {
    Checking,
    Savings,
    Cash,
    CreditCard,
    LineOfCredit,
    Other,
}

fn yes() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Account {
    pub name: String,
    pub kind: AccountKind,
    /// Off-budget (tracking) accounts never affect the budget.
    #[serde(default = "yes")]
    pub on_budget: bool,
    #[serde(default)]
    pub closed: bool,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct CategoryGroup {
    pub name: String,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub sort: i64,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Category {
    pub group_id: Uuid,
    pub name: String,
    #[serde(default)]
    pub hidden: bool,
    #[serde(default)]
    pub sort: i64,
    #[serde(default)]
    pub note: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Payee {
    pub name: String,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Transaction {
    pub account_id: Uuid,
    /// `YYYY-MM-DD`, local date of the transaction.
    pub date: String,
    /// Inflow positive, outflow negative, milliunits.
    pub amount: i64,
    #[serde(default)]
    pub payee_id: Option<Uuid>,
    /// `None` on an inflow means income into Ready to Assign.
    #[serde(default)]
    pub category_id: Option<Uuid>,
    /// Set on each leg of a transfer: the account on the other side.
    #[serde(default)]
    pub transfer_account_id: Option<Uuid>,
    /// Set on each leg of a transfer: the id of the other leg.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transfer_transaction_id: Option<Uuid>,
    /// Category lines of a split. Empty for an unsplit transaction. The line
    /// amounts must sum to `amount`. One field, so concurrent edits merge whole.
    #[serde(default, skip_serializing_if = "Vec::is_empty")]
    pub splits: Vec<Split>,
    #[serde(default)]
    pub memo: Option<String>,
    #[serde(default)]
    pub cleared: bool,
}

/// One category line of a split transaction. Lines are never transfers.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Split {
    pub category_id: Uuid,
    pub amount: i64,
    #[serde(default)]
    pub memo: Option<String>,
}

/// Money assigned to one category in one month.
///
/// The entity id is derived from `(category_id, month)` so two devices that
/// create the entry offline converge on the same entity. See [`budget_entry_id`].
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct BudgetEntry {
    pub category_id: Uuid,
    /// `YYYY-MM`.
    pub month: String,
    pub assigned: i64,
}

const BUDGET_ENTRY_NAMESPACE: Uuid = Uuid::from_u128(0x7a65_726f_2d73_756d_8000_0000_0000_0001);

/// Deterministic id for the budget entry of a category in a month.
pub fn budget_entry_id(category_id: Uuid, month: &str) -> Uuid {
    Uuid::new_v5(
        &BUDGET_ENTRY_NAMESPACE,
        format!("{category_id}:{month}").as_bytes(),
    )
}

pub fn parse_data<T: DeserializeOwned>(data: &Map<String, Value>) -> Result<T, String> {
    serde_json::from_value(Value::Object(data.clone())).map_err(|e| e.to_string())
}

/// Parse `YYYY-MM-DD` into `(year, month, day)`.
pub fn parse_date(s: &str) -> Option<(i32, u32, u32)> {
    let b = s.as_bytes();
    if b.len() != 10 || b[4] != b'-' || b[7] != b'-' {
        return None;
    }
    let y: i32 = s.get(0..4)?.parse().ok()?;
    let m: u32 = s.get(5..7)?.parse().ok()?;
    let d: u32 = s.get(8..10)?.parse().ok()?;
    ((1..=12).contains(&m) && (1..=31).contains(&d)).then_some((y, m, d))
}

/// Parse `YYYY-MM` into `(year, month)`.
pub fn parse_month(s: &str) -> Option<(i32, u32)> {
    let b = s.as_bytes();
    if b.len() != 7 || b[4] != b'-' {
        return None;
    }
    let y: i32 = s.get(0..4)?.parse().ok()?;
    let m: u32 = s.get(5..7)?.parse().ok()?;
    (1..=12).contains(&m).then_some((y, m))
}

/// Check that `data` is a complete, well-formed entity of `kind` with the given `id`.
pub fn validate(kind: Kind, id: Uuid, data: &Map<String, Value>) -> Result<(), String> {
    match kind {
        Kind::Account => parse_data::<Account>(data).map(drop),
        Kind::CategoryGroup => parse_data::<CategoryGroup>(data).map(drop),
        Kind::Category => parse_data::<Category>(data).map(drop),
        Kind::Payee => parse_data::<Payee>(data).map(drop),
        Kind::Transaction => {
            let t: Transaction = parse_data(data)?;
            parse_date(&t.date).ok_or_else(|| format!("bad date {:?}, want YYYY-MM-DD", t.date))?;
            if t.transfer_transaction_id.is_some() && t.transfer_account_id.is_none() {
                return Err("transfer_transaction_id needs transfer_account_id".into());
            }
            if !t.splits.is_empty() {
                if t.transfer_account_id.is_some() {
                    return Err("a transfer cannot be split".into());
                }
                if t.category_id.is_some() {
                    return Err("a split transaction has no category of its own".into());
                }
                let sum = t
                    .splits
                    .iter()
                    .try_fold(0i64, |a, l| a.checked_add(l.amount));
                if sum != Some(t.amount) {
                    return Err(format!("split lines must sum to amount {}", t.amount));
                }
            }
            Ok(())
        }
        Kind::BudgetEntry => {
            let e: BudgetEntry = parse_data(data)?;
            parse_month(&e.month)
                .ok_or_else(|| format!("bad month {:?}, want YYYY-MM", e.month))?;
            let want = budget_entry_id(e.category_id, &e.month);
            if id != want {
                return Err(format!(
                    "budget_entry id must be {want} for this category and month"
                ));
            }
            Ok(())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn check(extra: Value) -> Result<(), String> {
        let mut data = json!({
            "account_id": "00000000-0000-4000-8000-000000000001",
            "date": "2026-10-05",
            "amount": -300,
        });
        data.as_object_mut()
            .unwrap()
            .extend(extra.as_object().unwrap().clone());
        validate(Kind::Transaction, Uuid::nil(), data.as_object().unwrap())
    }

    fn line(n: u8, amount: i64) -> Value {
        json!({"category_id": format!("00000000-0000-4000-8000-0000000000{n:02}"), "amount": amount})
    }

    #[test]
    fn split_lines_must_sum_to_amount() {
        assert!(check(json!({"splits": [line(10, -100), line(11, -200)]})).is_ok());
        assert!(check(json!({"splits": [line(10, -100), line(11, -100)]})).is_err());
    }

    #[test]
    fn split_excludes_category_and_transfer() {
        let s = json!([line(10, -300)]);
        assert!(
            check(json!({"splits": s, "category_id": "00000000-0000-4000-8000-000000000010"}))
                .is_err()
        );
        assert!(check(
            json!({"splits": s, "transfer_account_id": "00000000-0000-4000-8000-000000000002"})
        )
        .is_err());
    }

    #[test]
    fn transfer_partner_needs_transfer_account() {
        let partner = "00000000-0000-4000-8000-000000000077";
        assert!(check(json!({"transfer_transaction_id": partner})).is_err());
        assert!(check(json!({
            "transfer_transaction_id": partner,
            "transfer_account_id": "00000000-0000-4000-8000-000000000002",
        }))
        .is_ok());
    }
}
