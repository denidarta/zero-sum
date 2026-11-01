# YNAB API study and feature ideas

Status: research note, 2026-11-01. Nothing here is decided. It compares the public YNAB API with what zero-sum has, and proposes what to bring in.

Sources, all primary:

- Docs: <https://api.ynab.com/> (cited below as "docs", with the anchor)
- OpenAPI spec, version 1.88.0: <https://api.ynab.com/papi/open_api_spec.yaml> (cited as "spec")
- Official JS SDK: <https://github.com/ynab/ynab-sdk-js>. The Ruby and Python SDKs are linked from the docs "Libraries" section and are generated from the same spec.

Naming note: the API now calls budgets "plans" (`/v1/plans/{plan_id}/...`). The old term was "budgets". This note uses "plan" for the YNAB object and "budget" for ours.

## 1. Summary of the YNAB API

### Auth

- Every call needs `Authorization: Bearer <token>`. Source: docs `#access-token-usage`.
- Two token kinds. A Personal Access Token is made in Account Settings, does not expire and can be revoked. It is meant for one person using their own data. OAuth is for apps that serve other users. Source: docs `#authentication-overview`.
- OAuth supports the implicit grant (token expires after 2 hours, no refresh) and the authorization code grant (refresh tokens, optional PKCE and `state`). A `read-only` scope makes writes return 403. New OAuth apps are in Restricted Mode (25 foreign users) until reviewed. Source: docs `#oauth-applications`.
- `plan_id` accepts `last-used`, and `default` if the OAuth app enabled default plan selection. Source: spec, `plan_id` parameter; docs `#oauth-default-plan`.
- TLS is enforced and CORS is supported. Source: docs `#usage-overview`.

### Rate limits and errors

- 200 requests per hour per token, in a rolling window. Over the limit returns 429. Source: docs `#rate-limiting`.
- Errors are `{"error": {"id", "name", "detail"}}`. Codes include 400, 401, 403.1 to 403.5 (subscription lapsed, trial expired, scope, data limit, email unconfirmed), 404.1/404.2, 409 (conflict), 429, 500, 503. A request that runs over 30 seconds gives 503. Source: docs `#errors`.
- Success is `{"data": {...}}`. Empty values are `null`, never omitted. Source: docs `#response-format`.
- The docs ask clients to cache, use delta requests, and ask for the narrowest resource possible. Source: docs `#best-practices`.

### Data formats

- Money is "milliunits": 1000 = one currency unit, signed integers, whatever the currency's decimals. Since v1.82.0 responses also carry `*_formatted` and `*_currency` fields. Source: docs `#formats`.
- Dates are ISO 8601 `YYYY-MM-DD`, in UTC. Months are the first of the month (`2024-01-01`). Source: docs `#formats`; spec `MoneyMovementBase.month`.

### Delta requests

- Nine endpoints take `last_knowledge_of_server` and return `server_knowledge`: plan detail, accounts, categories, money movements, money movement groups, months, payees, scheduled transactions, transactions. Pass back the last `server_knowledge` and get only entities changed since. Source: docs `#deltas`.
- Deleted rows come back with `deleted: true`, and only in delta responses. Every entity schema says this ("Deleted ... will only be included in delta requests"). Source: spec, `deleted` fields.
- Payee locations, settings and single-entity reads have no delta.

### Resources

All paths are under `/v1/plans/{plan_id}`. Source for the whole list: spec `paths`.

