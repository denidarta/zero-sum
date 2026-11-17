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
mod tests;
