# Digit Installer
A modern, self-hosted APK auto-updater for Flutter.

## Features

- **Android installs** via the `PackageInstaller` Session API: real-time
  install progress, and an optional fully silent path for MDM/kiosk apps
  enrolled as a Device Owner.
- **Dart 3 sealed-class state machine** (`UpdateState`) for the whole
  lifecycle — pattern-match exhaustively, no `default`/`_` branch needed.
- **Custom HTTP headers** (bearer tokens, signatures, custom user-agents),
  rebuilt per request so short-lived tokens stay fresh.
- **SHA-256 checksum, APK signature, and TLS certificate pinning**
  verification before a single byte is installed.
- **Background resumable, chunked downloads** with pause/resume that
  survives app restarts (via the companion
  [`digit_downloader`](https://pub.dev/packages/digit_downloader) package).
- Works without any dependency on Google Play Store or Play Services —
  bring your own hosting (GitHub Releases, your own backend, etc).

iOS is not supported for install in this version (Apple doesn't allow
sideloaded installs outside the App Store) — `checkForUpdate` still works.
Desktop platforms verify and hand the file to the user rather than
auto-launching anything.

## Usage

```dart
final installer = DigitInstaller(
  DigitInstallerConfig(
    manifestUrl: Uri.parse('YOUR_MANIFEST_URL'),
    headersBuilder: () async => {'Authorization': 'Bearer ${await getToken()}'},
  ),
);

installer.updates.listen((state) {
  switch (state) {
    case UpdateIdle():
    case UpdateChecking():
      break;
    case UpdateAvailable(:final manifest):
      installer.download();
    case UpdateDownloading(:final progress):
      print('${(progress.fraction * 100).toStringAsFixed(1)}%');
    case UpdateVerified():
      installer.install();
    case UpdateInstalling(:final fraction):
      print('installing: $fraction');
    case UpdateInstalled(:final installedVersion):
      print('installed $installedVersion');
    case UpdateUpToDate():
    case UpdatePaused():
      break;
    case UpdateFailed(:final reason):
      print('failed: $reason');
  }
});

await installer.checkForUpdate(currentVersionCode: 3, currentVersion: '1.2.0');
```

## Publishing updates via GitHub Releases

`digit_installer` doesn't know anything about GitHub specifically —
[`manifestUrl`](#usage) just needs to resolve to a JSON document, and
`downloadUrl` just needs to resolve to the APK. GitHub Releases happens to
be a convenient free host for both, using the stable
`.../releases/latest/download/<asset-name>` URL pattern (works unauthenticated
for public repos, and with a bearer token for private ones). This section
walks through publishing a release by hand — if you're working inside the
`digit_installer_workspace` monorepo, its `scripts/publish_release.sh`
automates the same steps for the showcase app.

### 1. Prerequisites

- A GitHub repo to host releases on (can be the same repo as your app).
- Either the [`gh` CLI](https://cli.github.com/) authenticated
  (`gh auth login`), **or** a
  [Personal Access Token](https://github.com/settings/personal-access-tokens/new)
  with `Contents: Read and write` scoped to that repo, for use with `curl`
  against the REST API. Fine-grained tokens scoped to a single repo are
  preferred over classic tokens with the full `repo` scope.
  - Keep the token out of shell history and source control — e.g. put it in
    a git-ignored `.env` file and `source` it, rather than pasting it
    directly into commands.

### 2. Build the APK and note its version

```
flutter build apk --release   # or --debug, e.g. while signing isn't set up yet
```

The output is at `build/app/outputs/flutter-apk/app-release.apk` (or
`app-debug.apk`). Match `versionCode` in the manifest below to the
`+<build number>` you set in `pubspec.yaml`'s `version:` field —
`checkForUpdate` treats it as a monotonically increasing integer and will
never offer a manifest whose `versionCode` isn't strictly greater than the
value passed as `currentVersionCode`.

### 3. Compute the APK's SHA-256

```
# Linux / Git Bash / WSL
sha256sum build/app/outputs/flutter-apk/app-release.apk

# macOS
shasum -a 256 build/app/outputs/flutter-apk/app-release.apk

# Windows (PowerShell)
Get-FileHash build\app\outputs\flutter-apk\app-release.apk -Algorithm SHA256
```

This value is checked against the downloaded bytes before install — a
mismatch fails the update with `ChecksumMismatch` rather than installing a
corrupted or tampered file.

### 4. Write `manifest.json`

This is the exact shape [`UpdateManifest.fromJson`](lib/src/models/update_manifest.dart)
expects:

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

- `signingCertSha256` (optional): SHA-256 of the APK's signing certificate.
  Set it to enable the signature-verification step in addition to the
  checksum check — see [`getApkSigningCertSha256`](lib/src/platform_interface/digit_installer_platform.dart)
  for how it's read off an installed/downloaded APK.
- `downloadUrl` should use `.../releases/latest/download/<name>`, not a
  version-pinned URL — that way the manifest and the asset it points at are
  always published together in the same release and stay in sync.
- `mandatory` is metadata only — `digit_installer` doesn't currently block
  skipping an update based on it; enforce that in your own UI if needed.

### 5. Create the release and upload both files as assets

**Using `gh`:**

```
gh release create v1.1.0 \
  build/app/outputs/flutter-apk/app-release.apk#app-release.apk \
  manifest.json \
  --title "v1.1.0" \
  --notes "What changed in this release"
```

**Using the REST API directly** (no `gh` install required — useful in CI
or a minimal shell):

```bash
OWNER_REPO="<owner>/<repo>"
TAG="v1.1.0"

# Create the release, capture its numeric id from the response
RELEASE_ID=$(curl -s -X POST \
  -H "Authorization: Bearer $GITHUB_TOKEN" \
  -H "Accept: application/vnd.github+json" \
  -H "User-Agent: release-script" \
  "https://api.github.com/repos/$OWNER_REPO/releases" \
  -d "{\"tag_name\":\"$TAG\",\"name\":\"$TAG\",\"draft\":false,\"prerelease\":false}" \
  | grep -o '"id":[0-9]*' | head -1 | cut -d: -f2)

# Upload each asset to the upload host (note: uploads.github.com, not api.github.com)
upload() {
  curl -s -X POST \
    -H "Authorization: Bearer $GITHUB_TOKEN" \
    -H "Accept: application/vnd.github+json" \
    -H "Content-Type: $2" \
    --data-binary @"$1" \
    "https://uploads.github.com/repos/$OWNER_REPO/releases/$RELEASE_ID/assets?name=$(basename "$1")"
}
upload manifest.json application/json
upload build/app/outputs/flutter-apk/app-release.apk application/vnd.android.package-archive
```

A release tag can only be created once — publishing a new version means
bumping `versionCode`/creating a new tag, not re-uploading assets onto an
existing release.

### 6. Point the app at it

```dart
DigitInstallerConfig(
  manifestUrl: Uri.parse('https://github.com/<owner>/<repo>/releases/latest/download/manifest.json'),
  // Only needed for a private repo:
  headersBuilder: () async => {'Authorization': 'Bearer $githubToken'},
)
```

For a private repo, the same bearer token used to publish the release (or
a separate read-only one) needs `Contents: Read` access and must be
supplied via `headersBuilder` on every request — it's applied to both the
manifest fetch and the APK download.

Treat publishing a release as a deliberate, explicit action — something
you run on purpose when you mean to ship an update — rather than folding
it into a routine build step.

## Additional information

Published by [justunknown.com](https://justunknown.com), BSD-3-Clause
licensed. See the root workspace's showcase app for a full end-to-end demo,
including a real GitHub Releases-backed update flow.
