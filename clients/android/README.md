# zero-sum Android client

Flutter app. Offline-first: all reads and writes hit local SQLite (`sqflite`). Edits queue in an outbox and sync to the Rust server by op-log push and pull. A WebSocket only nudges "pull now". Same protocol and behaviour as `clients/web`.

Merge rules and budget math are not re-implemented in Dart. The app calls the shared `zero-sum-core` through `crates/ffi-c` (C ABI, JSON strings) with `dart:ffi`, so Android shows the same numbers as the server and web.

## Layout

- `lib/core.dart`: `dart:ffi` bridge (`merge`, `budget`, `budgetEntryId`).
- `lib/db.dart`: SQLite store, outbox, push and pull, WebSocket, reconnect. Port of `clients/web/src/db.ts`.
- `lib/ledger.dart`: transfer pairs, splits and category delete (port of `clients/web/src/ledger.ts`, see `docs/ledger-edits-spec.md`).
- `lib/app.dart`: Budget (with Orphaned section), Transactions (add, edit, transfer, split) and Accounts screens, server URL dialog.
- `lib/money.dart`: milliunit formatting and parsing.

## Test

Builds the Rust library and server for this machine, then runs Dart tests (including two devices syncing through the real server).

```sh
clients/android/tool/test.sh
```

Needs Flutter 3.47+ and `libsqlite3` on the host.

## Build the app

```sh
clients/android/tool/build_core.sh     # Rust core into jniLibs (needs Android NDK, see script)
cd clients/android && flutter run      # or: flutter build apk
```

On first launch the app asks for the server URL, for example `https://<mac-mini>.<tailnet>.ts.net`. Change it later with the gear icon. Release builds accept HTTPS only (use `tailscale serve`). Debug builds also allow plain `http://`.
