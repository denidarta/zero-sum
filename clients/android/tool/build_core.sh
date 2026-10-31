#!/usr/bin/env bash
# Cross-compile the Rust core (crates/ffi-c) for Android into the APK's jniLibs.
# One-time: rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
#           cargo install cargo-ndk --locked
#           export ANDROID_NDK_HOME=<path to NDK>
set -euo pipefail
root="$(cd "$(dirname "$0")/../../.." && pwd)"
cargo ndk -t arm64-v8a -t armeabi-v7a -t x86_64 \
  -o "$root/clients/android/android/app/src/main/jniLibs" \
  build --release -p zero-sum-ffi-c --manifest-path "$root/Cargo.toml"
