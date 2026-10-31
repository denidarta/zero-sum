# zero-sum

A private, single-user YNAB-style envelope budget. Rust server, offline-first clients (iOS, Android, web) kept in sync.

Design and decisions: [docs/architecture.md](docs/architecture.md).

## Layout

- `crates/core`: entity model, sync merge rules, budget math. No I/O. Shared with clients.
- `crates/server`: axum HTTP and WebSocket server, SQLite storage.
- `crates/wasm`: `core` compiled to WASM for the web client.
- `crates/ffi-c`: `core` behind a C ABI for the Android client.
- `clients/android`: offline-first Flutter app. Calls the same Rust core through `dart:ffi`. See its README.
- `clients/web`: offline-first web app (Preact, TypeScript, PWA). Runs the same Rust merge and budget code as the server.

## Run

```sh
cargo run -p zero-sum-server
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZERO_SUM_ADDR` | `127.0.0.1:8787` | Listen address |
| `ZERO_SUM_DB` | `zero-sum.db` | SQLite file |

There is no authentication. Keep the server on localhost and expose it only through Tailscale. See the architecture doc.

## Web client

One-time setup: `rustup target add wasm32-unknown-unknown`, `cargo install wasm-bindgen-cli --version 0.2.130 --locked`.

```sh
cd clients/web
npm install
npm run build
cd ../..
ZERO_SUM_WEB_DIR=clients/web/dist cargo run -p zero-sum-server
```

Open http://127.0.0.1:8787. The server serves the app from the same origin, so there is no CORS to configure. For development, `npm run dev` proxies API calls to a server on port 8787.

End-to-end test (two browsers, offline edit, convergence): `node clients/web/e2e/smoke.mjs`. It needs Playwright and a built server and client.

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
