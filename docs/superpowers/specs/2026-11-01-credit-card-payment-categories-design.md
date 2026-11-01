# Credit card payment categories: design

Status: draft for approval. Date: 2026-11-01. Owner: Deni.

## Intent

Deni is moving a YNAB budget into zero-sum and uses credit cards. YNAB sets money aside for a card as you spend on it, in a per-card payment category. zero-sum has no equivalent (`docs/architecture.md`, "Not modelled yet"), so imported numbers would not match YNAB. The goal is for `budget::compute` to reproduce YNAB's category, payment-category and Ready to Assign numbers for card accounts, so the one-off YNAB import (see `docs/ynab-api-feature-ideas.md`, 3.1) can be checked against YNAB's own figures.

## Goals

- Each on-budget `credit_card` account gets a payment category row in the budget month, with assigned, activity and available.
- Spending on a card moves money from the spending category into the card's payment category.
- Paying the card from an on-budget account draws the payment category down.
- The user can assign money to a payment category, to pay down debt that existed before the budget.
- All clients show the same numbers, because the math lives in `crates/core/src/budget.rs`.
- No change to sync, to the stored entities, or to the op format.

## Non-goals

- Loans, mortgages, `line_of_credit`. They stay ordinary on-budget accounts with no payment category.
- Goals, scheduled payments, interest, due dates or minimum payments.
- Any bank connection. Every transaction is entered by hand.
- A new `Kind`, or a real `Category` entity per card.

## Anti-goals

- Syncing derived numbers. Payment category activity and available are computed, never stored.
- A design where editing one transaction rewrites budget entries elsewhere. That would conflict under per-field last-writer-wins.
- Silent mismatch with YNAB. Where our rules differ, the import reports the difference.

## Constraints

- `model.rs` structs use `deny_unknown_fields`, so adding stored fields forces a core release before any client writes them. This design adds no stored fields.
- `BudgetMonth` is returned by the server (`GET /budget/{month}`) and by the WASM, C and UniFFI bindings. New fields on it must be additive with serde defaults so older clients keep working.
- Money is `i64` milliunits.
- Single user, single budget, one currency.

## Approaches considered

- **A. Derived rows only.** Payment rows are computed and read-only. Rejected: money cannot be assigned to them, so the import would drop YNAB's `budgeted` values on payment categories, and Ready to Assign would differ whenever debt was paid down that way.
- **B. Derived rows that accept assignment.** Chosen. Each card gets a deterministic id. Ordinary `budget_entry` rows may target it. Activity is computed.
- **C. Defer, import cards as plain accounts.** Rejected: Deni uses cards, numbers would not match.

Deni chose B on 2026-11-01.

## Design

### Payment category id

For a card account `a`, the payment category id is `uuid5(CARD_PAYMENT_NAMESPACE, a.to_string())`, a new namespace constant next to `BUDGET_ENTRY_NAMESPACE` in `model.rs`. It is not an entity. A `budget_entry` for it uses the normal `budget_entry_id(payment_id, month)`. `model::validate` already accepts any `category_id` in a budget entry, so no validation change is needed, but see "Left to the builder".

A card account is a live account with `kind == CreditCard` and `on_budget == true`. Closed cards keep their row while they have a non-zero available amount.

### Output shape

`BudgetMonth` gains `card_payments: Vec<CardPaymentMonth>` with `#[serde(default)]`. `CardPaymentMonth` is `{ account_id, category_id (the payment id), assigned, activity, available }`. Sorted by `account_id`. The existing `categories` list is unchanged, so clients that do not know the field still compute the right Ready to Assign and category rows.

### Rules

These follow YNAB's behaviour as Deni described it and as the API exposes it. YNAB's help pages could not be fetched during design, so the rules below are an assumption to be confirmed by the import check: for a real YNAB budget, our `card_payments` available per card per month must equal the `balance` of that card's payment category in the YNAB API. Differences are reported, not forced.

For month `m`, category `c`, card `a`:

1. `card_spend(c, a, m)` is the net outflow on card `a` attributed to category `c` in `m`: categorized outflows, split lines included, minus categorized inflows (refunds). Transfers are excluded.
2. Category activity is unchanged from today: all accounts, all months.
3. Category available is `carry + assigned + activity`, as today. If it is negative, the overspent amount is split. The **credit overspending** is `min(overspent, sum over cards of card_spend(c, a, m))`, never below zero. The rest is **cash overspending**.
4. Cash overspending resets the category to 0 and is subtracted from the next month's Ready to Assign, as today.
5. Credit overspending also resets the category to 0, but it is not subtracted from Ready to Assign. Instead the card's payment category is short by that amount (rule 6). The user fixes the shortfall by assigning money to the payment category. No per-category credit balance is carried between months.
6. Money moved into the payment category in `m`, for card `a`, is the sum over categories of `card_spend(c, a, m)` minus that card's share of credit overspending in `c`. The share is allocated greedily: cards in descending order of `card_spend(c, a, m)`, ties by account id, each card taking up to its own `card_spend` until the credit overspending is used up.
7. Payment category activity is `moved_in(a, m)` minus payments in `m`. A payment is the inflow leg on card `a` of a transfer whose source account is on-budget.
8. Payment category available is `carry + assigned + activity`. Positive carries. Negative follows rule 4: it resets and reduces the next month's Ready to Assign.
9. Ready to Assign is otherwise unchanged: cumulative income, minus cumulative assigned (categories and payment categories), minus cash overspending of earlier months.

### Documentation changes

- `crates/core/src/budget.rs` header: replace "Credit-card payment categories are not modelled yet" with the rules above.
- `docs/architecture.md`: remove credit card payment categories from "Not modelled yet" and describe the rows.
- `docs/ynab-api-feature-ideas.md`: fix the note in 3.5 that says reconcile would reverse D8. Deni decided on 2026-11-01 that `reconciled` mirrors across transfer legs like `cleared`, so D8 stands.

### Tests

- Unit tests in `budget.rs` for each rule: covered spend, refund, credit overspending carry, cash overspending unchanged, payment, payment above set-aside, assignment to the payment category, two cards sharing one overspent category, closed card.
- Extend `scripts/seed-demo.py` with a credit card scenario whose expected numbers are worked out by hand, so the end-to-end check covers the server and the JSON shape.

## Decisions made by Deni

- Option B.
- Credit cards are in use. Loan and mortgage account types are not.
- Tracking and asset accounts map to off-budget accounts. No new account kinds.
- Reconcile mirrors across transfer legs (D8 stays).
- Concurrent "move money" edits overwriting each other is acceptable.
- Transactions are entered by hand. No bank import.

## Calls made by the author (not yet confirmed by Deni)

- Credit overspending resets the category and leaves the payment category short (rule 5). The alternative, carrying it as negative available, needs a per-category credit balance and double-counts easily. I could not fetch YNAB's help pages to confirm which one YNAB does. The import check settles it.
- Verification against real YNAB data belongs to the importer project, not this one. This project ships with hand-computed tests and the rules are unverified until the import runs.
- Card starting balance: keep today's behaviour (an uncategorized card outflow reduces Ready to Assign). Revisit after the import check.
- Cards that are closed still count in category math. A card switched to off-budget has no row and its transactions are skipped, as for any off-budget account. A `budget_entry` for an unknown payment id is ignored, so that money returns to Ready to Assign.
- Allocation across cards is greedy (rule 6).

## Left to the builder

- Rendering in each client (web, iOS, Android): where the payment rows appear and how the user assigns to them. Group them under a "Credit Card Payments" heading, as in YNAB. Wire through the existing assign-money action with the payment id as `category_id`.
- Whether `model::validate` should reject a budget entry whose `category_id` is neither a category nor a payment id. Today it cannot know, because it sees one entity. Rejecting is not possible there; prefer ignoring such entries in `compute`, as unknown categories are ignored now.
- Cash advances and transfers out of a card (card-side outflow leg). Ignored today because on-budget transfers are ignored. Keep that unless the import check shows a difference.
- Transfers from an off-budget account into a card: follow D5.