- **User**: `GET /user`.
- **Plans**: list, and `GET /plans/{plan_id}` which returns everything (accounts, payees, categories, months, transactions, scheduled items) in one delta-capable response. `include_accounts=true` on the list.
- **Settings**: `GET /settings` returns `date_format` and `currency_format` (`iso_code`, `decimal_digits`, `decimal_separator`, `group_separator`, `currency_symbol`, `symbol_first`, `display_symbol`). Source: spec `PlanSettings`, `CurrencyFormat`.
- **Accounts**: list, get, `POST` (name, type, starting balance). Fields: `type` (13 values: checking, savings, cash, creditCard, lineOfCredit, otherAsset, otherLiability, mortgage, autoLoan, studentLoan, personalLoan, medicalDebt, otherDebt), `on_budget`, `closed`, `note`, `balance`, `cleared_balance`, `uncleared_balance`, `transfer_payee_id`, `direct_import_linked`, `direct_import_in_error`, `last_reconciled_at`, loan fields (`debt_interest_rates`, `debt_minimum_payments`, `debt_escrow_amounts`). No update or delete. Source: spec `AccountBase`, `AccountType`.
- **Category groups**: `POST` and `PATCH`. Fields: `hidden`, `internal` (the built-in group), `deleted`. No delete endpoint.
- **Categories**: list (grouped), get, `POST`, `PATCH`. Amounts in the response are for the current UTC month: `budgeted` (assigned), `activity`, `balance` (available). Also `hidden`, `internal`, `note`, and the goal fields below. `PATCH /months/{month}/categories/{id}` changes only `budgeted` for that month. Source: spec `CategoryBase`, `SaveMonthCategory`.
- **Goals (targets)**: read on the category, write on create and patch. Types `goal_type`: `TB` (target balance), `TBD` (target balance by date), `MF` (monthly funding), `NEED` (plan your spending), `DEBT`. Fields: `goal_target`, `goal_target_date`, `goal_day`, `goal_cadence` (0 to 14) with `goal_cadence_frequency`, `goal_needs_whole_amount` (NEED only; "Set Aside" vs "Refill"), `goal_creation_month`, `goal_snoozed_at`. Computed and read-only: `goal_percentage_complete`, `goal_months_to_budget`, `goal_under_funded`, `goal_overall_funded`, `goal_overall_left`. Write side (`SaveCategory`) only exposes `goal_target`, `goal_target_date`, `goal_needs_whole_amount`, `goal_frequency` (monthly, weekly, yearly). Source: spec `CategoryBase`, `SaveCategory`.
- **Payees**: list, get, `POST`, `PATCH` (name only). `transfer_account_id` is set on the special payee that stands for "transfer to account X". No delete. Source: spec `Payee`, `SavePayee`.
- **Payee locations**: read-only latitude and longitude per payee, listed globally or per payee. Source: spec `PayeeLocation`.
- **Months**: list and get. Fields: `income`, `budgeted`, `activity`, `to_be_budgeted` (Ready to Assign), `age_of_money`, `note`, and the month's categories. Source: spec `MonthSummaryBase`.
- **Transactions**: list (default last year, filters `since_date`, `until_date`, `type=uncategorized|unapproved`, delta), get, `POST` (one or many), `PUT` (one), `PATCH` (many), `DELETE`. Also per account, per category, per payee and per month lists. Pending (unposted) bank transactions are excluded. Source: spec `/transactions`.
- **Scheduled transactions**: list, get, `POST`, `PUT`, `DELETE`, delta. Fields: `date_first`, `date_next`, `frequency` (`never, daily, weekly, everyOtherWeek, twiceAMonth, every4Weeks, monthly, everyOtherMonth, every3Months, every4Months, twiceAYear, yearly, everyOtherYear`), amount, payee, category, flag, memo, plus scheduled subtransactions. The date must be in the future, at most 5 years out. Creating a split scheduled transaction is not supported. Source: spec `SaveScheduledTransaction`, `ScheduledTransactionFrequency`.
- **Money movements**: read-only, global and per month, plus "groups". A movement is `from_category_id` to `to_category_id` with amount, month, `moved_at`, note, and a group id. Groups hold `note`, `month`, `group_created_at`. Both delta-capable. This is the audit trail of "move money" between categories. Source: spec `MoneyMovementBase`, `MoneyMovementGroup`.

### Transaction field semantics

