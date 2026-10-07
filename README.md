# hcm_app_installer

A Flutter showcase app for a **self-hosted APK auto-updater**. It checks a
remote manifest for a newer build, downloads it, verifies it, and installs it
on Android, without the Play Store or Play Services.

The updater is built from two Flutter plugin packages that are developed in
this repo under `packages/`.

| Package | Role |
| --- | --- |
| [`digit_installer`](packages/digit_installer/README.md) | The update lifecycle: manifest check, download, verification and Android install. |
| [`digit_downloader`](packages/digit_downloader/README.md) | A general-purpose download engine. It handles resumable, chunked HTTP downloads and knows nothing about APKs. |

The dependencies run in one direction: app → `digit_installer` → `digit_downloader`.

## Repository layout

```
.
├── lib/
│   ├── main.dart              # Showcase UI that drives the update flow
│   ├── update_config.dart     # Update hosting settings (GitHub repo, token)
│   ├── demo_server.dart       # Local fallback server, used when no repo is set
│   └── releases_page.dart     # Lists all GitHub releases (not linked in the UI yet)
├── packages/
│   ├── digit_installer/       # Updater plugin (Dart, plus Kotlin for Android)
│   └── digit_downloader/       # Download engine plugin (Dart, plus Kotlin/Swift)
├── android/  ios/  linux/  macos/  web/  windows/
├── pubspec.yaml
└── pubspec_overrides.yaml     # Points the app at the local packages/ copies
```

`pubspec_overrides.yaml` (and `packages/digit_installer/pubspec_overrides.yaml`)
link the packages by local path. Changes you make under `packages/` show up in
the app straight away.

## Requirements

- Flutter 3.22.2 or newer (Dart `>=3.4.3`)
- To test installs: an Android device or emulator running API 24 (Android 7.0) or newer
- Android toolchain used by the host app and both plugins: Gradle 7.6.3,
  AGP 7.3.0, Kotlin 1.7.10, Java 8, `compileSdk` 34

## Getting started

```bash
# 1. Fetch dependencies for the app and for each package
flutter pub get
(cd packages/digit_installer && flutter pub get)
(cd packages/digit_downloader && flutter pub get)

# 2. Run the showcase
flutter run                   # on a connected Android device (full flow)
flutter run -d linux          # desktop: check and download only, no install
```

To build a release APK:

```bash
flutter build apk --release
# Output: build/app/outputs/flutter-apk/app-release.apk
```

> The release build type is currently signed with the **debug** key (see
> `android/app/build.gradle`). Set up a real signing config before you
> distribute builds. An update only installs over the existing app if both
> APKs are signed with the same key.

## Configuring the update source

All hosting details live in `lib/update_config.dart`:

```dart
/// 'owner/repo' of the GitHub repo that hosts releases.
/// Leave blank to use the local demo server instead.
const String githubReleaseHost = 'just-unknown-dev/just-installer-workspace';

/// Bearer token. Only needed when the repo is private.
const String githubToken = '';
```

When a repo is set, the app reads its manifest from:

```
https://github.com/<owner>/<repo>/releases/latest/download/manifest.json
```

This URL always points to the newest published release that is not a draft
or pre-release.

> Don't commit a real `githubToken`. Any token compiled into an APK can be
> pulled back out of it. For private hosting, prefer a short-lived token
> fetched at runtime and passed through `headersBuilder`.

## How the update flow works

1. The app reads its version and build number using `package_info_plus`.
2. **Check for update** fetches the manifest. An update is offered only when
   the manifest's `versionCode` is **strictly greater** than the app's build
   number (the `+N` part of `version:` in `pubspec.yaml`).
3. **Download** fetches the APK in parallel chunks. A download can be paused
   and resumed, and it can pick up where it left off after the app restarts.
   If the same file was already downloaded and verified, the app skips the
   download and shows **Install** right away.
4. **Verify** checks the file's SHA-256 against the manifest. If the manifest
   includes `signingCertSha256`, the APK's signing certificate is checked as
   well.
5. **Install** hands the APK to Android's `PackageInstaller`, which asks the
   user to confirm once.
6. After a successful install, the app deletes the downloaded APK.

Every step is reported as an `UpdateState` on the `DigitInstaller.updates`
stream:

```
Idle → Checking → UpToDate | Available → Initializing → Downloading ⇄ Paused
     → Verifying → Verified → Installing → Installed
```

Any step can end in `Failed(UpdateFailure)`. The UI shows a readable message
for each kind of failure, plus a **Try again** button.

## Publishing an update

1. Increase the build number in `pubspec.yaml`, for example
   `1.0.0+1` → `1.1.0+2`.
