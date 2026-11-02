# Credit Card Payment Categories Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `budget::compute` returns a payment row per on-budget credit card, moves covered card spending into it, lets the user assign to it, and all three clients show it.

**Architecture:** Payment rows are derived in `crates/core/src/budget.rs` and returned in a new additive `BudgetMonth.card_payments` list. A card's payment category has a deterministic id (uuid5 of the account id), so the existing `budget_entry` entity and `entry_id` binding work unchanged. No new `Kind`, no stored fields, no sync change.

**Tech Stack:** Rust (core, server), Python (`scripts/seed-demo.py`), Preact/TypeScript (web), Swift/SwiftUI (iOS), Flutter/Dart (Android).

**Spec:** `docs/superpowers/specs/2026-11-01-credit-card-payment-categories-design.md`. Read it first. The rule numbers (1 to 9) below refer to its "Rules" section.

## Global Constraints

- Money is `i64` milliunits. Whole-unit test values below are written as milliunits (`200_000` = 200.00).
- `BudgetMonth.card_payments` is `#[serde(default)]`. Clients that do not know it must keep working.
- Do not store or sync any derived payment number.
- Card account means `kind == AccountKind::CreditCard` and `on_budget == true`. Closed cards count. Other kinds get no payment row.
- Transactions are entered by hand. No bank import.
- Core release first, then clients. The core change is backward compatible, so clients may ship later.
- Commit messages end with the attribution lines the session reminder specifies.

## Review Focus

- Card with no transactions and no assignment: no row for a closed card, a zero row for an open card.
- Refund on a card larger than the spend in that category (negative net spend): moves money back out of the payment category and never produces negative credit overspending.
- Budget entry targeting the payment id of a card that is off-budget, deleted or not a card: ignored, money stays in Ready to Assign.
- Payment transfer entered before any card spending: payment available goes negative, resets next month, and reduces next month's Ready to Assign (rule 8).
- Category overspent by cash and card together: credit part first (rule 3), remainder hits Ready to Assign.
- Old clients receiving the new JSON: unknown field `card_payments` is ignored.

---

### Task 1: Payment row from spending, payments and assignment

**Files:**
- Modify: `crates/core/src/model.rs` (add `CARD_PAYMENT_NAMESPACE`, `card_payment_id`)
- Modify: `crates/core/src/budget.rs` (types, `compute`, tests)

**Interfaces:**
- Produces, in `model.rs`: `pub fn card_payment_id(account_id: Uuid) -> Uuid` = `Uuid::new_v5(&CARD_PAYMENT_NAMESPACE, account_id.to_string().as_bytes())`, with `const CARD_PAYMENT_NAMESPACE: Uuid = Uuid::from_u128(0x7a65_726f_2d73_756d_8000_0000_0000_0002)`.
- Produces, in `budget.rs`: `pub struct CardPaymentMonth { pub account_id: Uuid, pub category_id: Uuid, pub assigned: i64, pub activity: i64, pub available: i64 }` (derive like `CategoryMonth`), and `BudgetMonth.card_payments: Vec<CardPaymentMonth>` with `#[serde(default)]`, sorted by `account_id`.
- Consumes: existing `compute(snap, month)`.

Implements spec rules 1, 2, 7, 8 and 9 without credit overspending (that is Task 2). In this task, `moved_in(a, m)` is simply the sum of `card_spend(c, a, m)` over live categories.