- `amount`: signed milliunits, negative is outflow. Source: spec `TransactionSummaryBase`.
- `cleared`: `cleared | uncleared | reconciled`. Three states, not a boolean. `account.last_reconciled_at` records the last reconcile. Source: spec `TransactionClearedStatus`, `AccountBase`.
- `approved`: boolean. New API transactions are unapproved unless `approved: true` is sent. It is the inbox flag for imported items. `type=unapproved` filters on it. Source: spec `SaveTransactionWithOptionalFields.approved`, `/transactions` `type`.
- `flag_color`: `red, orange, yellow, green, blue, purple`, empty or null. `flag_name` is the user's label for that colour, read-only. Source: spec `TransactionFlagColor`.
- Payee: send `payee_id`, or `payee_name`. A name resolves to a payee rename rule (only when `import_id` is also set), else an existing payee with that name, else a new payee. Source: spec `payee_name`.
- Transfers: set `payee_id` to the target account's `transfer_payee_id`. The server creates and links the other leg. Reads show `transfer_account_id` and `transfer_transaction_id`. Source: spec `payee_id` description.
- Splits: `category_id: null` plus a `subtransactions` array of `{amount, payee_id|payee_name, category_id, memo}`. Subtransactions can be transfers (`transfer_account_id`). Existing splits cannot have their subtransactions, date, amount or category changed through the API. Splits are not allowed on tracking accounts or on transfers between on-budget accounts. Source: spec `SaveTransactionWithOptionalFields`, `SaveSubTransaction`, `SubTransactionBase`.
- Credit Card Payment categories cannot be used by the API for transactions or splits. Source: spec `category_id`.
- `matched_transaction_id`: set when an imported transaction was matched to a hand-entered one. Source: spec `TransactionSummaryBase`.
- `debt_transaction_type`: payment, refund, fee, interest, escrow, balanceAdjustment, credit, charge, for loan accounts. Source: spec.
- `deleted`: tombstone, shown only in delta responses. Source: spec.

### Import and bulk behaviour

- `import_id` (max 36 chars, unique per account) marks a transaction as imported. YNAB's own bank and file import use the format `YNAB:<milliunits>:<iso_date>:<occurrence>`, for example `YNAB:-294230:2015-12-30:1`, where occurrence counts same-amount, same-date items on the account. Using that format prevents duplicates against bank and file import. Source: spec `NewTransaction.import_id`.
- When a transaction is created with an `import_id`, YNAB tries to match it to an existing user-entered transaction on the same account, same amount, date within plus or minus 10 days. Without `import_id` the transaction is "user-entered" and can be matched later. Source: spec `import_id` description.
- Single create with a duplicate `import_id` on the account returns 409. Bulk create does not fail: the response lists `duplicate_import_ids` for items skipped, and `transaction_ids` for created ones. Source: spec POST responses, `SaveTransactionsResponse`.
- `POST /transactions` takes either `transaction` or `transactions[]`. `PATCH /transactions` takes an array, each item looked up by `id` or, if `id` is null, by `import_id`. Changing `import_id` on an existing item is not allowed. Source: spec `PostTransactionsWrapper`, PATCH description.
- `POST /transactions/import` is deprecated and does nothing, because YNAB now imports from linked accounts itself. Source: spec `importTransactions`.
- Future dates are rejected on transaction create. Use scheduled transactions. Source: spec `date`.
- Only `budgeted` can be written to a month category. No endpoint creates or edits months. Source: spec.

## 2. Gap analysis

Reference points in this repo: entities in `crates/core/src/model.rs` (`Kind`: account, category_group, category, payee, transaction, budget_entry), merge in `crates/core/src/sync.rs`, budget math in `crates/core/src/budget.rs`, edit rules in `crates/core/src/ledger.rs`, endpoints in `crates/server/src/api.rs`, design in `docs/architecture.md`.

