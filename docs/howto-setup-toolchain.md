# How to set up the toolchain

Type: How-to guide · Product: zero-sum · Audience: developer (internal)

Goal: build, test and run the server and all three clients (web, iOS, Android) on an Apple Silicon Mac.

Each part stands alone. Do Part 1 first, then only the clients you need.

| Part | Needed for |
| --- | --- |
| 1. Rust and the server | Everything. All clients share the Rust core. |
| 2. Web client | `clients/web` |
| 3. iOS client | `clients/ios` |
| 4. Android client | `clients/android` |

## Prerequisites

- macOS on Apple Silicon. The iOS simulator slice is arm64 only.
- [Homebrew](https://brew.sh). Check with `brew --version`.
- Git, with the repository cloned.

The commands below pin the versions CI uses (`.github/workflows/ci.yml`) or the versions the repository requires. Newer versions usually work, but CI does not test them.

## 1. Install Rust and run the server

1. Install `rustup`, the Rust toolchain manager:

   ```sh
   curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
   ```

   Accept the default stable toolchain. The installer adds `. "$HOME/.cargo/env"` to your shell profile. Open a new terminal afterwards.

   If you install with `brew install rustup` instead, Homebrew does not put `cargo` and `rustc` on your `PATH`. Add the keg to `~/.zshrc`, then run `rustup default stable`:

   ```sh
   export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
   ```

2. Check the install:

   ```sh
   rustc --version
   cargo --version
   ```

3. Add the formatter and linter that CI runs:

   ```sh
   rustup component add clippy rustfmt
   ```

4. Run the Rust tests and lints from the repository root:

   ```sh
   cargo fmt --check
   cargo clippy --all-targets -- -D warnings
   cargo test
   ```

5. Start the server:

   ```sh
   cargo run -p zero-sum-server
   ```

   It listens on `127.0.0.1:8787` and writes `zero-sum.db` in the current directory. Override with `ZERO_SUM_ADDR` and `ZERO_SUM_DB`.

6. In a second terminal, check that it is up:

   ```sh
   curl -sf http://127.0.0.1:8787/health
   ```

Expected result: the `curl` command succeeds and `cargo test` passes.

## 2. Set up the web client

1. Install Node.js 22 (the version CI uses). npm comes with it:

   ```sh
   brew install node@22
   ```

   `node@22` is keg-only. Add `export PATH="/opt/homebrew/opt/node@22/bin:$PATH"` to `~/.zshrc`, or use `brew install node` for the current release.

2. Add the WebAssembly target and the matching `wasm-bindgen` CLI. The version must equal the `wasm-bindgen` dependency in `crates/wasm/Cargo.toml` exactly.

   ```sh
   rustup target add wasm32-unknown-unknown
   cargo install wasm-bindgen-cli --version 0.2.130 --locked
   ```

3. Install dependencies and build:

   ```sh
   cd clients/web
   npm ci
   npm run build
   ```

   `npm run build` compiles the Rust core to WASM, type-checks, then runs Vite.

4. Serve the built app from the server:

   ```sh
   cd ../..
   ZERO_SUM_WEB_DIR=clients/web/dist cargo run -p zero-sum-server
   ```

   Open <http://127.0.0.1:8787>.

5. For development with live reload, run the server in one terminal and `npm run dev` in `clients/web` in another. Vite proxies API calls to port 8787.

6. To run the end-to-end test (two browsers, offline edit, convergence), build the server and the client first, then run:

   ```sh
   node clients/web/e2e/smoke.mjs
   ```

   The script needs Playwright. It is not in `package.json`. Install it in `clients/web` with `npm install --no-save playwright`, then `npx playwright install chromium`.

Expected result: the app loads at <http://127.0.0.1:8787> and `npm run typecheck` passes.

## 3. Set up the iOS client

1. Install Xcode 16 or later from the Mac App Store. CI uses Xcode on `macos-15`. The Command Line Tools alone are not enough: `scripts/build-ios-core.sh` calls `xcodebuild -create-xcframework`, which needs full Xcode.

2. Point the command-line tools at Xcode, accept the license and finish first-launch setup. Each command asks for your password:

   ```sh
   sudo xcode-select --switch /Applications/Xcode.app/Contents/Developer
   sudo xcodebuild -license accept
   sudo xcodebuild -runFirstLaunch
   ```

3. Check that `xcodebuild` works:

   ```sh
   xcode-select -p
   xcodebuild -version
   ```

   `xcode-select -p` must print a path inside `Xcode.app`, not `/Library/Developer/CommandLineTools`.

4. Install an iOS Simulator runtime if Xcode has none: Xcode → Settings → Components. The app targets iOS 17 or later.

5. Install XcodeGen. It generates `ZeroSum.xcodeproj` from `clients/ios/project.yml`:

   ```sh
   brew install xcodegen
   ```

6. Build the Rust core for Apple platforms. The script adds the Rust targets (`aarch64-apple-ios`, `aarch64-apple-ios-sim`, `aarch64-apple-darwin`) itself. Rerun it after any change in `crates/`.

   ```sh
   scripts/build-ios-core.sh
   ```

7. Run the Swift tests. Start the server first (Part 1, step 5) to include the end-to-end tests:

   ```sh
   cd clients/ios
   ZERO_SUM_TEST_SERVER=http://127.0.0.1:8787 swift test
   ```

   Omit the variable to skip the end-to-end tests.

8. Generate the project and build for the simulator:

   ```sh
   xcodegen
   xcodebuild build -project ZeroSum.xcodeproj -scheme ZeroSum \
     -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO
   ```

9. To run the app, open `ZeroSum.xcodeproj`, choose your team under Signing & Capabilities, pick a simulator or device and press Run. In the app, open Settings and enter the server address.

Expected result: `swift test` passes and the `xcodebuild` command ends with `BUILD SUCCEEDED`.

## 4. Set up the Android client

The host tests need only Rust and Flutter (steps 1–2). Building and running the app also needs the JDK, the Android SDK, the NDK and the Rust Android targets (steps 3–7).

1. Install Flutter stable 3.47 or later, following the [Flutter macOS install guide](https://docs.flutter.dev/get-started/install/macos) or `brew install --cask flutter`. Check with:

   ```sh
   flutter --version
   ```

2. Run the host tests. This builds the Rust core and the server for your Mac, then runs `flutter analyze` and `flutter test`:

   ```sh
   clients/android/tool/test.sh
   ```

   macOS ships `libsqlite3`, so nothing else is required.

3. Install JDK 17. Gradle 9.3.1 (from `gradle-wrapper.properties`) and the app's `build.gradle.kts` both target Java 17:

   ```sh
   brew install --cask temurin@17
   ```

   Add to `~/.zshrc`:

   ```sh
   export JAVA_HOME="$(/usr/libexec/java_home -v 17)"
   ```

   Android Studio's bundled JDK also works. In that case run `flutter config --jdk-dir <path to its jbr>`.

4. Install the Android SDK. The simplest route is [Android Studio](https://developer.android.com/studio): on first launch it installs the SDK to `~/Library/Android/sdk`. Then, in Android Studio → Settings → Android SDK → SDK Tools, install:
   - Android SDK Command-line Tools
   - Android SDK Platform-Tools
   - Android Emulator
   - NDK (Side by side) version `28.2.13676358`. This is the NDK that Flutter 3.47 selects (`flutter.ndkVersion`). If you upgrade Flutter, check the version in `packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt`.
   - Android SDK Platform 36 (`compileSdk` is 36)

   Command-line Tools alone work too: `brew install --cask android-commandlinetools`, then `sdkmanager` with the package names above.

5. Set the environment variables in `~/.zshrc`, then open a new terminal:

   ```sh
   export ANDROID_HOME="$HOME/Library/Android/sdk"
   export ANDROID_NDK_HOME="$ANDROID_HOME/ndk/28.2.13676358"
   export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$ANDROID_HOME/cmdline-tools/latest/bin:$PATH"
   ```

6. Accept the SDK licenses and check the setup:

   ```sh
   flutter doctor --android-licenses
   flutter doctor
   ```

   The Android toolchain line must show a check mark.

7. Install the Rust Android targets and `cargo-ndk`:

   ```sh
   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
   cargo install cargo-ndk --locked
   ```

8. Create an emulator. In Android Studio, open Device Manager → Create Virtual Device, and pick an arm64 system image. Or use `avdmanager`. Start it, then confirm Flutter sees it:

   ```sh
   flutter devices
   ```

9. Cross-compile the Rust core into `jniLibs`, then run the app. Rerun the first command after any change in `crates/`.

   ```sh
   clients/android/tool/build_core.sh
   cd clients/android
   flutter run
   ```

   On first launch, enter the server URL. For the emulator, the host machine is `http://10.0.2.2:8787`. Debug builds accept plain `http://`. Release builds accept HTTPS only.

Expected result: `clients/android/tool/test.sh` passes, `flutter build apk --debug` succeeds, and the app runs on the emulator.

## Troubleshooting

| Symptom | Cause and fix |
| --- | --- |
| `xcode-select: error: tool 'xcodebuild' requires Xcode, but active developer directory '/Library/Developer/CommandLineTools' is a command line tools instance` | Xcode is missing or not selected. Do Part 3, steps 1–3. |
| `The operation couldn't be completed. Unable to locate a Java Runtime.` | `/usr/bin/java` is a stub. Install JDK 17 and set `JAVA_HOME` (Part 4, step 3). |
| `cargo: command not found` after `brew install rustup` | Homebrew's `rustup` is keg-only. Add `/opt/homebrew/opt/rustup/bin` to `PATH` (Part 1, step 1). |
| `flutter doctor`: `Unable to locate Android SDK` | Set `ANDROID_HOME`, or run `flutter config --android-sdk <path>` (Part 4, steps 4–5). |
| `cargo ndk` cannot find the NDK | Set `ANDROID_NDK_HOME` to the NDK directory (Part 4, step 5). |
| `wasm-bindgen` schema or version mismatch during `npm run build` | The CLI must be exactly `0.2.130`. Reinstall with `cargo install wasm-bindgen-cli --version 0.2.130 --locked --force`. |
| iOS simulator build fails with an `x86_64` error | The Rust core is arm64-only. Use an Apple Silicon Mac. |

## Related

- [Architecture](architecture.md): sync, storage and client design.
- [Ledger edits spec](ledger-edits-spec.md)
- [README](../README.md): layout and a short run guide.
