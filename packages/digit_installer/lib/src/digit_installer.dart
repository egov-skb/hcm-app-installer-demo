import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:http/http.dart' as http;
import 'package:digit_downloader/digit_downloader.dart' as downloads;

import 'models/install_mode.dart';
import 'models/installer_config.dart';
import 'models/update_manifest.dart';
import 'platform_interface/digit_installer_platform.dart';
import 'state/install_progress_event.dart';
import 'state/silent_install_eligibility.dart';
import 'state/update_failure.dart';
import 'state/update_state.dart';

/// Self-hosted APK auto-updater: checks a manifest, downloads and verifies
/// the update, then installs it — without any dependency on Google Play
/// Store or Play Services.
///
/// Drive it via [updates] (a broadcast `Stream<UpdateState>`) and the
/// imperative methods below; every method emits into that same stream
/// rather than returning results directly, so a single `StreamBuilder`
/// can render the whole lifecycle with an exhaustive `switch`.
class DigitInstaller {
  DigitInstaller(this.config, {downloads.Downloader? downloader, http.Client? httpClient})
    : _downloader = downloader ?? downloads.DigitDownloader(),
      _httpClient = httpClient ?? http.Client();

  final DigitInstallerConfig config;
  final downloads.Downloader _downloader;
  final http.Client _httpClient;
  // sync: true so a listener has already observed an emitted state by the
  // time the method that emitted it (e.g. checkForUpdate()) finishes
  // awaiting — otherwise the default async broadcast dispatch can resolve
  // the caller's await before the corresponding stream event is delivered.
  final _stateController = StreamController<UpdateState>.broadcast(sync: true);

  UpdateManifest? _lastManifest;
  String? _lastFilePath;

  Stream<UpdateState> get updates => _stateController.stream;

  UpdateManifest? get lastManifest => _lastManifest;

  /// Path of the downloaded (and, once past [UpdateVerified], checksum- and
  /// signature-verified) update file. Set once [download] reaches
  /// [UpdateVerified]/[UpdateInstalled]; hosts that want to delete it after
  /// a successful install — it isn't cleaned up automatically — can do so
  /// via this path.
  String? get lastFilePath => _lastFilePath;

  String _taskIdFor(UpdateManifest manifest) => 'digit_installer.${manifest.versionCode}.${manifest.sha256}';

  /// Whether [manifest]'s update file is already downloaded and
  /// checksum-verified at its expected destination — e.g. left over from a
  /// previous [download] that was never followed by [install]. Hosts can
  /// check this after [UpdateAvailable] to offer an "Install" affordance
  /// instead of "Download": calling [download] in that case still runs (to
  /// populate [lastFilePath] and reach [UpdateVerified]) but skips the
  /// network transfer entirely, since [downloads.Downloader] implementations
  /// are expected to detect the same match and short-circuit.
  Future<bool> isDownloaded(UpdateManifest manifest) {
    return _downloader.isComplete(
      downloads.DownloadRequest(url: manifest.downloadUrl, taskId: _taskIdFor(manifest), expectedSha256: manifest.sha256),
    );
  }

  Future<void> checkForUpdate({required int currentVersionCode, required String currentVersion}) async {
    _emit(const UpdateChecking());
    try {
      final headers = await config.headersBuilder?.call() ?? <String, String>{};
      final response = await _httpClient.get(config.manifestUrl, headers: headers);
      if (response.statusCode != 200) {
        _emit(UpdateFailed(NetworkFailure('Unexpected status ${response.statusCode} fetching manifest')));
        return;
      }

      final Map<String, dynamic> json;
      try {
        json = jsonDecode(response.body) as Map<String, dynamic>;
      } catch (e) {
        _emit(UpdateFailed(ManifestParseFailure(e.toString())));
        return;
      }

      final UpdateManifest manifest;
      try {
        manifest = UpdateManifest.fromJson(json);
      } catch (e) {
        _emit(UpdateFailed(ManifestParseFailure(e.toString())));
        return;
      }

      _lastManifest = manifest;
      if (manifest.versionCode <= currentVersionCode) {
        _emit(UpdateUpToDate(currentVersion));
        return;
      }
      _emit(UpdateAvailable(manifest));
    } catch (e, st) {
      _emit(UpdateFailed(_mapNetworkError(e, st)));
    }
  }