- **Personal access token / OAuth**: lacks, on purpose. See section 4.
- **Rate limit**: lacks, not needed. One user, local server.
- **Milliunits**: has. `i64` milliunits everywhere (`model.rs`, architecture "Money").
- **Dates**: has. `YYYY-MM-DD` transaction dates and `YYYY-MM` months (`model.rs` `parse_date`, `parse_month`). YNAB uses first-of-month dates for months; mapping is trivial.
- **Delta requests**: has an equivalent, stronger in one way. `GET /sync/pull?since=N` returns changed entities with per-field stamps and tombstones (`api.rs`, `sync.rs`). Comparison in section 3.8.
- **Plans (multiple budgets)**: lacks. One implicit budget. Architecture lists "multiple budgets" as not modelled.
- **Settings (currency and date format)**: lacks. Single currency assumed (architecture, "Currency").
- **Accounts**: partially has. `Account` has name, kind, `on_budget`, closed, note. `AccountKind` has 6 values against YNAB's 13 (no mortgage or loan types). Has no cleared/uncleared balance split in the model; the budget math does not need it. No `last_reconciled_at`, no direct import fields (not applicable).
- **Category groups and categories**: has. Name, hidden, sort, note, orphan handling, deletion rules (`ledger.rs`, `ledger-edits-spec.md`). Lacks `internal` flag (Inflow group), since Ready to Assign is derived, not a category. Lacks credit card payment categories.
- **Month assignment**: has. `BudgetEntry` per (category, month) with deterministic id (`model.rs` `budget_entry_id`). Equivalent of `PATCH /months/{month}/categories/{id}`.
- **Month summary**: has. `budget::compute` returns the month with Ready to Assign, activity, available, carry rules. Lacks `income` as a separate total, `age_of_money`, and a month `note`.
- **Goals and targets**: lacks. Architecture says "goals and targets" are not modelled. Category has `note` only.
- **Payees**: partially has. `Payee { name }` entity exists and `Transaction.payee_id` references it. Lacks rename and merge rules, transfer payees (we use `transfer_account_id` on the transaction instead), and payee rename rules.
- **Payee locations**: lacks. Low value for this app.
- **Transactions**: has the core. Account, date, amount, payee, category, memo, cleared, transfer pair, splits (`model.rs` `Transaction`, `ledger.rs`). Edit and delete rules exist.
- **Cleared/reconciled/approved**: partially has. `cleared` is a boolean. No `reconciled` state, no `approved`, no reconciliation workflow (architecture: "reconciliation" not modelled).
- **Flags**: lacks. No `flag_color`.
- **import_id and dedup**: lacks, on purpose. Bank import is out of scope (3.6). Architecture open question 2 asks for a YNAB importer; that is 3.1.
- **Transfers**: has, and richer in places. Two linked legs created client-side by `ledger::plan`, mirror edits (D8), budget-boundary category rule (D5). YNAB creates the other leg server-side via a transfer payee. Our model puts the transfer on the transaction, not on a payee.
- **Splits / subtransactions**: has, with differences. `Transaction.splits` of `{category_id, amount, memo}` (`model.rs` `Split`). Ours cannot carry per-line payee or transfer (D7); YNAB allows both. Ours are editable as a whole under LWW; YNAB's API cannot edit them.
- **Scheduled transactions**: lacks. Architecture lists them as not modelled.
- **Money movements**: lacks. Moves between categories are not a first-class record. A move is two `budget_entry` edits, with no link and no history shown. The op log exists (`ops` table) but no UI reads it.
- **Deleted flag**: has. Tombstones merged like a field (`sync.rs`, architecture "Deletes are tombstones"). YNAB hides deleted rows outside deltas; our pull always carries them to the client, which needs them to converge.
- **Bulk create with duplicate reporting**: partially has. `POST /sync/push` takes many ops and reports `applied | stale | duplicate | rejected` per op (architecture). That is op-id dedup, not content dedup.
- **Server-side matching of imported vs manual transactions**: lacks, on purpose (no bank import).
- **Reports** (spending by category, net worth, age of money): lacks. YNAB's API has none beyond month totals and `age_of_money`.

## 3. Candidate features

