//! Envelope budget math. Pure functions over a snapshot of live entities.
//!
//! Rules (simplified YNAB):
//! - Only transactions in on-budget accounts count.
//! - A transfer between two on-budget accounts is ignored.
//! - An uncategorized transaction is income into Ready to Assign.
//! - `available = carry-in + assigned + activity`.
//! - Positive available carries to the next month. Negative available resets
//!   to 0 and is subtracted from the next month's Ready to Assign.
//! - Credit-card payment categories are not modelled yet.

use crate::model::{parse_date, parse_month, Account, BudgetEntry, Category, Transaction};
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    pub accounts: Vec<(Uuid, Account)>,
    pub categories: Vec<(Uuid, Category)>,
    pub transactions: Vec<Transaction>,
    pub entries: Vec<BudgetEntry>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CategoryMonth {
    pub category_id: Uuid,
    pub assigned: i64,
    pub activity: i64,
    pub available: i64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct BudgetMonth {
    pub month: String,
    pub ready_to_assign: i64,
    pub categories: Vec<CategoryMonth>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, PartialOrd, Ord)]
struct Ym(i32, u32);

impl Ym {
    fn parse(s: &str) -> Option<Ym> {
        parse_month(s).map(|(y, m)| Ym(y, m))
    }
    fn of_date(s: &str) -> Option<Ym> {
        parse_date(s).map(|(y, m, _)| Ym(y, m))
    }
    fn next(self) -> Ym {
        if self.1 == 12 {
            Ym(self.0 + 1, 1)
        } else {
            Ym(self.0, self.1 + 1)
        }
    }
}

