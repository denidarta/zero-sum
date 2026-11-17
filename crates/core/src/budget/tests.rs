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
