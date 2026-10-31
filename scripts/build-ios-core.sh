#!/usr/bin/env bash
# Build the Rust core for Apple platforms and generate its Swift bindings.
#
# Needs macOS with Xcode and rustup. Output, both git-ignored:
#   clients/ios/Frameworks/zero_sum_ffiFFI.xcframework   static library, iOS device + simulator + macOS
#   clients/ios/Sources/ZeroSumFFI/zero_sum_ffi.swift    UniFFI Swift bindings
#
# Run it again whenever crates/core or crates/ffi change.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
ios="$root/clients/ios"
lib=libzero_sum_ffi.a
targets=(aarch64-apple-ios aarch64-apple-ios-sim aarch64-apple-darwin)

# Keep in step with Package.swift and project.yml.
export IPHONEOS_DEPLOYMENT_TARGET=17.0
export MACOSX_DEPLOYMENT_TARGET=14.0

cd "$root"
rustup target add "${targets[@]}"
for t in "${targets[@]}"; do
  cargo rustc -p zero-sum-ffi --lib --release --target "$t" --crate-type staticlib
done

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Swift bindings come from the metadata inside the compiled library.
cargo run -q -p zero-sum-ffi --features bindgen --bin uniffi-bindgen -- \
  generate --library "target/aarch64-apple-darwin/release/$lib" \
  --language swift --out-dir "$work/gen"

mkdir -p "$work/headers"
cp "$work/gen/zero_sum_ffiFFI.h" "$work/headers/"
cp "$work/gen/zero_sum_ffiFFI.modulemap" "$work/headers/module.modulemap"

out="$ios/Frameworks/zero_sum_ffiFFI.xcframework"
rm -rf "$out"
mkdir -p "$ios/Frameworks"
args=()
for t in "${targets[@]}"; do
  args+=(-library "target/$t/release/$lib" -headers "$work/headers")
done
xcodebuild -create-xcframework "${args[@]}" -output "$out"

cp "$work/gen/zero_sum_ffi.swift" "$ios/Sources/ZeroSumFFI/zero_sum_ffi.swift"
echo "ok: $out"
