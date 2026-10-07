# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A Flutter showcase app (`hcm_app_installer`, `lib/`) for a self-hosted APK auto-updater that doesn't need the Play Store, plus the two plugin packages it's built on, which are developed in-tree under `packages/`:

- `packages/digit_installer`: the update lifecycle (manifest check, download, verification, Android install).
- `packages/digit_downloader`: a generic resumable, chunked HTTP download engine. It knows nothing about APKs or updates.

The dependency chain is app → `digit_installer` → `digit_downloader`. All of it is wired to local paths through `dependency_overrides`: the root `pubspec.yaml` and `pubspec_overrides.yaml` for the app, and `packages/digit_installer/pubspec_overrides.yaml` for the package. Edits to the packages take effect in the app immediately.

Code comments and the `digit_downloader` README sometimes mention `just_installer` / `JustInstallerConfig`. That's the old name of `digit_installer` / `DigitInstallerConfig`.

## Commands

The project is pinned to **Flutter 3.22.2 (Dart 3.4.3)** in `.fvmrc`. Always use `fvm flutter …`. A global `flutter` may be a different version, and running it rewrites `android/local.properties`, `pubspec.lock` and the generated plugin registrants. `.vscode/settings.json` points the Dart extension at `.fvm/versions/3.22.2`, which `fvm use` creates.

If a build fails in `:gradle:compileKotlin` with "Language version 1.4 is no longer supported", it was run with a newer Flutter. Check `flutter.sdk` in `android/local.properties`. That Flutter's migrator also adds `android.builtInKotlin` / `android.newDsl` to `android/gradle.properties`; both are ignored under AGP 7.3.

Run each package's commands from that package's own directory. Each one is a separate pub package.

```bash
fvm flutter pub get                   # in the root and in each packages/* dir
fvm flutter analyze                   # root or any package dir
fvm flutter test                      # in packages/digit_installer or packages/digit_downloader
fvm flutter test test/digit_installer_facade_test.dart --plain-name "some test name"   # single test
fvm flutter run                       # install only works on an Android device
fvm flutter build apk --release
(cd android && ./gradlew :digit_installer:testDebugUnitTest)   # Kotlin plugin unit tests
```

The root app has no `test/` directory. All Dart tests live in the packages.

### Staying compatible with Flutter 3.22.2

- **Dart 3.4 language level.** Don't use null-aware collection elements (`?x`), dot shorthands (`.value`), wildcard `_` variables (repeated `_` parameters are a duplicate-name error), or digit separators.
- **Flutter 3.22 APIs only.** For example, there's no `Column`/`Row` `spacing:` (added in 3.27; use `SizedBox` gaps) and no `Color.withValues`.
- **Dependency versions must still resolve on Dart 3.4.3.** For example, `package_info_plus` is held at `^8` because 10.x needs Dart 3.10, and the packages use `flutter_lints ^4`.
- **Android toolchain**, from the 3.22 template:
  - Gradle 7.6.3, AGP 7.3.0, Kotlin 1.8.22 (`android/settings.gradle`).
  - Kotlin must stay ≥ 1.8.22. Older versions hit duplicate `kotlin-stdlib-jdk7/jdk8` classes from `androidx.core:1.13.1`.
  - The plugins' `build.gradle.kts` apply `kotlin-android` explicitly, since AGP 7 has no built-in Kotlin. They use compileSdk 34 and Java/JVM target 1.8, and their `buildscript` versions mirror the host's.
  - The host app pins `minSdk = 24` because both plugins require it.
- **Release-build noise.** Release builds print `e: … incompatible version of Kotlin … expected version is 1.6.0` from `:app:lintVitalAnalyzeRelease`. AGP 7.3's lint bundles an older Kotlin compiler. The messages are non-fatal and can be ignored.
- **iOS deployment target is 13.0**, because `digit_downloader`'s Swift code uses `CryptoKit`.

## Architecture

### `digit_installer`: a facade plus a sealed-state stream

