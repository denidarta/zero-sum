# Ledger edits spec: deletes, transfers, splits, editing

Status: core rules implemented (PR 1). Clients not yet. Decisions below were made by Deni in the planning thread on 2026-10-31. Open items are listed at the end.

## Problem

1. Deleting a category group tombstones only the group. Its categories stay live, so `budget::compute` still counts their assigned money and activity. Every client renders categories under their group, so that money becomes invisible and Ready to Assign drops. Affected: web, iOS (`BudgetView.swift`), Android (`app.dart`).
2. Deleting a category makes its transactions drop out of budget math (`budget.rs`, "category deleted"). Spending vanishes.
3. Transfers, split transactions and editing existing transactions are missing on every client.

## Decisions

### D1. Deleting a category group

Block the delete while the group still has live categories. The client tells the user to move or delete the categories first. Same rule on web, iOS and Android.

### D2. Category whose group is deleted or missing

Merge stays order-independent, so the server never rejects a group delete. Another device can still create a category in a group that a second device deletes offline. Clients must show any live category whose group is missing or deleted under a synthetic **Orphaned** group. The user can move or delete those categories. Money never becomes invisible.

The grouping rule lives in the shared core so all clients agree. Clients do not reimplement it.

### D3. Deleting a category

If the category has transactions, the client prompts for one of:

- **Delete the transactions** linked to the category, or
- **Move them to another category** (user picks the target).

Assigned money returns to Ready to Assign. The category's `budget_entry` rows are tombstoned with the category, so the money is no longer assigned anywhere.

Proposed, not yet confirmed by Deni: budget math should never silently drop a transaction. A transaction whose category is deleted (for example from a concurrent edit on another device) would count as uncategorized instead of being skipped. This replaces the current `Some(_) => continue` behavior.

### D4. Transfers are two linked transactions

A transfer is one outflow transaction in the source account and one inflow transaction in the destination account. Each carries `transfer_account_id` and points at its partner. Editing or deleting one leg updates both. The pair exists on every client.

### D5. Transfers across the budget boundary need a category

A transfer between an on-budget and an off-budget account must carry a category. Moving money out counts as spending in that category. Money in from an off-budget account counts as income, as it does today. A transfer between two on-budget accounts has no category and is ignored by budget math. A transfer between two off-budget accounts is ignored too.

### D6. Splits are an array field on the transaction

A split transaction holds a `splits` list of `{category_id, amount, memo}` lines. The line amounts must sum to the transaction amount. The list is one field, so concurrent edits resolve as a whole under last-writer-wins. Budget math attributes each line to its category.

### D7. Split lines are categories only

A split line carries a category. A transfer cannot be split, and a split line cannot be a transfer. Revisit later if needed. Existing splits would not need a data change.

### D8. Editing a transfer leg mirrors every field

Editing one leg of a transfer updates the other leg in the same change, with the amount sign flipped. This covers amount, date, memo and cleared. Accounts on an existing pair cannot be changed. The user deletes the transfer and creates a new one.

Trade-off accepted: cleared status now mirrors, although the two banks may clear on different days.

### D9. Rollout

1. PR 1: shared core and server rules, with tests. Covers the Orphaned grouping, the deleted-category fallback, split math, and the transfer pair rules.
2. PR 2 to 4: web, iOS and Android, one PR each. Each client adds the delete guards, transfers, splits and transaction editing against the finished core.

### D10. Edits never convert a transaction

An edit cannot turn a regular transaction into a transfer, or a transfer into a regular transaction. The user deletes and recreates. Edits therefore never create or remove a partner leg.

## Open

Not asked yet. Defaults below apply unless Deni objects.

- Deleted-category fallback (see D3): a transaction with a deleted category counts as uncategorized instead of being skipped. Proposed by Claude, not confirmed.
- Concurrent transfer edits: one device deletes a leg while another edits its partner offline. Default: the surviving leg shows as an unmatched transfer and the user fixes it by hand. Core should flag it.
- Editing a regular transaction: all fields are editable (date, amount, payee, category, memo, cleared, account), except the transfer rules above. Split sum must equal amount; clients block save otherwise.
- Existing orphans: categories already hidden by the old group delete bug appear under Orphaned after PR 1, with no data migration.
