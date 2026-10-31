# zero-sum architecture

Private, single-user envelope budgeting (YNAB style). One Rust server on a Mac mini. Three clients: iOS, Android, web. All stay in sync. No accounts, no login.

This document records the decisions and why. Status: server, shared core and web client are in this repo. iOS and Android clients are not started.

## Decisions at a glance

| Area | Decision |
| --- | --- |
| Sync | Offline-first clients. Op log on the server. Per-field last-writer-wins. |
| Storage | SQLite (WAL) on the Mac mini. SQLite on every client. |
| API | JSON over HTTP for push and pull. One WebSocket that only says "something changed". |
| Money | Integer milliunits (`i64`). No floats. |
| Shared logic | One Rust `core` crate: model, merge rules, budget math. Reused by all clients. |
| Reachability | Tailscale. Server never exposed to the public internet. |
| Auth | None in the app. The tailnet is the access control. |

## Sync strategy

**Choice: offline-first with an op log and per-field last-writer-wins (LWW).**

Each client keeps a full local copy in SQLite and works with no network. Every edit becomes an op: a patch to one entity (`kind`, `entity_id`, `fields`, optional `deleted`) with a client-generated `op_id` and a client timestamp. Clients push queued ops when online and pull entity changes since a cursor.

The server merges each field independently. The write with the highest `(ts, op_id)` wins. This merge is commutative and idempotent, so ops may arrive late, twice, or out of order and every replica ends in the same state.

Why not the alternatives:

- **Server-authoritative, online only.** Fails offline. Phones are offline often enough that this would hurt daily use.
- **Whole-entity LWW.** Loses edits. Device A edits a memo offline, device B changes the amount, and one change disappears. Per-field merge keeps both.
- **Full CRDT (Automerge, Yjs).** Heavy, and it buys nothing here. There is one writer at a time (Deni), conflicts are rare, and the data is flat records, not collaborative text. Per-field LWW gives the same convergence for this shape of data.

Details:

- **Idempotency.** The server records every `op_id`. A retried push returns `duplicate` and changes nothing.
- **Pull is state, not ops.** `GET /sync/pull?since=N` returns entities whose last change has `seq > N`, each with its per-field stamps. Clients do not replay history. A new device pulls from `since=0`.
- **Deletes are tombstones.** `deleted` is merged like a field, so a delete and a restore resolve by timestamp.
- **Derived numbers are never synced.** Available, activity, and Ready to Assign are computed from entities. Syncing derived values is how budgets drift.
- **Budget entries have deterministic ids.** The id of "assigned to category C in month M" is a UUIDv5 of `(C, M)`. Two devices that both create it offline write the same entity. The server rejects any other id.
- **Bad ops do not fail the batch.** Each op gets its own status: `applied`, `stale`, `duplicate`, or `rejected` with a reason.

Known limits, accepted:

- **Clock skew.** LWW trusts client clocks. For one person with three personal devices on automatic time this is fine. If it ever bites, replace `ts` with a hybrid logical clock. The wire format does not change shape.
- **No history UI.** The op log is kept, so undo and audit can be built later. Nothing uses it yet.

## Storage

**Choice: SQLite.**

One user, small data, one server process. SQLite in WAL mode is simple, fast, and backed up by copying a file. No database service to run on the Mac mini. Postgres adds an operational burden with no benefit at this scale.

Server tables:

- `ops`: append-only log. `seq` is the server's monotonic sequence number.
- `entities`: merged state as JSON plus per-field stamps, keyed by `(kind, id)`, indexed by `seq`.

JSON-in-a-row keeps the sync layer generic. Entities are validated against typed Rust structs on every write, so the JSON is never free-form. If a query needs a typed column later, add it.

Backups: the `.db` file. Suggested: `sqlite3 zero-sum.db ".backup backup.db"` on a schedule, copied off the machine.

## API

**Choice: plain JSON over HTTP, plus one notification WebSocket.**

| Endpoint | Purpose |
| --- | --- |
| `POST /sync/push` | Send ops. Returns a status per op and the new cursor. |
| `GET /sync/pull?since=N&limit=M` | Entities changed after `N`. Paginated. |
| `GET /sync/ws` | Server sends `{"type":"changed","cursor":N}`. Client then pulls. |
| `GET /budget/{month}` | Derived budget for `YYYY-MM`. Reference implementation and a handy debug view. |
| `GET /health` | Liveness. |