  Future<void> download() async {
    final manifest = _lastManifest;
    if (manifest == null) {
      _emit(const UpdateFailed(UnknownFailure('download() called before an update was available')));
      return;
    }
    if (kIsWeb) {
      _emit(const UpdateFailed(UnsupportedPlatform(platform: 'web', operation: 'download')));
      return;
    }

    final request = downloads.DownloadRequest(
      url: manifest.downloadUrl,
      taskId: _taskIdFor(manifest),
      headersBuilder: config.headersBuilder,
      chunkCount: config.chunkCount,
      minChunkSize: config.minChunkSize,
      maxRetriesPerChunk: config.maxRetriesPerChunk,
      expectedSha256: manifest.sha256,
      certificatePins: config.certificatePins,
      backgroundMode: config.backgroundDownloadMode,
    );

    await for (final state in _downloader.start(request)) {
      switch (state) {
        case downloads.DownloadIdle():
          break;
        case downloads.DownloadStarting():
          _emit(const UpdateInitializing());
        case downloads.DownloadInProgress(:final progress):
          _emit(UpdateDownloading(progress));
        case downloads.DownloadPaused(:final progress):
          _emit(UpdatePaused(progress));
        case downloads.DownloadCompleted(:final filePath):
          _lastFilePath = filePath;
          await _verify(filePath, manifest);
        case downloads.DownloadFailed(:final reason):
          _emit(UpdateFailed(_mapDownloadFailure(reason)));
      }
    }
  }

  Future<void> _verify(String filePath, UpdateManifest manifest) async {
    _emit(UpdateVerifying(filePath));
    final platform = DigitInstallerPlatform.instance;

    if (manifest.signingCertSha256 != null && platform.supportsSignatureVerification) {
      final actual = await platform.getApkSigningCertSha256(filePath);
      if (actual == null || actual != manifest.signingCertSha256) {
        _emit(
          UpdateFailed(
            SignatureMismatch(expectedSha256: manifest.signingCertSha256, actualSha256: actual ?? ''),
          ),
        );
        return;
      }
    }

    _emit(UpdateVerified(filePath, manifest));
  }

  Future<void> pauseDownload() async {
    final manifest = _lastManifest;
    if (manifest == null) return;
    await _downloader.pause(_taskIdFor(manifest));
  }

  Future<void> cancelDownload() async {
    final manifest = _lastManifest;
    if (manifest == null) return;
    await _downloader.cancel(_taskIdFor(manifest));
  }

  /// Queried proactively so hosts using [InstallMode.silentDeviceOwner] can
  /// react to ineligibility before calling [install] — `install()` itself
  /// never blindly attempts the silent path.
  Future<SilentInstallEligibility> checkSilentInstallEligibility() {
    final platform = DigitInstallerPlatform.instance;
    if (!platform.supportsInstall) return Future.value(const SilentInstallNotAndroid());
    return platform.checkSilentInstallEligibility();
  }

