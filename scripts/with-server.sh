#!/usr/bin/env bash
# Run a command against a throwaway server: free port, temp database, never the real budget.
# Exports ZERO_SUM_TEST_SERVER for the command, then stops the server and deletes the database.
#
#   scripts/with-server.sh swift test        # from clients/ios
set -euo pipefail
[ $# -gt 0 ] || { echo "usage: $0 <command> [args...]" >&2; exit 2; }
root="$(cd "$(dirname "$0")/.." && pwd)"

cargo build --manifest-path "$root/Cargo.toml" -p zero-sum-server
port="$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')"
tmp="$(mktemp -d)"
ZERO_SUM_ADDR="127.0.0.1:$port" ZERO_SUM_DB="$tmp/test.db" "$root/target/debug/zero-sum-server" &
pid=$!
trap 'kill "$pid" 2>/dev/null || true; rm -rf "$tmp"' EXIT

url="http://127.0.0.1:$port"
for _ in $(seq 1 50); do curl -sf "$url/health" >/dev/null && break; sleep 0.2; done
curl -sf "$url/health" >/dev/null  # fail here, with the right error, if it never came up

ZERO_SUM_TEST_SERVER="$url" "$@"
