# Digit Downloader

A generic background resumable/chunked download engine for Dart & Flutter.

This is a general-purpose downloader to download a large file safely over HTTP.

- **Chunked, concurrent downloads** using HTTP `Range` requests.
- **Pause/resume that survives app restarts** — progress is persisted via
  [`just_storage`](https://pub.dev/packages/just_storage), not just kept in
  memory.
- **Streaming SHA-256 checksum verification**, so a download only completes
  once its content is confirmed intact.
- **TLS certificate pinning** with support for multiple simultaneous pins per
  host (so you can rotate certificates without breaking clients mid-rollout).
- **Custom headers** (bearer tokens, signatures, custom user-agents), rebuilt
  per request so short-lived tokens stay fresh across a long download.

## Usage

```dart
final downloader = DigitDownloader();

final request = DownloadRequest(
  url: Uri.parse('https://example.com/files/big-file.bin'),
  taskId: 'big-file-v3',
  destinationPath: '/path/to/big-file.bin',
  expectedSha256: 'expected-hex-digest',
  headersBuilder: () async => {'Authorization': 'Bearer ${await getToken()}'},
);

await for (final state in downloader.start(request)) {
  switch (state) {
    case DownloadIdle():
    case DownloadStarting():
      break;
    case DownloadInProgress(:final progress):
      print('${(progress.fraction * 100).toStringAsFixed(1)}%');
    case DownloadPaused(:final progress):
      print('paused at ${progress.bytesReceived}/${progress.totalBytes}');
    case DownloadCompleted(:final filePath):
      print('done: $filePath');
    case DownloadFailed(:final reason):
      print('failed: $reason');
  }
}

// Pausing keeps the on-disk partial file + resume metadata.
await downloader.pause('big-file-v3');

// Calling start() again with the same request resumes automatically —
// there's no separate "resume" call to remember.
await for (final state in downloader.start(request)) { /* ... */ }

// Cancelling discards the partial file and any resume metadata.
await downloader.cancel('big-file-v3');
```

## Background downloads (`BackgroundDownloadMode`)

By default (`BackgroundDownloadMode.appLifecycle`) a download runs entirely
inside the Dart isolate that started it — it survives the app being
backgrounded, but dies with the process if the OS or the user kills the app
outright. Setting `DownloadRequest.backgroundMode` to
`BackgroundDownloadMode.systemManaged` instead delegates the transfer to a
native background engine — an Android foreground `Service`, an iOS
background `URLSession` — that keeps going independent of whether Flutter
is even running, with a live progress notification:

```dart
final request = DownloadRequest(
  url: Uri.parse('https://example.com/files/big-file.bin'),
  taskId: 'big-file-v3',
  expectedSha256: 'expected-hex-digest',
  backgroundMode: BackgroundDownloadMode.systemManaged,
);
```

The `Stream<DownloadState>` returned by `start()` is exactly the same
either way — the native engine is a Kotlin/Swift port of the same
HEAD-then-Range-chunk-then-verify logic, reporting through the same
`DownloadState` events.

### Customizing the notification

Every string `systemManaged` shows is configurable via
`DownloadRequest.notificationConfig` — nothing is hardcoded to "Download
complete"/"Download failed":

```dart
final request = DownloadRequest(
  url: Uri.parse('https://example.com/files/big-file.bin'),
  taskId: 'big-file-v3',
  backgroundMode: BackgroundDownloadMode.systemManaged,
  notificationConfig: DownloadNotificationConfig(
    channelId: 'my_app_downloads',       // Android notification channel
    channelName: 'App updates',
    progressTitle: 'Fetching the latest version',
    progressText: '{percent}% done',     // {percent} is substituted natively
    completedTitle: 'Update ready',
    completedText: 'Tap to install',
    failedTitle: 'Update failed',
    failedText: 'Something went wrong: {error}', // {error} is substituted natively
    smallIconResourceName: 'ic_notification',    // Android only; a drawable/mipmap in the host app
    channelImportance: DownloadNotificationImportance.normal, // Android only
  ),
);
```

- `{percent}` (in `progressText`) and `{error}` (in `failedText`) are
  substituted by the native engine itself, not a Dart callback — a
  callback would mean a platform-channel round trip on every single
  progress tick.
- Each notification can be turned off independently via `showProgress` /
  `showCompleted` / `showFailed` (all default `true`). On Android,
  `showProgress: false` still posts a minimal, low-priority notification
  while the download runs — a foreground service is required to have
  *some* associated notification while active, so this can be made
  unobtrusive but not fully invisible.
- `smallIconResourceName` is Android-only, resolved at runtime against the
  host app's own `drawable`/`mipmap` resources; falls back to the app's
  launcher icon when unset. iOS notifications always use the app icon —
  there's no per-notification icon concept there.
- `channelImportance` (Android only) defaults to `normal`. `low` is
  silent — no sound, no heads-up peek — which is easy to never notice
  while the app is in the foreground; you only stumble onto it later when
  checking the notification shade after leaving/killing the app, which
  looks a lot like "the notification only shows once the app is closed."
  **Android notification channels are immutable once created** — changing
  `channelImportance` (or anything else about an existing `channelId`) has
  no effect on a device where that channel already exists from a previous
  install; only the user can change it by hand in system settings, or you
  can pick a new `channelId` to force a fresh channel, or uninstall the
  app before reinstalling during testing.

A few real differences to know about between the two native engines:

- **Notifications need permission — requested automatically.** Android 13+
  requires the runtime `POST_NOTIFICATIONS` permission (declaring it in
  the manifest, which this package does, isn't enough on its own); `start()`
  requests it right before the native download begins, the same way
  `just_installer` already does before installing when
  `JustInstallerConfig.reopenAfterInstall` is set. It's best-effort — a
  decline just means no notification, the download still proceeds. iOS
  similarly needs `UNUserNotificationCenter` authorization, requested
  automatically on first use.
- **iOS notifications show even while the app is foregrounded.** By
  default, iOS silently drops the visual presentation of a notification
  posted while the app is in the foreground (since iOS 10) — this package
  sets `BackgroundDownloadManager` as `UNUserNotificationCenter`'s delegate
  and opts in via `willPresent` so progress/completion notifications show
  regardless of app state. That delegate is a single global slot, though:
  if your host app also needs to be a `UNUserNotificationCenterDelegate`
  (e.g. to handle taps on its own notifications), you'll need to
  coordinate rather than set `.delegate` again and silently override this.
- **iOS resumability is per-chunk, not per-byte.** A `URLSessionDownloadTask`
  either completes a chunk in full or it doesn't — there's no simple
  mid-chunk byte offset to persist the way a raw streamed HTTP connection
  gives the Dart and Android engines. A resumed iOS download re-downloads
  any chunk that wasn't already fully completed, rather than continuing it
  from a partial byte offset.
- **iOS needs one line in your `AppDelegate`.** Background `URLSession`
  delivers its completion callback through the app delegate, not directly
  to the plugin:
  ```swift
  import digit_downloader

  override func application(
    _ application: UIApplication,
    handleEventsForBackgroundURLSession identifier: String,
    completionHandler: @escaping () -> Void
  ) {
    BackgroundDownloadManager.shared.backgroundCompletionHandler = completionHandler
  }
  ```
  Without this, a `systemManaged` download that finishes while the app is
  suspended may not deliver its completion event until the app is next
  opened manually.
- **The iOS implementation is unverified.** It was written without access
  to Xcode or macOS — there is no way to compile-check or run it in that
  environment. Build and test it on a real Mac/device before relying on it;
  treat it as a draft, not a shipped feature. The Android implementation,
  by contrast, is built and its full test suite passes as part of this
  repo's normal CI-equivalent checks.
- **Falls back silently on unsupported platforms** (desktop, web) —
  `systemManaged` behaves like `appLifecycle` there rather than erroring.

## Additional information

Published by [justunknown.com](https://justunknown.com), BSD-3-Clause licensed.