  /// Android-only: installs the verified APK via the PackageInstaller
  /// Session API. On other platforms this emits `UnsupportedPlatform` —
  /// desktop hosts should call [runDownloadedInstaller] instead once
  /// [UpdateVerified] is reached.
  Future<void> install() async {
    final filePath = _lastFilePath;
    final manifest = _lastManifest;
    if (filePath == null || manifest == null) {
      _emit(const UpdateFailed(UnknownFailure('install() called before an update was verified')));
      return;
    }
    if (kIsWeb) {
      _emit(const UpdateFailed(UnsupportedPlatform(platform: 'web', operation: 'install')));
      return;
    }

    final platform = DigitInstallerPlatform.instance;
    if (!platform.supportsInstall) {
      _emit(UpdateFailed(UnsupportedPlatform(platform: _currentPlatformName(), operation: 'install')));
      return;
    }

    if (!(await platform.canRequestPackageInstalls())) {
      _emit(const UpdateFailed(InstallUnknownAppsNotPermitted()));
      return;
    }

    var silent = false;
    if (config.installMode == InstallMode.silentDeviceOwner) {
      silent = await checkSilentInstallEligibility() is SilentInstallEligible;
    }

    // Best-effort — a declined/unavailable notification permission means no
    // reopen prompt after install, not a blocked install.
    if (config.reopenAfterInstall) {
      await platform.ensureNotificationPermission();
    }

    final sizeBytes = await File(filePath).length();
    await for (final event in platform.install(
      apkFilePath: filePath,
      sizeBytes: sizeBytes,
      silent: silent,
      reopenAfterInstall: config.reopenAfterInstall,
    )) {
      switch (event) {
        case InstallProgress(:final fraction):
          _emit(UpdateInstalling(fraction));
        case InstallSucceeded():
          _emit(UpdateInstalled(manifest.version));
        case InstallFailed(:final userCancelled, :final nativeStatusCode, :final message):
          if (userCancelled) {
            _emit(const UpdateFailed(UserCancelled()));
          } else {
            _emit(UpdateFailed(InstallerError(nativeStatusCode: nativeStatusCode, message: message ?? 'Install failed')));
          }
      }
    }
  }

  Future<void> openInstallUnknownAppsSettings() => DigitInstallerPlatform.instance.openInstallUnknownAppsSettings();

  /// Desktop-only: launches the verified installer/executable in direct
  /// response to an explicit host-app call. Never invoked automatically.
  Future<void> runDownloadedInstaller() async {
    final filePath = _lastFilePath;
    if (filePath == null) {
      _emit(const UpdateFailed(UnknownFailure('runDownloadedInstaller() called before an update was verified')));
      return;
    }
    await DigitInstallerPlatform.instance.runInstaller(filePath);
  }

  /// Desktop-only convenience: reveal the verified file in the OS file
  /// manager instead of running it directly.
  Future<void> revealDownloadedFileInFolder() async {
    final filePath = _lastFilePath;
    if (filePath == null) return;
    await DigitInstallerPlatform.instance.revealInFileManager(filePath);
  }

  void dispose() {
    _httpClient.close();
    _stateController.close();
  }

  void _emit(UpdateState state) => _stateController.add(state);

  String _currentPlatformName() {
    if (kIsWeb) return 'web';
    if (Platform.isIOS) return 'ios';
    if (Platform.isWindows) return 'windows';
    if (Platform.isMacOS) return 'macos';
    if (Platform.isLinux) return 'linux';
    return Platform.operatingSystem;
  }

  UpdateFailure _mapNetworkError(Object e, StackTrace st) {
    if (e is http.ClientException || e is SocketException || e is TimeoutException) {
      return NetworkFailure(e.toString(), e);
    }
    return UnknownFailure(e, st);
  }

  UpdateFailure _mapDownloadFailure(downloads.DownloadFailure reason) {
    return switch (reason) {
      downloads.DownloadNetworkFailure(:final message, :final cause) => NetworkFailure(message, cause),
      downloads.DownloadChecksumMismatch(:final expectedSha256, :final actualSha256) => ChecksumMismatch(
        expectedSha256: expectedSha256,
        actualSha256: actualSha256,
      ),
      downloads.DownloadCertificatePinningFailure(:final host) => CertificatePinningFailure(host),
      downloads.DownloadCancelled() => const UserCancelled(),
      downloads.DownloadIncomplete(:final bytesReceived, :final totalBytes) => DownloadIncomplete(
        bytesReceived: bytesReceived,
        totalBytes: totalBytes,
      ),
      downloads.DownloadUnknownFailure(:final error, :final stackTrace) => UnknownFailure(error, stackTrace),
    };
  }
}