- `DigitInstaller` (`lib/src/digit_installer.dart`) is the only entry point. Its methods (`checkForUpdate`, `download`, `install`, `pauseDownload`, …) return nothing useful. Every result is pushed as an `UpdateState` into `updates`, a **synchronous** broadcast stream, so listeners have seen a state before the emitting method's future resolves.
- The lifecycle is `Idle → Checking → UpToDate | Available → Initializing → Downloading ⇄ Paused → Verifying → Verified → Installing → Installed`, and any step can go to `Failed(UpdateFailure)`. `UpdateState`, `UpdateFailure`, `InstallProgressEvent` and `SilentInstallEligibility` are all sealed classes.
- Consumers `switch` over these exhaustively, with no default branch. If you add a variant, update `DigitInstaller._mapDownloadFailure` and the app's `_StateView` and `_FailureView._message` in `lib/main.dart`.
- An update is available when the manifest's `versionCode` is **strictly greater** than the `currentVersionCode` the caller passes in. The app passes the `+build` number from `pubspec.yaml`'s `version:`.
- The manifest JSON shape is `UpdateManifest.fromJson`. Release publishing steps are in `packages/digit_installer/README.md`. That README treats publishing a release as a deliberate manual step, not part of a routine build.
- Downloads use the task ID `digit_installer.<versionCode>.<sha256>`, which keys the resume state in `digit_downloader`. `isDownloaded(manifest)` lets the host skip straight to Install when the file is already on disk.
- The package **never deletes the downloaded APK**. The host does that itself on `UpdateInstalled`, using `lastFilePath` (see `_deleteDownloadedApk` in `lib/main.dart`).
- Verification order:
  1. `digit_downloader` checks the SHA-256 checksum.
  2. If `signingCertSha256` is set and the platform supports it, the APK signing certificate is checked.
  3. Only then does the state become `UpdateVerified`.

### Platform split (`plugin_platform_interface`)

- `DigitInstallerPlatform` covers only what really differs per OS: install sessions, signature extraction, the device-owner check, the unknown-apps permission, and desktop run/reveal. Capability getters (`supportsInstall`, `supportsSignatureVerification`) gate behaviour in the facade.
- **Only Android has native code.**
  - `MethodChannelDigitInstaller` uses the method channel `com.egov.digit_installer` and the event channel `com.egov.digit_installer/install_events`. Events are demultiplexed by `sessionId`, and status `2` means the user cancelled.
  - iOS (`DigitInstallerIos`) and desktop (`DigitInstallerDesktop`) are pure-Dart `dartPluginClass`es registered in `pubspec.yaml`.
  - Web has no install support. The facade short-circuits on `kIsWeb`.
- Android native code (`android/src/main/kotlin/com/egov/digit_installer/`):
  - `InstallSessionManager` drives the PackageInstaller Session API.
  - `InstallResultReceiver` is statically declared so it survives backgrounding.
  - `DeviceOwnerChecker` gates `InstallMode.silentDeviceOwner` (API 31+).
- Installing an update always kills the app's process. With `reopenAfterInstall`, `PostInstallRelaunchReceiver` listens for `MY_PACKAGE_REPLACED` and posts a "tap to reopen" notification. Android blocks starting an Activity from a background receiver, so this can't be an automatic relaunch.

### `digit_downloader`: two engines, one stream

- `Downloader` is the fakeable interface, and `DigitDownloader` implements it. There's no separate resume method: calling `start()` again with the same `taskId` resumes from the persisted `DownloadSnapshot`, which is stored via `just_storage` behind the injectable `JsonKeyValueStore`.
- **`appLifecycle`** (the default) runs in pure Dart:
  1. A HEAD request gets the size, ETag and range support.
  2. `ChunkPlanner` splits the file into ranges.
  3. One `ChunkWorker` per range writes through its own `RandomAccessFile`.
  4. The SHA-256 checksum is verified.

  The snapshot is persisted at most every 250 ms. A resume is only valid if the size and ETag still match.
- **`systemManaged`** hands the download to native engines (an Android foreground `BackgroundDownloadService`, or an iOS background `URLSession`) through `NativeBackgroundBridge`, on the channel `com.egov.digit_downloader`.
  - The native engines are ports of the same HEAD → chunk → verify logic and must emit the same `DownloadState` events. Change both sides together.
  - On desktop and web it silently falls back to `appLifecycle`.
  - The package README says the iOS native code has never been compiled or run.
- TLS pinning uses a conditional import: `certificate_pinner_io.dart` on IO platforms, `certificate_pinner_stub.dart` elsewhere.

### Showcase app (`lib/`)

- `update_config.dart` is the only file that knows the hosting details: the GitHub `owner/repo` and an optional token. The manifest URL is `https://github.com/<repo>/releases/latest/download/manifest.json`.
- If `githubReleaseHost` is blank, `main.dart` starts `DemoUpdateServer` instead, a loopback `shelf` server. It loads `assets/demo/sample-update.bin`, but that asset doesn't exist and isn't declared in `pubspec.yaml`, so this fallback currently fails.
- `ReleasesPage`, which lists all releases through the GitHub REST API, isn't linked from any navigation yet.

## Testing patterns

- `DigitInstaller(config, downloader: …, httpClient: …)` accepts a fake `Downloader` and an `http/testing` `MockClient`.
- To fake the platform, set `DigitInstallerPlatform.instance` to a subclass of `DigitInstallerPlatform` and restore the original in `tearDown`. See `test/digit_installer_facade_test.dart`.
- `DigitDownloader(store: …, clientFactory: …)` accepts an in-memory store and a `MockClient` (including `MockClient.streaming` for pause/resume tests).