- [ ] **Step 1: Write failing tests in `budget.rs` `mod tests`.** Add a card account `id(4)`, `CreditCard`, on-budget, to a test helper (do not change `snap()`; add `fn snap_with_card() -> Snapshot` that extends it). Add helper `fn card_row(b: &BudgetMonth, account: u128) -> &CardPaymentMonth`. Tests, month `2026-10` unless stated, income `tx(1, "2026-10-01", 1_000_000, None)`, entry `entry(11, "2026-10", 500_000)`:
  - `card_spend_moves_to_payment`: card `tx(4, "2026-10-05", -200_000, Some(11))`. Assert cat 11 activity `-200_000`, available `300_000`; card row activity `200_000`, available `200_000`, assigned `0`; `ready_to_assign == 500_000`.
  - `payment_draws_the_row_down`: add a transfer pair, checking `-150_000` and card `+150_000`, both with `transfer_account_id` set to the other account, dated `2026-10-20`. Card row activity `50_000`. Ready to Assign still `500_000`.
  - `card_refund_reduces_the_row`: add card `tx(4, "2026-10-06", 50_000, Some(11))`. Card row activity `150_000`.
  - `assigning_to_the_payment_category`: add `BudgetEntry { category_id: card_payment_id(id(4)), month: "2026-10", assigned: 100_000 }`. Card row assigned `100_000`, available `300_000`, Ready to Assign `400_000`.
  - `entry_for_a_non_card_payment_id_is_ignored`: entry for `card_payment_id(id(9))` of `100_000`. Ready to Assign unchanged at `500_000`, and `card_payments` has one row.
  - `payment_row_carries_to_next_month`: card spend `-200_000` dated `2026-09-05` in cat 11 with entry `2026-09`; compute `2026-10` with no October card activity. Row available `200_000`.
  - `payment_above_available_resets_and_hits_rta`: Sep: income `1_000_000`, `entry(11,"2026-09",300_000)`, card spend `-100_000` in cat 11, transfer pair of `150_000` from checking to card dated `2026-09-20`. Assert Sep row available `-50_000`, Sep Ready to Assign `700_000`; Oct row available `0`, Oct Ready to Assign `650_000`.
  - `closed_card_row_only_while_nonzero`: card closed with no activity: `card_payments` empty. Closed card with Sep spend of `100_000` covered by cat 11: Oct row exists with available `100_000`.
  - `non_card_kinds_get_no_row`: the existing `snap()` accounts (checking) produce `card_payments` empty.
- [ ] **Step 2: Run** `cargo test -p zero-sum-core budget` and confirm the new tests fail to compile or fail.
- [ ] **Step 3: Implement.** Add the id function and types. In `compute`: collect card account ids; accept `BudgetEntry` rows whose `category_id` is a card's payment id into a separate `card_assigned` map; compute `card_spend[(category, card, month)]` from non-transfer transactions on card accounts (split lines included) before the existing skip logic; compute `payments[(card, month)]` from inflow legs on a card whose `transfer_account_id` is an on-budget account (do this before the existing on-budget-transfer `continue`). In the month loop, after the category rows, build each card's row (`activity = moved_in - payments`, `available = carry + assigned + activity`), add card assigned to `assigned_cum`, reset negative available into `overspent` exactly like a category (rule 8), and omit a closed card's row when assigned, activity and available are all 0.
- [ ] **Step 4: Run** `cargo test -p zero-sum-core` and confirm all pass, old tests included.
- [ ] **Step 5: Commit** `feat(core): card payment rows in the budget month`.

---

### Task 2: Credit overspending

**Files:**
- Modify: `crates/core/src/budget.rs`

**Interfaces:**
- Consumes: Task 1 structures (`card_spend` map, card rows).
- Produces: no new public items. Changes `compute` so cash overspending alone feeds `overspent` and `moved_in` subtracts each card's credit share.

Implements rules 3, 5 and 6.

- [ ] **Step 1: Write failing tests** (same helpers as Task 1; Sep income `1_000_000` dated `2026-09-01` on checking):
  - `credit_overspending_leaves_rta_alone`: Sep `entry(11,"2026-09",100_000)`, card spend `-150_000` in cat 11. Assert Sep cat 11 available `-50_000`, card row activity `100_000`, Sep Ready to Assign `900_000`. Oct: cat 11 available `0`, card row available `100_000`, Oct Ready to Assign `900_000`.
  - `cash_overspending_still_hits_rta`: same but the spend is on checking `-150_000`. Oct Ready to Assign `850_000`, no card rows.
  - `mixed_overspending_credit_first`: entry `100_000`, checking `-150_000`, card `-100_000`. Sep cat 11 available `-150_000`, card row activity `0`, Oct Ready to Assign `850_000`.
  - `covering_credit_overspending_by_assigning_to_the_card`: first test plus Oct entry for `card_payment_id(id(4))` of `50_000`. Oct card row available `150_000`, Oct Ready to Assign `850_000`.
  - `credit_share_is_greedy_across_cards`: add card `id(5)`. Entry `100_000`, card 4 spend `-150_000`, card 5 spend `-60_000` in cat 11. Assert card 4 activity `40_000`, card 5 activity `60_000`.
  - `credit_share_is_capped_per_card`: entry `0`, card 4 spend `-50_000`, card 5 spend `-60_000`. Both rows activity `0`.
  - `refund_larger_than_spend_never_gives_negative_credit`: entry `100_000`, card tx `+30_000` in cat 11 only. Cat 11 available `130_000`, card row activity `-30_000`.
