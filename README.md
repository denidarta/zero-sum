# zero-sum

A private, single-user YNAB-style envelope budget. Rust server, offline-first clients (iOS, Android, web) kept in sync.

Design and decisions: [docs/architecture.md](docs/architecture.md).

## Layout

- `crates/core`: entity model, sync merge rules, budget math. No I/O. Shared with clients.
- `crates/server`: axum HTTP and WebSocket server, SQLite storage.

## Run

```sh
cargo run -p zero-sum-server
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZERO_SUM_ADDR` | `127.0.0.1:8787` | Listen address |
| `ZERO_SUM_DB` | `zero-sum.db` | SQLite file |

There is no authentication. Keep the server on localhost and expose it only through Tailscale. See the architecture doc.

## Try it

```sh
curl -s localhost:8787/sync/push -H 'content-type: application/json' -d '{
  "device_id": "laptop",
  "ops": [{
    "op_id": "11111111-1111-4111-8111-111111111111",
    "ts": 1761900000000,
    "kind": "account",
    "entity_id": "22222222-2222-4222-8222-222222222222",
    "fields": {"name": "Checking", "kind": "checking"}
  }]
}'
curl -s 'localhost:8787/sync/pull?since=0'
curl -s localhost:8787/budget/2026-10
```

## Test

```sh
cargo test
cargo clippy --all-targets
```
