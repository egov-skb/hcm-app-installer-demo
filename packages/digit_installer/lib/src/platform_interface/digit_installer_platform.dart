import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import '../state/install_progress_event.dart';
import '../state/silent_install_eligibility.dart';
import 'method_channel_digit_installer.dart';

/// The platform-specific surface `digit_installer` needs — scoped to only
/// what genuinely differs per OS: install-session lifecycle, signature
/// extraction, device-owner check, unknown-apps permission, and desktop
/// run/reveal helpers. Everything else (download engine, checksum, TLS
/// pinning, the update-lifecycle state machine) is plain shared Dart in
/// [DigitInstaller] and doesn't need a platform implementation at all.
abstract class DigitInstallerPlatform extends PlatformInterface {
  DigitInstallerPlatform() : super(token: _token);

  static final Object _token = Object();

  static DigitInstallerPlatform _instance = MethodChannelDigitInstaller();

  static DigitInstallerPlatform get instance => _instance;

  static set instance(DigitInstallerPlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  /// Whether this platform can install an APK at all. `false` on iOS, web,
  /// and desktop — those return [UnsupportedPlatform] instead of attempting
  /// [install].
  bool get supportsInstall => false;

  /// Whether [getApkSigningCertSha256]/[getInstalledSigningCertSha256] are
  /// implemented. Android-only — APK signature verification needs OS-level
  /// ZIP/certificate parsing that isn't feasible in pure Dart.
  bool get supportsSignatureVerification => false;

  Future<String?> getApkSigningCertSha256(String apkFilePath) {
    throw UnimplementedError('getApkSigningCertSha256() has not been implemented.');
  }

  Future<String?> getInstalledSigningCertSha256() {
    throw UnimplementedError('getInstalledSigningCertSha256() has not been implemented.');
  }

  Future<SilentInstallEligibility> checkSilentInstallEligibility() {
    throw UnimplementedError('checkSilentInstallEligibility() has not been implemented.');
  }

  /// Whether the user has granted "install unknown apps" for this app
  /// (Android API 26+; always `true` pre-26, where it's a single global
  /// toggle rather than per-app).
  Future<bool> canRequestPackageInstalls() {
    throw UnimplementedError('canRequestPackageInstalls() has not been implemented.');
  }

  Future<void> openInstallUnknownAppsSettings() {
    throw UnimplementedError('openInstallUnknownAppsSettings() has not been implemented.');
  }

  /// Android 13+: requests `POST_NOTIFICATIONS`, needed for the "tap to
  /// reopen" notification [DigitInstallerConfig.reopenAfterInstall] shows
  /// after an update installs (posting it from a background broadcast
  /// receiver is the only way to relaunch the app — see that field's doc
  /// comment). Best-effort: [install] proceeds regardless of the result.
  Future<bool> ensureNotificationPermission() {
    throw UnimplementedError('ensureNotificationPermission() has not been implemented.');
  }

  Stream<InstallProgressEvent> install({
    required String apkFilePath,
    required int sizeBytes,
    required bool silent,
    required bool reopenAfterInstall,
  }) {
    throw UnimplementedError('install() has not been implemented.');
  }

  /// Desktop-only. The package never calls this on its own initiative — it
  /// is only ever invoked in direct response to an explicit host-app call
  /// (e.g. a user tapping "Install"), never automatically after a download
  /// completes.
  Future<void> runInstaller(String filePath) {
    throw UnimplementedError('runInstaller() has not been implemented.');
  }

  Future<void> revealInFileManager(String filePath) {
    throw UnimplementedError('revealInFileManager() has not been implemented.');
  }
}
