#!/usr/bin/env bash
# Build the Rust core library and server for this machine, then run all Dart tests.
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cargo build --manifest-path "$root/Cargo.toml" -p zero-sum-ffi-c -p zero-sum-server
ext=so; [ "$(uname)" = Darwin ] && ext=dylib
export ZERO_SUM_FFI="$root/target/debug/libzero_sum_ffi_c.$ext"
export ZERO_SUM_SERVER="$root/target/debug/zero-sum-server"
cd "$root/clients/android"
flutter analyze --no-fatal-infos
flutter test "$@"