pub fn compute(snap: &Snapshot, month: &str) -> Result<BudgetMonth, String> {
    let target = Ym::parse(month).ok_or_else(|| format!("bad month {month:?}, want YYYY-MM"))?;

    let on_budget: HashSet<Uuid> = snap
        .accounts
        .iter()
        .filter(|(_, a)| a.on_budget)
        .map(|(id, _)| *id)
        .collect();
    let mut cats: Vec<Uuid> = snap.categories.iter().map(|(id, _)| *id).collect();
    cats.sort();
    let cat_set: HashSet<Uuid> = cats.iter().copied().collect();

    let mut assigned: HashMap<(Uuid, Ym), i64> = HashMap::new();
    let mut activity: HashMap<(Uuid, Ym), i64> = HashMap::new();
    let mut income: HashMap<Ym, i64> = HashMap::new();
    let mut start = target;

    for e in &snap.entries {
        let m = Ym::parse(&e.month).ok_or("entry with bad month")?;
        if cat_set.contains(&e.category_id) {
            *assigned.entry((e.category_id, m)).or_default() += e.assigned;
            start = start.min(m);
        }
    }
    for t in &snap.transactions {
        if !on_budget.contains(&t.account_id) {
            continue;
        }
        if t.transfer_account_id
            .is_some_and(|to| on_budget.contains(&to))
        {
            continue;
        }
        let m = Ym::of_date(&t.date).ok_or("transaction with bad date")?;
        match t.category_id {
            Some(c) if cat_set.contains(&c) => *activity.entry((c, m)).or_default() += t.amount,
            Some(_) => continue, // category deleted
            None => *income.entry(m).or_default() += t.amount,
        }
        start = start.min(m);
    }

    let mut carry: HashMap<Uuid, i64> = HashMap::new();
    let (mut income_cum, mut assigned_cum, mut overspent_before) = (0i64, 0i64, 0i64);
    let mut m = start;
    loop {
        let mut rows = Vec::with_capacity(cats.len());
        let mut overspent = 0i64;
        income_cum += income.get(&m).copied().unwrap_or(0);
        for &c in &cats {
            let a = assigned.get(&(c, m)).copied().unwrap_or(0);
            let act = activity.get(&(c, m)).copied().unwrap_or(0);
            let available = carry.get(&c).copied().unwrap_or(0) + a + act;
            assigned_cum += a;
            if available < 0 {
                overspent -= available;
                carry.insert(c, 0);
            } else {
                carry.insert(c, available);
            }
            rows.push(CategoryMonth {
                category_id: c,
                assigned: a,
                activity: act,
                available,
            });
        }
        if m == target {
            return Ok(BudgetMonth {
                month: month.to_string(),
                ready_to_assign: income_cum - assigned_cum - overspent_before,
                categories: rows,
            });
        }
        overspent_before += overspent;
        m = m.next();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::AccountKind;

    fn id(n: u128) -> Uuid {
        Uuid::from_u128(n)
    }

    fn snap() -> Snapshot {
        let acct = |on_budget| Account {
            name: "a".into(),
            kind: AccountKind::Checking,
            on_budget,
            closed: false,
            note: None,
        };
        let cat = |name: &str| Category {
            group_id: id(500),
            name: name.into(),
            hidden: false,
            sort: 0,
            note: None,
        };
        Snapshot {
            accounts: vec![
                (id(1), acct(true)),
                (id(2), acct(true)),
                (id(3), acct(false)),
            ],
            categories: vec![(id(10), cat("Rent")), (id(11), cat("Food"))],
            ..Default::default()
        }
    }

    fn tx(account: u128, date: &str, amount: i64, category: Option<u128>) -> Transaction {
        Transaction {
            account_id: id(account),
            date: date.into(),
            amount,
            payee_id: None,
            category_id: category.map(id),
            transfer_account_id: None,
            memo: None,
            cleared: false,
        }
    }

    fn entry(cat: u128, month: &str, assigned: i64) -> BudgetEntry {
        BudgetEntry {
            category_id: id(cat),
            month: month.into(),
            assigned,
        }
    }

    fn row(b: &BudgetMonth, cat: u128) -> &CategoryMonth {
        b.categories
            .iter()
            .find(|c| c.category_id == id(cat))
            .unwrap()
    }

    #[test]
    fn income_assign_spend() {
        let mut s = snap();
        s.transactions = vec![
            tx(1, "2026-10-01", 3_000_000, None),
            tx(1, "2026-10-05", -400_000, Some(11)),
        ];
        s.entries = vec![
            entry(10, "2026-10", 1_000_000),
            entry(11, "2026-10", 500_000),
        ];
        let b = compute(&s, "2026-10").unwrap();
        assert_eq!(b.ready_to_assign, 1_500_000);
        assert_eq!(row(&b, 10).available, 1_000_000);
        assert_eq!(row(&b, 11).activity, -400_000);
        assert_eq!(row(&b, 11).available, 100_000);
    }

    #[test]
    fn positive_available_carries_over() {
        let mut s = snap();
        s.transactions = vec![tx(1, "2026-09-01", 1_000_000, None)];
        s.entries = vec![entry(11, "2026-09", 300_000), entry(11, "2026-10", 200_000)];
        let b = compute(&s, "2026-10").unwrap();
        assert_eq!(row(&b, 11).available, 500_000);
        assert_eq!(b.ready_to_assign, 500_000);
    }

    #[test]
    fn overspending_resets_and_reduces_next_month_rta() {
        let mut s = snap();
        s.transactions = vec![
            tx(1, "2026-09-01", 1_000_000, None),
            tx(1, "2026-09-10", -150_000, Some(11)),
        ];
        s.entries = vec![entry(11, "2026-09", 100_000)];
        let sep = compute(&s, "2026-09").unwrap();
        assert_eq!(row(&sep, 11).available, -50_000);
        assert_eq!(sep.ready_to_assign, 900_000);
        let oct = compute(&s, "2026-10").unwrap();
        assert_eq!(row(&oct, 11).available, 0);
        assert_eq!(oct.ready_to_assign, 850_000);
    }

    #[test]
    fn off_budget_and_on_budget_transfers_are_ignored() {
        let mut s = snap();
        let mut transfer = tx(1, "2026-10-02", -200_000, None);
        transfer.transfer_account_id = Some(id(2));
        s.transactions = vec![
            tx(1, "2026-10-01", 1_000_000, None),
            tx(3, "2026-10-01", 9_999_000, None),
            transfer,
        ];
        let b = compute(&s, "2026-10").unwrap();
        assert_eq!(b.ready_to_assign, 1_000_000);
    }

    #[test]
    fn rejects_bad_month() {
        assert!(compute(&snap(), "2026-13").is_err());
    }
}