Common frame. In our design every change is an op, a patch to one entity with a stamp per field. A new feature is either a new field on an existing entity, or a new `Kind`. New fields cost nothing in the merge: unknown fields to old clients are the risk, because `model.rs` uses `deny_unknown_fields`. So each new field needs a core release before any client writes it. Sizes: S under a day or two, M about a week, L more than a week.

### 3.1 One-time YNAB import (via the API)

- **What**: a script (a small binary crate or a `scripts/` tool) that reads one plan from YNAB and emits ops for our `push` endpoint. Accounts, category groups, categories, payees, transactions with splits and transfers, monthly `budgeted` values.
- **Why**: it is the migration path, and answers open question 2 in the architecture doc. A personal token suffices.
- **How it fits**: no new sync concepts. Map YNAB ids to our UUIDs by reusing the YNAB UUIDs as entity ids (both are UUIDs), which makes the import idempotent: rerunning produces the same `entity_id`s and the same op content. Use one stable `op_id` per entity, for example UUIDv5 of `(kind, id)`, so a retried push returns `duplicate`. Fetch with one `GET /plans/{id}` call (all data, one request, well under the 200 per hour limit), then optionally `GET /transactions` for history older than a year, because the default `since_date` is one year back. Mappings:
  - account `type` to `AccountKind`, with mortgage and loan types to `Other` unless we extend the enum.
  - `transfer_payee_id` payees are dropped. Use `transfer_account_id` and `transfer_transaction_id` from the transaction.
  - YNAB subtransactions to `splits`. Per-line payees are lost. Transfer subtransactions cannot be represented (D7) and must be reported.
  - `cleared` `reconciled` collapses to `true` until 3.5 lands.
  - month `budgeted` to `BudgetEntry`; skip internal categories (Inflow: Ready to Assign).
  - Run the result through `core::validate` and compare `budget::compute` against YNAB's `to_be_budgeted` and category `balance` per month as the acceptance check.
- **Size**: M. The check against YNAB's own numbers is most of the work.
- **Risks**: YNAB carry-over and overspending rules differ from ours in edge cases (credit card overspending, negative available), so numbers may not match exactly; report differences, do not force them. History older than the API's first-call default needs paging by date. The token must not be committed or logged. Credit card payment categories (3.10 below) will appear and have nowhere to go yet.

### 3.2 Payees (first-class)

- **What**: use the existing `payee` entity properly: autocomplete from history, rename, merge, and default category per payee (last used).
- **Why**: payee is the main speed-up when entering transactions by hand, since all entry is manual.
- **How it fits**: rename is one field patch, trivially LWW. Merge is a command in `ledger::plan`: repoint all transactions to the survivor, tombstone the other. Concurrent creation of the same name on two devices makes duplicates; a merge command is the repair, same as YNAB's approach (names resolve to existing payees). Optional deterministic id: UUIDv5 of the normalized name, like `budget_entry_id`, so two offline devices converge on one payee. Keep transfers on the transaction, not a transfer payee, to avoid a second mechanism.
- **Size**: S for rename and autocomplete, M with merge and default category.
- **Risks**: deterministic ids make rename awkward (id no longer matches name). Pick one: deterministic ids with merge-on-demand, or random ids with merge. Random ids plus merge is simpler and matches the rest.

### 3.3 Scheduled and recurring transactions