- [ ] **Step 2: Run** `cargo test -p zero-sum-core budget` and confirm failures.
- [ ] **Step 3: Implement.** Per category and month: `overspent = max(0, -available)`; `credit = clamp(overspent, 0, sum of card_spend over cards)`; cash part `overspent - credit` goes to the month's `overspent`; the category carry still resets to 0. Allocate `credit` greedily to cards (descending `card_spend`, ties by account id, each capped at its own spend, ignore cards with non-positive spend) and subtract each card's share from its `moved_in`. A category with negative net card spend moves that negative amount back out of the row.
- [ ] **Step 4: Run** `cargo test -p zero-sum-core`, then `cargo test --workspace`. All pass.
- [ ] **Step 5: Commit** `feat(core): credit overspending leaves the card payment short`.

---

### Task 3: Server check, seed scenario and docs

**Files:**
- Modify: `scripts/seed-demo.py`
- Modify: `crates/core/src/budget.rs` (header comment only)
- Modify: `docs/architecture.md`, `docs/ynab-api-feature-ideas.md`

**Interfaces:**
- Consumes: JSON field `card_payments[]` of `GET /budget/{month}`: `{account_id, category_id, assigned, activity, available}`.

- [ ] **Step 1: Extend the expected numbers in `seed-demo.py`.** Add Python `CARD_NS = uuid.UUID(int=0x7A65_726F_2D73_756D_8000_0000_0000_0002)`, a helper `assign_payment(month, account_id, amount)` using `uuid.uuid5(CARD_NS, account_id)` as the category id and the same budget-entry id rule as `assign`, and an `EXPECTED_CARD` table of `(assigned, activity, available)` for the Credit Card account. Existing months, worked out by hand from the data already in the script: `2026-08` `(0, 295, 295)`, `2026-09` `(0, 365.6, 660.6)`, `2026-10` `(0, -189.5, 471.1)`. The existing category and Ready to Assign numbers must not change.
- [ ] **Step 2: Add a `2026-11` scenario that credit-overspends.** Checking: salary `+4000` on `2026-11-01`. Assign: Rent 1500, Utilities 220, Internet 80, Groceries 600, Dining Out 0, Transport 150, Emergency Fund 500, Vacation 400; payment category of Credit Card 50. Spend: Rent `-1500`, Utilities `-220`, Internet `-80`, Transport `-60` on Checking; Groceries `-300` and Dining Out `-200` on the Credit Card. Expected: Ready to Assign `4323.75`; Dining Out `(0, -200, -115.5)`; Groceries `(600, -300, 394.7)`; Utilities `(220, -220, 14.25)`; Transport `(150, -60, 239.5)`; Emergency Fund `(500, 0, 2500)`; Vacation `(400, 0, 1030)`; Rent and Internet `(…, …, 0)`; card row `(50, 384.5, 905.6)`.
- [ ] **Step 3: Compare `card_payments` in the verification loop** the same way categories are compared (find the card row by `account_id`).
- [ ] **Step 4: Run** `scripts/with-server.sh bash -c 'python3 scripts/seed-demo.py "$ZERO_SUM_TEST_SERVER"'`. Expect `budget math matches…`. A mismatch is either a hand-computation error or a core bug: stop and work out which before changing either side.
- [ ] **Step 5: Docs.** Replace the "Credit-card payment categories are not modelled yet" line in the `budget.rs` header with a short summary of rules 1 to 9. In `docs/architecture.md` remove credit card payment categories from "Not modelled yet" and describe `card_payments`. In `docs/ynab-api-feature-ideas.md` fix 3.5 and roadmap so they say `reconciled` mirrors across transfer legs and D8 stands, and mark 3.11's credit card item as done.
- [ ] **Step 6: Commit** `feat(scripts): credit card scenario in the demo seed` and `docs: credit card payment categories`.

