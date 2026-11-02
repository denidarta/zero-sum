//! Envelope budget math. Pure functions over a snapshot of live entities.
//!
//! Rules (simplified YNAB):
//! - Only transactions in on-budget accounts count.
//! - A transfer between two on-budget accounts is ignored.
//! - An uncategorized transaction is income into Ready to Assign.
//! - `available = carry-in + assigned + activity`.
//! - Positive available carries to the next month. Negative available resets
//!   to 0 and is subtracted from the next month's Ready to Assign.
//! - A transaction whose category is deleted counts as uncategorized, so
//!   spending is never dropped. Split lines are attributed one by one.
//! - A category whose group is missing or deleted is reported as orphaned so
//!   clients can still show its money.
//! - Each on-budget credit card has a payment category (`card_payments`, id from
//!   `card_payment_id`). Card spending in a category moves that much into the card's
//!   row, and a transfer into the card from an on-budget account draws it down. Money
//!   can be assigned to the row with an ordinary budget entry.
//! - Overspending covered by card spending ("credit overspending") resets the category
//!   but leaves Ready to Assign alone. The card's row is short by that amount instead.
//!   Only the rest is cash overspending. A negative card row resets and reduces the
//!   next month's Ready to Assign. Spec: `docs/superpowers/specs/2026-11-01-credit-card-payment-categories-design.md`.

use crate::model::{
    card_payment_id, parse_data, parse_date, parse_month, Account, AccountKind, BudgetEntry,
    Category, Kind, Transaction,
};
use crate::sync::EntityState;
use serde::{Deserialize, Serialize};
use std::collections::{HashMap, HashSet};
use uuid::Uuid;

#[derive(Debug, Clone, Default)]
pub struct Snapshot {
    pub accounts: Vec<(Uuid, Account)>,
    /// Ids of live category groups.
    pub groups: Vec<Uuid>,
    pub categories: Vec<(Uuid, Category)>,
    pub transactions: Vec<Transaction>,
    pub entries: Vec<BudgetEntry>,
}