- **What**: a new `scheduled_transaction` entity with `date_next`, `frequency` (YNAB's 13 values), account, payee, category, amount, memo, optional transfer. A client action "enter now" or "skip".
- **Why**: rent, subscriptions and bills are most of the predictable spending; also gives a forecast for upcoming obligations.
- **How it fits**: the schedule is state, the occurrence is a normal transaction. Do not generate transactions on a timer on every device, because three devices would each create one. Instead, "enter" is an explicit user action that creates a transaction with a deterministic id, UUIDv5 of `(scheduled_id, date)`, and advances `date_next` in the same change. If two devices enter the same occurrence offline, they write the same transaction id and the same `date_next`, so the merge converges. Frequency math (month ends, twiceAMonth, every4Weeks) belongs in `core` so all clients agree. Budget math ignores scheduled items, same as YNAB. Splits on a schedule: YNAB does not support creating them via the API; we can support them cheaply because our `splits` is just an array.
- **Size**: M. Core entity and date math with tests, then one UI per client.
- **Risks**: month-end rules are where the bugs are (Jan 31 monthly). A schedule edited on one device while another enters an occurrence is an LWW conflict on `date_next`; the deterministic transaction id keeps the ledger correct, worst case the same occurrence is offered once more. Future-dated transactions (YNAB forbids them) need a decision: our `compute` counts by date, so a scheduled item must never become a future transaction.

### 3.4 Category goals and targets

- **What**: goal fields on `category`: type (YNAB's `TB`, `TBD`, `MF`, `NEED`; `DEBT` later), target amount, target date, cadence, whole-amount flag. A derived "underfunded this month" and a one-click "assign to meet targets".
- **Why**: it is the feature that turns the envelope table into a plan, and the part users of YNAB lean on most.
- **How it fits**: store only the inputs (`goal_type`, `goal_target`, `goal_target_date`, `goal_cadence`, `goal_cadence_frequency`, `goal_day`, `goal_needs_whole_amount`) as optional fields on `Category`, which is a pure field addition with per-field LWW. Never sync `goal_under_funded`, `goal_overall_funded`, `goal_percentage_complete` and friends; YNAB returns them but we already rule that derived numbers are not synced. Compute them in `budget.rs` next to `available`, so every client shows the same underfunded number. "Assign to meet targets" is a client command that emits `budget_entry` patches via `ledger::plan`.
- **Size**: L. The goal math is the hard part: YNAB's cadence has 15 values with two different behaviours (repeat-every versus fixed-schedule) and `NEED` has Set Aside versus Refill. Start with `MF` and `TBD`, then `TB`, then `NEED`.
- **Risks**: exact parity with YNAB is not documented in the API, only field meanings, so our numbers will differ in places; accept and document. Snoozing a goal is per-month state (`goal_snoozed_at`); skip it at first. Old clients with `deny_unknown_fields` break on the new fields until updated.

### 3.5 Cleared and reconciled states

- **What**: replace `cleared: bool` with `cleared | uncleared | reconciled`, add `last_reconciled_at` on account, and a reconcile flow: enter the bank statement balance, tick off cleared items, lock them as reconciled.
- **Why**: reconcile is how a user trusts the balance. `approved` only exists in YNAB for the imported-transaction inbox, so skip it: with manual entry there is nothing to approve.
- **How it fits**: all per-transaction fields, so LWW merges them. Keep the wire compatible: accept the old boolean as `cleared`/`uncleared` on read. Reconcile is a command in `ledger::plan` that emits patches: set `reconciled` on the chosen transactions and, if needed, a balance-adjustment transaction for the difference (YNAB does the same, with a payee "Reconciliation Balance Adjustment"). Transfer mirroring (D8) needs a rule: mirror `cleared` and `uncleared` as today, but never mirror `reconciled`, because each bank reconciles on its own day. That reverses an accepted trade-off in D8 and should be confirmed.
- **Size**: M. Model change S, reconcile UI and command M.
- **Risks**: a reconciled transaction edited later on another device. Decide the rule: edits to amount, date or account on a reconciled transaction ask for confirmation (YNAB does this); the core cannot enforce it across offline devices, only warn. The enum change touches validation on all three clients and the stored JSON, so ship with a read-both-forms period.

### 3.6 `import_id` dedup and bank import: out of scope

Decision: zero-sum takes no bank sync or file import. Every transaction is entered by hand. So no `import_id`, no importer, no matching against imported items, no unapproved inbox. The one-time YNAB migration (3.1) is the only import and uses the YNAB transaction ids directly.

### 3.7 Flags

- **What**: `flag_color` on transactions (`red, orange, yellow, green, blue, purple`, or none), filter by flag. Optional labels per colour in a settings entity.
- **Why**: cheap, useful marker for "ask about this", "tax deductible", "check receipt".
- **How it fits**: one optional field, LWW. Colour labels (`flag_name`) are plan-level state; either a small `settings` entity (also useful for 3.10) or skip the labels.
- **Size**: S.
- **Risks**: almost none. Do not mirror flags across transfer legs.

### 3.8 Delta sync: YNAB versus our ops

- **What**: a comparison, to confirm what we have is enough. No feature.
- **How they differ**:
  - YNAB: one integer, `server_knowledge`, per plan. The client sends it back and gets changed entities. Delta works per resource. Deleted rows appear only in delta responses. Writes are online REST calls, resolved by the server; the conflict signals are 409 on `import_id` duplicates and silent server-side last write for fields. No offline write queue, no per-field merge, no idempotency key on writes (a retried `POST` without `import_id` creates twice).
  - Ours: `seq` cursor, same idea as `server_knowledge`, but over one stream for all entity kinds, so one cursor per client, not per resource. Writes are idempotent by `op_id`. Per-field stamps let two offline devices both keep their edits. Tombstones are always sent so replicas converge.
- **What to borrow**: nothing structural. Two small things are worth taking: (a) YNAB's habit of returning the new `server_knowledge` on every write response, which our `push` already does via the new cursor; (b) the `duplicate_import_ids` style of reporting skipped items, which our per-op `duplicate`/`rejected` status already covers.
- **What not to borrow**: per-resource cursors. They exist because YNAB's resources are separate tables behind separate endpoints.
- **Size**: none.

### 3.9 Money movements and reporting

- **What**: (a) a "move money" action that is one logical change: take X from category A, give to B, with an optional note, and show it in a history list; (b) a few derived reports: spending by category per month, income versus expense, net worth over time, age of money.
- **Why**: moving money between envelopes is the daily action of envelope budgeting, and the history answers "why did this envelope change". Reports use data we already have.
- **How it fits**: (a) A move is two `budget_entry` patches today (A minus X, B plus X). Concurrent moves on the same pair of entries conflict under per-field LWW on `assigned`: two devices that each set the final value will overwrite one another instead of adding. That is the real weak point of the model for this action. Options: keep absolute values and accept it (single user, rare); or add a `money_movement` entity (from, to, amount, month, note, group id, as in YNAB's schema) as an immutable record and derive `assigned` as base plus sum of movements. The second is a bigger change to `budget.rs` and the entry id scheme; try the first and add a movement record only for history. (b) Reports are pure functions over a `Snapshot`, so they belong in `core` and need no sync. Age of money is the FIFO calculation over inflows and outflows; define it in core once so clients agree, as YNAB's `age_of_money` is a server number we cannot reuse.
- **Size**: S for the history record and move command, M for reports, M for age of money.
- **Risks**: derived-from-movements assigned breaks the "budget entry is an entity" simplicity, avoid unless LWW overwrites actually occur. The op log is append-only but not indexed for this use; a movement record is cleaner than reading `ops`.

### 3.10 Multi-currency and format settings

- **What**: a `settings` entity: currency (ISO code, decimal digits, separators, symbol position) and date display format, used by clients to render milliunits. Not multi-currency accounting.
- **Why**: single currency is baked in as USD-style formatting in some places. A user in IDR or JPY (zero decimals) or KWD (three decimals) needs correct formatting. YNAB's `CurrencyFormat` is a good field list, and it shows milliunits already handle 0 to 3 decimals.
- **How it fits**: one small singleton entity with a fixed id, fields merge by LWW. Formatting stays in each client, but rounding rules should be in `core` (one helper `format_amount(milliunits, CurrencyFormat)`), so the three UIs agree. True multi-currency (accounts in different currencies, exchange rates, tracking accounts) is a different and large feature; YNAB itself does not support it inside one plan. Recommend: one currency per budget, and multiple budgets if ever needed (YNAB's answer is multiple plans).
- **Size**: S for settings and formatting helper. Multi-currency: L, not recommended.
- **Risks**: changing the currency after data exists changes how every number reads without converting it; make it a set-once value with a warning.

### 3.11 Smaller items worth listing

- **Credit card payment categories**: YNAB creates one per credit card and moves money into it when you spend on the card. Architecture says not modelled. It is the biggest hole in budget parity and affects the import (3.1). M to L, core math change in `budget.rs`.
- **Account types**: extend `AccountKind` with the YNAB loan types only if loans are wanted. S, but enum changes need the same read-compat care as 3.5.
- **Month notes and income total**: `note` on the month needs a month entity or a `budget_entry`-like deterministic entity. S. Low value.
- **Hidden `internal` Inflow category**: not needed; we derive Ready to Assign.

## 4. What not to copy

- **Personal tokens, OAuth, scopes, restricted mode, default plan selection.** The design is one user on a tailnet, with no login (architecture, "Auth"). Section "Security notes" already names the fallback: a single static bearer token. That is enough.
- **Rate limiting (200 per hour).** Local server, no abuse model. A limit would only hurt sync after a long offline period.
- **Users and `performed_by_user_id` on money movements and groups.** One person. Device id on the op (already there) is the only attribution needed.
- **Subscription and trial errors (403.1, 403.2, 403.5) and data limits (403.4).** No billing, no quotas.
- **Cloud/hosted assumptions**: multi-tenant plan list, plan sharing, `last-used` plan alias, CORS for third-party web apps. Ours is one origin, served by the same server.
- **Direct import and bank linking** (`direct_import_linked`, `direct_import_in_error`, `matched_transaction_id` as server state). It needs a bank aggregator, a credential store and a public endpoint, all against the private design. Transactions are entered by hand, so no import path is needed.
- **Per-resource REST CRUD with `last_knowledge_of_server`.** Our single op stream is simpler and handles offline writes, which YNAB's API cannot.
- **Read-only restrictions** (no account update, no category delete, no editing of existing splits). These are limits of a public API surface, not design choices to match. Our clients own the data.
- **Deleted rows hidden outside deltas.** Our clients need tombstones to converge; keep sending them.
- **Payee-as-transfer-endpoint.** YNAB models "transfer to account X" as a payee. Our `transfer_account_id` on the transaction is already specified (D4) and avoids a fake-payee special case.

## 5. Recommended roadmap

Order by value for one person, then by how little rework later steps cause.

1. **Phase 1, foundation for everything else (S to M).** Settings entity and amount formatting helper (3.10); `flag_color` (3.7); payee rename and autocomplete (3.2). All are additive fields. Ship core first with `deny_unknown_fields` updated, then clients. This also lets the import carry flags and payees.
2. **Phase 2, states and import (M).** `cleared | uncleared | reconciled`, reconcile command (3.5); then the YNAB API importer (3.1) which can fill the new fields correctly and is checked against YNAB's own month numbers. Do the cleared change first so the import does not have to be redone. Decide the D8 mirroring rule for `reconciled` before coding.
3. **Phase 3, scheduled transactions (M).** Entity, frequency math in core, "enter" with deterministic occurrence ids (3.3). Independent of the above, so it can move earlier. With all entry manual, it saves the most typing.
4. **Phase 4, goals (L).** `MF` and `TBD` first, derived underfunded in `budget.rs`, then `TB` and `NEED` (3.4). Highest effort, so after the data is real.
5. **Phase 5, reporting and money movement history (S to M).** Move-money record and history, spending and net worth reports, age of money (3.9). Credit card payment categories (3.11) belong here or earlier if the imported budget has cards, because they change `budget.rs` numbers.

Cross-cutting: every phase adds fields, so keep the rule "core release first, then clients" and add a test per new field in `crates/core` that an old payload still validates. Update `docs/architecture.md` ("Not modelled yet") as each item lands. Decide open question 2 (importer) now: this note recommends API import by one-off script, not a long-lived feature.
