#!/usr/bin/env bash
# Format every part of the project with its language's formatter.
#
#   scripts/format.sh           # rewrite files
#   scripts/format.sh --check   # change nothing, exit 1 if anything is unformatted
#
# web (ts/tsx/json/css/md) -> prettier    rust -> cargo fmt
# ios (swift)              -> swift format    android (dart) -> dart format
# A missing formatter is skipped with a warning; it does not fail the run.
set -uo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
export PATH="$HOME/.cargo/bin:$PATH"

check=0
case "${1:-}" in
  "") ;;
  --check) check=1 ;;
  *) echo "usage: $0 [--check]" >&2; exit 2 ;;
esac

failed=()

# run <name> <tool> <dir> <write-cmd...> -- <check-cmd...>
run() {
  local name="$1" tool="$2" dir="$3"; shift 3
  local write=() checkcmd=()
  while [ "$1" != "--" ]; do write+=("$1"); shift; done
  shift
  checkcmd=("$@")

  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "skip  $name ($tool not found)"
    return
  fi
  echo "run   $name"
  if [ "$check" = 1 ]; then
    (cd "$dir" && "${checkcmd[@]}") || failed+=("$name")
  else
    (cd "$dir" && "${write[@]}") || failed+=("$name")
  fi
}

run web npx "$root/clients/web" \
  npx prettier --write . -- npx prettier --check .
run rust cargo "$root" \
  cargo fmt --all -- cargo fmt --all --check
# swift format has no "would change" exit code (lint checks rules, not layout), so diff each file.
run ios xcrun "$root/clients/ios" \
  xcrun swift format format --in-place --recursive Sources Tests App -- \
  sh -c 'bad=0; for f in $(find Sources Tests App -name "*.swift"); do
    xcrun swift format "$f" | diff -q - "$f" >/dev/null || { echo "unformatted: $f"; bad=1; }
  done; exit $bad'
run android dart "$root/clients/android" \
  dart format lib test tool -- dart format --output=none --set-exit-if-changed lib test tool

if [ "${#failed[@]}" -gt 0 ]; then
  echo "failed: ${failed[*]}" >&2
  exit 1
fi