2. Build the APK: `flutter build apk --release`.
3. Get its SHA-256 with `sha256sum build/app/outputs/flutter-apk/app-release.apk`.
4. Write a `manifest.json`:

   ```json
   {
     "version": "1.1.0",
     "versionCode": 2,
     "downloadUrl": "https://github.com/<owner>/<repo>/releases/latest/download/app-release.apk",
     "sha256": "<sha256 from step 3>",
     "size": 12345678,
     "releaseNotes": "What changed in this release",
     "mandatory": false
   }
   ```

5. Create a GitHub release and attach both the APK and `manifest.json` to it:

   ```bash
   gh release create v1.1.0 \
     build/app/outputs/flutter-apk/app-release.apk#app-release.apk \
     manifest.json \
     --title "v1.1.0" --notes "What changed in this release"
   ```

The [`digit_installer` README](packages/digit_installer/README.md#publishing-updates-via-github-releases)
covers more: the optional `signingCertSha256` field, publishing with the REST
API instead of `gh`, and private repos. Publish releases on purpose, as a
manual step. Don't make it part of a routine build.

## Android behaviour

- **Permissions.** The plugins add `REQUEST_INSTALL_PACKAGES`,
  `POST_NOTIFICATIONS`, `INTERNET` and the foreground-service permissions to
  the app's manifest automatically. You don't need to edit
  `AndroidManifest.xml`.
- **Installing unknown apps.** The first install may fail with
  `InstallUnknownAppsNotPermitted`. In that case the app shows an
  **Open settings** button, so the user can allow installs from this app.
- **The app closes during install.** Android always stops an app's process
  when it installs an update over it. The showcase turns on
  `reopenAfterInstall`, so a "tap to reopen" notification appears once the
  update finishes. Android doesn't let a background receiver relaunch the
  app on its own, so the user has to tap the notification.
- **Background downloads.** By default, downloads run in an Android
  foreground service (`BackgroundDownloadMode.systemManaged`) with a progress
  notification. The download keeps going even if the app is closed.
- **Silent installs.** `InstallMode.silentDeviceOwner` installs with no
  confirmation dialog. It only works on API 31+ when the app is the device
  owner (MDM or kiosk setups). Otherwise it falls back to the normal
  confirmation flow.

## Platform support

| Platform | Check | Download and verify | Install |
| --- | --- | --- | --- |
| Android | ✅ | ✅ | ✅ |
| iOS | ✅ | ⚠️ Untested (\*) | ❌ Apple doesn't allow installs from outside the App Store |
| Windows, macOS, Linux | ✅ | ✅ | ❌ in this app (\*\*) |
| Web | ✅ | ❌ | ❌ |

(\*) On iOS, background downloads use a native `URLSession` engine that has
never been compiled or run. This app's `AppDelegate` also doesn't have the
`handleEventsForBackgroundURLSession` hook that engine needs. See the
[`digit_downloader` README](packages/digit_downloader/README.md).

(\*\*) On desktop, `digit_installer` offers `runDownloadedInstaller()`, which
opens the verified file in the system's own installer. The showcase UI
doesn't call it yet, so tapping **Install** on desktop reports
`UnsupportedPlatform`.

## Development

Each package is its own pub package. Run its commands from inside that
package's folder.

```bash
flutter analyze                                   # in the root or any package folder

cd packages/digit_installer && flutter test       # updater tests
cd packages/digit_downloader && flutter test       # download engine tests

# Run a single test by name
flutter test test/digit_installer_facade_test.dart --plain-name "<test name>"
```

The root app has no tests of its own. All tests live in the packages. There
is also a Kotlin unit test at
`packages/digit_installer/android/src/test/kotlin/com/egov/digit_installer/DigitInstallerPluginTest.kt`.

## Known limitations

- **The demo server fallback doesn't work.** If `githubReleaseHost` is left
  blank, the app starts `DemoUpdateServer`. That server loads
  `assets/demo/sample-update.bin`, but the file doesn't exist and isn't
  declared in `pubspec.yaml`. Until it's added, keep a GitHub repo
  configured.
- **The releases list isn't reachable.** `ReleasesPage` exists but nothing in
  the app navigates to it.
- **Placeholder IDs.** The Android `applicationId` and namespace are still
  `com.example.hcm_app_installer`.
- **`mandatory` isn't enforced.** The manifest's `mandatory` field is
  informational only. The package doesn't stop the user from skipping an
  update.
- **Old package names.** Some comments and the `digit_downloader` README
  still say `just_installer` / `JustInstallerConfig`. These are the old names
  for `digit_installer` / `DigitInstallerConfig`.