The WebSocket carries no data, only a nudge. If it drops, nothing is lost: clients also pull on launch, on foreground, and after every push. This keeps the realtime path trivially correct.

Why not GraphQL or gRPC: three clients, a handful of endpoints, no need for a schema toolchain on each platform. JSON is native everywhere.

## Entities

All amounts are `i64` milliunits (1000 = 1.00). Inflow positive, outflow negative.

- `account`: name, kind, `on_budget`, closed.
- `category_group` and `category`: name, order, hidden.
- `payee`: name.
- `transaction`: account, date (`YYYY-MM-DD`), amount, payee, category, optional `transfer_account_id`, memo, cleared.
- `budget_entry`: category, month (`YYYY-MM`), assigned.

Budget rules (in `crates/core/src/budget.rs`):

- `available = carry-in + assigned + activity`.
- Positive available carries to next month.
- Negative available resets to 0 and reduces next month's Ready to Assign.
- An uncategorized inflow in an on-budget account is income.
- A transfer between two on-budget accounts is ignored. Off-budget accounts never count.

Not modelled yet: split transactions, credit card payment categories, goals and targets, scheduled transactions, reconciliation, multiple budgets, currencies.

## Clients

**Choice: native on iOS and Android, a PWA on web, all sharing one Rust core.**

| Client | Stack | Local store |
| --- | --- | --- |
| iOS | Swift, SwiftUI | SQLite via GRDB |
| Android | Kotlin, Jetpack Compose | SQLite via Room |
| Web | TypeScript, a PWA | SQLite in WASM (OPFS) or IndexedDB |

The merge rules and budget math are the part most likely to diverge between three codebases, and divergence means different numbers on different devices. So they live once, in `zero-sum-core`:

- iOS and Android call it through UniFFI bindings.
- Web calls it as WASM.
- The server links it directly.

UI stays native per platform. Only logic is shared.

Alternatives considered:

- **One cross-platform UI (Flutter, React Native, Kotlin Multiplatform).** One UI codebase, but a weaker fit on iOS and a heavier toolchain. Reasonable if the aim is to ship fast and care less about platform feel. Open to switching if Deni prefers this. It does not change the server.
- **Web app only, installed to home screens.** Cheapest by far, but weak offline and background behaviour on iOS. Worth building first as a prototype, since the web client is needed anyway.

Suggested order: web first (fastest feedback on the model), then iOS, then Android.

Status: the web client exists in `clients/web`. It uses IndexedDB for local storage, a service worker for offline loading, and the Rust core through `crates/wasm`. The server can serve it from the same origin (`ZERO_SUM_WEB_DIR`). iOS and Android are not started.

## Reaching the Mac mini safely

The server has no auth, so it must not be reachable from the open internet.

**Choice: Tailscale.**

1. Install Tailscale on the Mac mini and every device.
2. Bind the server to localhost: `ZERO_SUM_ADDR=127.0.0.1:8787`.
3. Run `tailscale serve --bg 8787`. This gives `https://<mac-mini>.<tailnet>.ts.net` with a real certificate, reachable only by devices on the tailnet.
4. Point all clients at that URL.

Why HTTPS matters: iOS blocks plain HTTP by default, and browsers block a secure page from calling an insecure API. `tailscale serve` solves both with no cert handling in the app.

Do not use port forwarding, a public tunnel, or `0.0.0.0` on an untrusted network. If a device is lost, remove it from the tailnet.

Run the server as a launchd service so it starts at boot and restarts on failure. A sample plist is not included yet.

Alternatives: WireGuard directly (same idea, more manual), Cloudflare Tunnel with Access (public hostname with an auth layer; more moving parts and it adds a login after all).

## Security notes

- CORS is permissive because the tailnet is the boundary. Tighten it if the server is ever exposed differently.
- The data is financial. Enable FileVault on the Mac mini and keep encrypted backups.
- If the threat model changes (shared tailnet, other users), add a single static bearer token. One middleware, no user model.

## Open questions

1. **Cross-platform UI vs native.** Recommendation above is native plus shared Rust core. Say so if one UI codebase matters more.
2. **Import.** Do you want a YNAB export importer (CSV or API)? It would be a script that emits ops.
3. **Currency.** Single currency assumed.
