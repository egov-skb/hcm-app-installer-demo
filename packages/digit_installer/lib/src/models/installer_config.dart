import 'package:digit_downloader/digit_downloader.dart'
    show BackgroundDownloadMode, CertificatePinSet;

import 'install_mode.dart';

/// Configuration for a [DigitInstaller] instance.
///
/// Deliberately host-agnostic: [manifestUrl] can point at a GitHub Releases
/// asset, a custom backend, or anything else that serves the manifest JSON
/// shape — hosting-specific details (repo owner/name, tokens) belong in the
/// consuming app's own config, never hardcoded here.
class DigitInstallerConfig {
  const DigitInstallerConfig({
    required this.manifestUrl,
    this.headersBuilder,
    this.certificatePins,
    this.installMode = InstallMode.consumerConfirm,
    this.chunkCount = 4,
    this.minChunkSize = 1024 * 1024,
    this.maxRetriesPerChunk = 3,
    this.reopenAfterInstall = false,
    this.backgroundDownloadMode = BackgroundDownloadMode.systemManaged,
  });

  final Uri manifestUrl;

  /// Rebuilt on every request, so short-lived bearer tokens stay fresh.
  /// Applies to both the manifest fetch and the APK download.
  final Future<Map<String, String>> Function()? headersBuilder;

  final CertificatePinSet? certificatePins;

  final InstallMode installMode;

  final int chunkCount;
  final int minChunkSize;
  final int maxRetriesPerChunk;

  /// Android: installing an update over the running app always kills its
  /// process — the OS won't let new code load into a live process. When
  /// `true`, a static receiver for `ACTION_MY_PACKAGE_REPLACED` picks this
  /// up once the update finishes (nothing Dart- or Kotlin-side survives
  /// the process kill to do it directly) and shows a "tap to reopen"
  /// notification — not an automatic relaunch: Android blocks starting an
  /// Activity from a background receiver, so a notification the user taps
  /// is the only mechanism that actually works. On API 33+ this also
  /// prompts for `POST_NOTIFICATIONS` (best-effort — a decline just means
  /// no notification, [install] still proceeds) right before installing.
  /// `false` by default: leaving the user on the home screen after an
  /// update is a legitimate choice too, so this is opt-in rather than
  /// automatic. No effect on platforms other than Android.
  final bool reopenAfterInstall;

  /// Whether the update download needs to survive the app being
  /// backgrounded ([BackgroundDownloadMode.appLifecycle], the default) or
  /// fully killed ([BackgroundDownloadMode.systemManaged], which also
  /// shows a live progress notification). Passed straight through to the
  /// underlying `digit_downloader` request.
  final BackgroundDownloadMode backgroundDownloadMode;
}