---

### Task 4: Web client

**Files:**
- Modify: `clients/web/src/types.ts`, `clients/web/src/app.tsx`

**Interfaces:**
- Consumes: `BudgetMonth.card_payments`. `export interface CardPaymentMonth { account_id: string; category_id: string; assigned: number; activity: number; available: number }` and `card_payments?: CardPaymentMonth[]` on `BudgetMonth` (optional, older cached data may lack it).

- [ ] **Step 1: Add the type and render a "Credit Card Payments" `<tbody data-testid="card-payments">`** after the groups, one row per entry with the account name (look up the `account` entity by `account_id`), the same Assigned input as `categoryRow` writing a `budget_entry` with `category_id: row.category_id` through the existing assign path (`entry_id` binding), plus Activity and Available. Hide the section when `card_payments` is empty.
- [ ] **Step 2: Run** `cd clients/web && npm run build`. Passes with no type errors.
- [ ] **Step 3: Extend `clients/web/e2e/smoke.mjs`** to add a credit card account, spend on it in a category, and assert the `card-payments` row shows the moved amount; run it as the README describes.
- [ ] **Step 4: Commit** `feat(web): show credit card payment rows`.

---

### Task 5: iOS client

**Files:**
- Modify: `clients/ios/Sources/ZeroSumKit/Models.swift`, `clients/ios/App/BudgetView.swift`
- Test: `clients/ios/Tests/ZeroSumKitTests/CoreTests.swift`

**Interfaces:**
- Produces: `public struct CardPaymentMonth: Codable, Hashable { accountId, categoryId, assigned, activity, available }` with snake_case `CodingKeys`, and `BudgetMonth.cardPayments: [CardPaymentMonth]` decoded with `decodeIfPresent ?? []` (follow `orphanedCategoryIds`).

- [ ] **Step 1: Write the failing test** `testBudgetDecodesCardPayments` in `CoreTests.swift` that decodes a `BudgetMonth` JSON with one `card_payments` row and one without the key, asserting `cardPayments.count` is 1 and 0.
- [ ] **Step 2: Run** `scripts/with-server.sh swift test` in `clients/ios` (macOS needed). Fails.
- [ ] **Step 3: Implement the model and a "Credit Card Payments" section in `BudgetView.swift`** reusing `AssignSheet`, passing a payment row as the category (extend `AssignSheet` input to a `(id, name)` pair if it requires an `Entity`).
- [ ] **Step 4: Run tests.** Pass.
- [ ] **Step 5: Commit** `feat(ios): show credit card payment rows`.

---

### Task 6: Android client

**Files:**
- Modify: `clients/android/lib/app.dart`
- Test: `clients/android/test/ui_test.dart`

- [ ] **Step 1: Write the failing widget test** `shows credit card payment rows` in `ui_test.dart`: seed the db with a credit card account, a category with assigned money and a card spend, pump the budget screen, and expect a `Key('card-payments')` section containing the card name and the moved amount.
- [ ] **Step 2: Run** `flutter test test/ui_test.dart` in `clients/android`. Fails.
- [ ] **Step 3: Implement** a "Credit Card Payments" section after the groups in the budget list, rows from `b['card_payments'] as List? ?? const []`, assigned editing through the same dialog and `budget_entry` write as `_CategoryRow`, with the row's `category_id`.
- [ ] **Step 4: Run** `flutter test`. Passes.
- [ ] **Step 5: Commit** `feat(android): show credit card payment rows`.

---

## Self-review

- **Spec coverage:** rules 1, 2, 7, 8, 9 in Task 1; 3, 5, 6 in Task 2; rule 4 is unchanged behaviour and covered by `cash_overspending_still_hits_rta`; docs, D8 note and seed test in Task 3; clients in Tasks 4 to 6. Calls made by the author (greedy allocation, closed and off-budget cards, unknown payment ids, starting balance unchanged) are all pinned by tests.
- **Type consistency:** `card_payment_id`, `CardPaymentMonth`, `card_payments` are named the same in every task. JSON keys are `account_id`, `category_id`, `assigned`, `activity`, `available`.
- **Not in this plan:** the YNAB importer and its check against YNAB's figures (separate project), loans, goals.