impl Snapshot {
    /// Collect the live (not deleted) entities that budget math needs.
    pub fn from_entities<'a>(
        entities: impl IntoIterator<Item = &'a EntityState>,
    ) -> Result<Snapshot, String> {
        let mut snap = Snapshot::default();
        for e in entities.into_iter().filter(|e| !e.deleted) {
            match e.kind {
                Kind::Account => snap.accounts.push((e.id, parse_data(&e.data)?)),
                Kind::Category => snap.categories.push((e.id, parse_data(&e.data)?)),
                Kind::Transaction => snap.transactions.push(parse_data(&e.data)?),
                Kind::BudgetEntry => snap.entries.push(parse_data(&e.data)?),
                Kind::CategoryGroup => snap.groups.push(e.id),
                Kind::Payee => {}
            }
        }
        Ok(snap)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CategoryMonth {
    pub category_id: Uuid,
    pub assigned: i64,
    pub activity: i64,
    pub available: i64,
}

/// The payment category of one credit card. `category_id` is [`card_payment_id`] of the account.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct CardPaymentMonth {
    pub account_id: Uuid,
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
    /// Live categories whose group is missing or deleted, sorted by id.
    #[serde(default)]
    pub orphaned_category_ids: Vec<Uuid>,
    /// One row per on-budget credit card, sorted by account id.
    #[serde(default)]
    pub card_payments: Vec<CardPaymentMonth>,
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
    let group_set: HashSet<Uuid> = snap.groups.iter().copied().collect();
    let orphaned: Vec<Uuid> = cats
        .iter()
        .copied()
        .filter(|c| {
            snap.categories
                .iter()
                .any(|(id, cat)| id == c && !group_set.contains(&cat.group_id))
        })
        .collect();
    let cat_set: HashSet<Uuid> = cats.iter().copied().collect();
    let mut cards: Vec<(Uuid, bool)> = snap
        .accounts
        .iter()
        .filter(|(_, a)| a.on_budget && a.kind == AccountKind::CreditCard)
        .map(|(id, a)| (*id, a.closed))
        .collect();
    cards.sort();
    let card_ids: HashSet<Uuid> = cards.iter().map(|(id, _)| *id).collect();
    let card_by_payment_id: HashMap<Uuid, Uuid> = cards
        .iter()
        .map(|(id, _)| (card_payment_id(*id), *id))
        .collect();

    let mut assigned: HashMap<(Uuid, Ym), i64> = HashMap::new();
    let mut activity: HashMap<(Uuid, Ym), i64> = HashMap::new();
    let mut income: HashMap<Ym, i64> = HashMap::new();
    let mut card_assigned: HashMap<(Uuid, Ym), i64> = HashMap::new();
    let mut card_spend: HashMap<(Uuid, Uuid, Ym), i64> = HashMap::new();
    let mut card_paid: HashMap<(Uuid, Ym), i64> = HashMap::new();
    let mut start = target;

    for e in &snap.entries {
        let m = Ym::parse(&e.month).ok_or("entry with bad month")?;
        if cat_set.contains(&e.category_id) {
            *assigned.entry((e.category_id, m)).or_default() += e.assigned;
            start = start.min(m);
        } else if let Some(&card) = card_by_payment_id.get(&e.category_id) {
            *card_assigned.entry((card, m)).or_default() += e.assigned;
            start = start.min(m);
        }
    }
    for t in &snap.transactions {
        if !on_budget.contains(&t.account_id) {
            continue;
        }
        let is_card = card_ids.contains(&t.account_id);
        // A payment: money into the card from an on-budget account that is not a card.
        // A balance transfer between cards moves debt, it does not pay it.
        if is_card
            && t.amount > 0
            && t.transfer_account_id
                .is_some_and(|f| on_budget.contains(&f) && !card_ids.contains(&f))
        {
            let m = Ym::of_date(&t.date).ok_or("transaction with bad date")?;
            *card_paid.entry((t.account_id, m)).or_default() += t.amount;
            start = start.min(m);
        }
        if t.transfer_account_id
            .is_some_and(|to| on_budget.contains(&to))
        {
            continue;
        }
        let m = Ym::of_date(&t.date).ok_or("transaction with bad date")?;
        let lines: Vec<(Option<Uuid>, i64)> = if t.splits.is_empty() {
            vec![(t.category_id, t.amount)]
        } else {
            t.splits
                .iter()
                .map(|l| (Some(l.category_id), l.amount))
                .collect()
        };
        for (cat, amount) in lines {
            match cat {
                Some(c) if cat_set.contains(&c) => {
                    *activity.entry((c, m)).or_default() += amount;
                    if is_card {
                        *card_spend.entry((c, t.account_id, m)).or_default() -= amount;
                    }
                }
                // Card debt with no category (opening balance, fees): unfunded. It reaches
                // Ready to Assign once, when the card is paid and its row goes negative.
                _ if is_card && t.transfer_account_id.is_none() && amount < 0 => {}
                // Uncategorized, or its category was deleted: counts against Ready to Assign.
                _ => *income.entry(m).or_default() += amount,
            }
        }
        start = start.min(m);
    }

    let mut carry: HashMap<Uuid, i64> = HashMap::new();
    let mut card_carry: HashMap<Uuid, i64> = HashMap::new();
    let (mut income_cum, mut assigned_cum, mut overspent_before) = (0i64, 0i64, 0i64);
    let mut m = start;
    loop {
        let mut rows = Vec::with_capacity(cats.len());
        let mut overspent = 0i64;
        // Credit overspending each card's payment category is short this month.
        let mut credit_share: HashMap<Uuid, i64> = HashMap::new();
        income_cum += income.get(&m).copied().unwrap_or(0);
        for &c in &cats {
            let a = assigned.get(&(c, m)).copied().unwrap_or(0);
            let act = activity.get(&(c, m)).copied().unwrap_or(0);
            let available = carry.get(&c).copied().unwrap_or(0) + a + act;
            assigned_cum += a;
            if available < 0 {
                // Overspending covered by card spending leaves Ready to Assign alone: the
                // card's payment category is short instead. Only the rest is cash overspending.
                let mut spend: Vec<(i64, Uuid)> = cards
                    .iter()
                    .map(|&(card, _)| (card_spend.get(&(c, card, m)).copied().unwrap_or(0), card))
                    .collect();
                let total: i64 = spend.iter().map(|(s, _)| s).sum();
                let mut credit = (-available).min(total).max(0);
                overspent += -available - credit;
                spend.sort_by(|x, y| y.0.cmp(&x.0).then(x.1.cmp(&y.1)));
                for (s, card) in spend.into_iter().filter(|(s, _)| *s > 0) {
                    let take = s.min(credit);
                    *credit_share.entry(card).or_default() += take;
                    credit -= take;
                }
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
        let mut card_rows = Vec::new();
        for &(card, closed) in &cards {
            let a = card_assigned.get(&(card, m)).copied().unwrap_or(0);
            let moved_in: i64 = cats
                .iter()
                .map(|&c| card_spend.get(&(c, card, m)).copied().unwrap_or(0))
                .sum();
            let act = moved_in
                - credit_share.get(&card).copied().unwrap_or(0)
                - card_paid.get(&(card, m)).copied().unwrap_or(0);
            let available = card_carry.get(&card).copied().unwrap_or(0) + a + act;
            assigned_cum += a;
            if available < 0 {
                overspent -= available;
                card_carry.insert(card, 0);
            } else {
                card_carry.insert(card, available);
            }
            if !(closed && a == 0 && act == 0 && available == 0) {
                card_rows.push(CardPaymentMonth {
                    account_id: card,
                    category_id: card_payment_id(card),
                    assigned: a,
                    activity: act,
                    available,
                });
            }
        }
        if m == target {
            return Ok(BudgetMonth {
                month: month.to_string(),
                ready_to_assign: income_cum - assigned_cum - overspent_before,
                categories: rows,
                orphaned_category_ids: orphaned,
                card_payments: card_rows,
            });
        }
        overspent_before += overspent;
        m = m.next();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::model::{card_payment_id, AccountKind, Split};

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
            groups: vec![id(500)],
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
            transfer_transaction_id: None,
            splits: vec![],
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
    fn deleted_category_transactions_count_as_uncategorized() {
        let mut s = snap();
        s.transactions = vec![
            tx(1, "2026-10-01", 1_000_000, None),
            tx(1, "2026-10-02", -200_000, Some(99)), // category 99 is deleted
        ];
        let b = compute(&s, "2026-10").unwrap();
        assert_eq!(b.ready_to_assign, 800_000);
    }

    #[test]
    fn split_lines_hit_their_categories() {
        let mut s = snap();
        let mut split = tx(1, "2026-10-05", -300_000, None);
        split.splits = vec![
            Split {
                category_id: id(10),
                amount: -100_000,
                memo: None,
            },
            Split {
                category_id: id(11),
                amount: -200_000,
                memo: None,
            },
        ];
        s.transactions = vec![tx(1, "2026-10-01", 1_000_000, None), split];
        let b = compute(&s, "2026-10").unwrap();
        assert_eq!(row(&b, 10).activity, -100_000);
        assert_eq!(row(&b, 11).activity, -200_000);
        assert_eq!(b.ready_to_assign, 1_000_000);
    }

    #[test]
    fn categories_without_a_live_group_are_orphaned() {
        let mut s = snap();
        s.groups.clear();
        let b = compute(&s, "2026-10").unwrap();
        assert_eq!(b.orphaned_category_ids, vec![id(10), id(11)]);
        assert!(compute(&snap(), "2026-10")
            .unwrap()
            .orphaned_category_ids
            .is_empty());
    }

    fn card_account(closed: bool) -> Account {
        Account {
            name: "card".into(),
            kind: AccountKind::CreditCard,
            on_budget: true,
            closed,
            note: None,
        }
    }

    fn snap_with_card() -> Snapshot {
        let mut s = snap();
        s.accounts.push((id(4), card_account(false)));
        s
    }

    fn card_row(b: &BudgetMonth, account: u128) -> &CardPaymentMonth {
        b.card_payments
            .iter()
            .find(|c| c.account_id == id(account))
            .unwrap()
    }

    /// Both legs of a transfer from `from` to `to`.
    fn transfer(from: u128, to: u128, date: &str, amount: i64) -> Vec<Transaction> {
        let mut out = tx(from, date, -amount, None);
        out.transfer_account_id = Some(id(to));
        let mut inn = tx(to, date, amount, None);
        inn.transfer_account_id = Some(id(from));
        vec![out, inn]
    }

    /// Income 1000, 500 assigned to cat 11 in 2026-10.
    fn funded_card_snap() -> Snapshot {
        let mut s = snap_with_card();
        s.transactions = vec![tx(1, "2026-10-01", 1_000_000, None)];
        s.entries = vec![entry(11, "2026-10", 500_000)];
        s
    }

    #[test]
    fn card_spend_moves_to_payment() {
        let mut s = funded_card_snap();
        s.transactions.push(tx(4, "2026-10-05", -200_000, Some(11)));
        let b = compute(&s, "2026-10").unwrap();
        assert_eq!(row(&b, 11).activity, -200_000);
        assert_eq!(row(&b, 11).available, 300_000);
        let c = card_row(&b, 4);
        assert_eq!(c.category_id, card_payment_id(id(4)));
        assert_eq!((c.assigned, c.activity, c.available), (0, 200_000, 200_000));
        assert_eq!(b.ready_to_assign, 500_000);
    }

    #[test]
    fn payment_draws_the_row_down() {
        let mut s = funded_card_snap();
        s.transactions.push(tx(4, "2026-10-05", -200_000, Some(11)));
        s.transactions.extend(transfer(1, 4, "2026-10-20", 150_000));
        let b = compute(&s, "2026-10").unwrap();
        assert_eq!(card_row(&b, 4).activity, 50_000);
        assert_eq!(b.ready_to_assign, 500_000);
    }

    #[test]
    fn card_refund_reduces_the_row() {
        let mut s = funded_card_snap();
        s.transactions.push(tx(4, "2026-10-05", -200_000, Some(11)));
        s.transactions.push(tx(4, "2026-10-06", 50_000, Some(11)));
        let b = compute(&s, "2026-10").unwrap();
        assert_eq!(card_row(&b, 4).activity, 150_000);
    }

    #[test]
    fn assigning_to_the_payment_category() {
        let mut s = funded_card_snap();
        s.transactions.push(tx(4, "2026-10-05", -200_000, Some(11)));
        s.entries.push(BudgetEntry {
            category_id: card_payment_id(id(4)),
            month: "2026-10".into(),
            assigned: 100_000,
        });
        let b = compute(&s, "2026-10").unwrap();
        let c = card_row(&b, 4);
        assert_eq!((c.assigned, c.available), (100_000, 300_000));
        assert_eq!(b.ready_to_assign, 400_000);
    }

    #[test]
    fn entry_for_a_non_card_payment_id_is_ignored() {
        let mut s = funded_card_snap();
        s.entries.push(BudgetEntry {
            category_id: card_payment_id(id(9)),
            month: "2026-10".into(),
            assigned: 100_000,
        });
        let b = compute(&s, "2026-10").unwrap();
        assert_eq!(b.ready_to_assign, 500_000);
        assert_eq!(b.card_payments.len(), 1);
    }

    #[test]
    fn payment_row_carries_to_next_month() {
        let mut s = snap_with_card();
        s.transactions = vec![
            tx(1, "2026-09-01", 1_000_000, None),
            tx(4, "2026-09-05", -200_000, Some(11)),
        ];
        s.entries = vec![entry(11, "2026-09", 500_000)];
        let b = compute(&s, "2026-10").unwrap();
        assert_eq!(card_row(&b, 4).available, 200_000);
    }

    #[test]
    fn payment_above_available_resets_and_hits_rta() {
        let mut s = snap_with_card();
        s.transactions = vec![
            tx(1, "2026-09-01", 1_000_000, None),
            tx(4, "2026-09-05", -100_000, Some(11)),
        ];
        s.transactions.extend(transfer(1, 4, "2026-09-20", 150_000));
        s.entries = vec![entry(11, "2026-09", 300_000)];
        let sep = compute(&s, "2026-09").unwrap();
        assert_eq!(card_row(&sep, 4).available, -50_000);
        assert_eq!(sep.ready_to_assign, 700_000);
        let oct = compute(&s, "2026-10").unwrap();
        assert_eq!(card_row(&oct, 4).available, 0);
        assert_eq!(oct.ready_to_assign, 650_000);
    }

    #[test]
    fn closed_card_row_only_while_nonzero() {
        let mut s = snap();
        s.accounts.push((id(4), card_account(true)));
        assert!(compute(&s, "2026-10").unwrap().card_payments.is_empty());
        s.transactions = vec![
            tx(1, "2026-09-01", 1_000_000, None),
            tx(4, "2026-09-05", -100_000, Some(11)),
        ];
        s.entries = vec![entry(11, "2026-09", 500_000)];
        let b = compute(&s, "2026-10").unwrap();
        assert_eq!(card_row(&b, 4).available, 100_000);
    }

    #[test]
    fn non_card_kinds_get_no_row() {
        assert!(compute(&snap(), "2026-10")
            .unwrap()
            .card_payments
            .is_empty());
    }

    fn sep_card_snap(entry_amount: i64) -> Snapshot {
        let mut s = snap_with_card();
        s.transactions = vec![tx(1, "2026-09-01", 1_000_000, None)];
        s.entries = vec![entry(11, "2026-09", entry_amount)];
        s
    }

    #[test]
    fn credit_overspending_leaves_rta_alone() {
        let mut s = sep_card_snap(100_000);
        s.transactions.push(tx(4, "2026-09-10", -150_000, Some(11)));
        let sep = compute(&s, "2026-09").unwrap();
        assert_eq!(row(&sep, 11).available, -50_000);
        assert_eq!(card_row(&sep, 4).activity, 100_000);
        assert_eq!(sep.ready_to_assign, 900_000);
        let oct = compute(&s, "2026-10").unwrap();
        assert_eq!(row(&oct, 11).available, 0);
        assert_eq!(card_row(&oct, 4).available, 100_000);
        assert_eq!(oct.ready_to_assign, 900_000);
    }

    #[test]
    fn cash_overspending_still_hits_rta() {
        let mut s = sep_card_snap(100_000);
        s.transactions.push(tx(1, "2026-09-10", -150_000, Some(11)));
        let oct = compute(&s, "2026-10").unwrap();
        assert_eq!(oct.ready_to_assign, 850_000);
        assert_eq!(card_row(&oct, 4).available, 0);
    }

    #[test]
    fn mixed_overspending_credit_first() {
        let mut s = sep_card_snap(100_000);
        s.transactions.push(tx(1, "2026-09-10", -150_000, Some(11)));
        s.transactions.push(tx(4, "2026-09-11", -100_000, Some(11)));
        let sep = compute(&s, "2026-09").unwrap();
        assert_eq!(row(&sep, 11).available, -150_000);
        assert_eq!(card_row(&sep, 4).activity, 0);
        let oct = compute(&s, "2026-10").unwrap();
        assert_eq!(oct.ready_to_assign, 850_000);
    }

    #[test]
    fn covering_credit_overspending_by_assigning_to_the_card() {
        let mut s = sep_card_snap(100_000);
        s.transactions.push(tx(4, "2026-09-10", -150_000, Some(11)));
        s.entries.push(BudgetEntry {
            category_id: card_payment_id(id(4)),
            month: "2026-10".into(),
            assigned: 50_000,
        });
        let oct = compute(&s, "2026-10").unwrap();
        assert_eq!(card_row(&oct, 4).available, 150_000);
        assert_eq!(oct.ready_to_assign, 850_000);
    }

    #[test]
    fn credit_share_is_greedy_across_cards() {
        let mut s = sep_card_snap(100_000);
        s.accounts.push((id(5), card_account(false)));
        s.transactions.push(tx(4, "2026-09-10", -150_000, Some(11)));
        s.transactions.push(tx(5, "2026-09-11", -60_000, Some(11)));
        let b = compute(&s, "2026-09").unwrap();
        assert_eq!(card_row(&b, 4).activity, 40_000);
        assert_eq!(card_row(&b, 5).activity, 60_000);
    }

    #[test]
    fn credit_share_is_capped_per_card() {
        let mut s = sep_card_snap(0);
        s.accounts.push((id(5), card_account(false)));
        s.transactions.push(tx(4, "2026-09-10", -50_000, Some(11)));
        s.transactions.push(tx(5, "2026-09-11", -60_000, Some(11)));
        let b = compute(&s, "2026-09").unwrap();
        assert_eq!(card_row(&b, 4).activity, 0);
        assert_eq!(card_row(&b, 5).activity, 0);
    }

    #[test]
    fn refund_larger_than_spend_never_gives_negative_credit() {
        let mut s = sep_card_snap(100_000);
        s.transactions.push(tx(4, "2026-09-10", 30_000, Some(11)));
        let b = compute(&s, "2026-09").unwrap();
        assert_eq!(row(&b, 11).available, 130_000);
        assert_eq!(card_row(&b, 4).activity, -30_000);
    }

    #[test]
    fn uncategorized_card_outflow_is_charged_once() {
        let mut s = snap_with_card();
        s.transactions = vec![
            tx(1, "2026-10-01", 1_000_000, None),
            tx(4, "2026-10-02", -500_000, None), // card starting debt
        ];
        s.transactions.extend(transfer(1, 4, "2026-10-20", 500_000));
        assert_eq!(compute(&s, "2026-11").unwrap().ready_to_assign, 500_000);
    }

    #[test]
    fn card_spend_sent_to_an_off_budget_account_moves_to_the_row() {
        let mut s = funded_card_snap();
        let mut spend = tx(4, "2026-10-05", -200_000, Some(11));
        spend.transfer_account_id = Some(id(3));
        s.transactions.push(spend);
        s.transactions.extend(transfer(1, 4, "2026-10-25", 200_000));
        let oct = compute(&s, "2026-10").unwrap();
        assert_eq!(card_row(&oct, 4).available, 0);
        assert_eq!(compute(&s, "2026-11").unwrap().ready_to_assign, 500_000);
    }

    #[test]
    fn balance_transfer_between_cards_is_not_a_payment() {
        let mut s = funded_card_snap();
        s.accounts.push((id(5), card_account(false)));
        s.transactions.push(tx(4, "2026-10-05", -200_000, Some(11)));
        s.transactions.extend(transfer(4, 5, "2026-10-20", 200_000));
        let oct = compute(&s, "2026-10").unwrap();
        assert_eq!(card_row(&oct, 5).available, 0);
        assert_eq!(compute(&s, "2026-11").unwrap().ready_to_assign, 500_000);
    }

    #[test]
    fn rejects_bad_month() {
        assert!(compute(&snap(), "2026-13").is_err());
    }
}
