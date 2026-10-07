import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:digit_downloader/digit_downloader.dart' as downloads;
import 'package:digit_installer/digit_installer.dart';

class _FakeDownloader implements downloads.Downloader {
  _FakeDownloader(this.states);
  final List<downloads.DownloadState> states;
  String? lastPausedTaskId;
  String? lastCancelledTaskId;

  @override
  Stream<downloads.DownloadState> start(downloads.DownloadRequest request) => Stream.fromIterable(states);

  @override
  Future<void> pause(String taskId) async => lastPausedTaskId = taskId;

  @override
  Future<void> cancel(String taskId) async => lastCancelledTaskId = taskId;

  @override
  Future<bool> hasResumableDownload(String taskId) async => false;

  @override
  Future<bool> isComplete(downloads.DownloadRequest request) async => false;
}

class _FakePlatform extends DigitInstallerPlatform {
  _FakePlatform({
    this.installSupported = true,
    this.signatureVerificationSupported = true,
    this.apkSigningCertSha256,
    this.canRequestInstalls = true,
    this.installEvents = const [],
  });

  final bool installSupported;
  final bool signatureVerificationSupported;
  final String? apkSigningCertSha256;
  final bool canRequestInstalls;
  final List<InstallProgressEvent> installEvents;

  @override
  bool get supportsInstall => installSupported;

  @override
  bool get supportsSignatureVerification => signatureVerificationSupported;

  @override
  Future<String?> getApkSigningCertSha256(String apkFilePath) async => apkSigningCertSha256;

  @override
  Future<bool> canRequestPackageInstalls() async => canRequestInstalls;

  @override
  Stream<InstallProgressEvent> install({
    required String apkFilePath,
    required int sizeBytes,
    required bool silent,
    required bool reopenAfterInstall,
  }) => Stream.fromIterable(installEvents);
}

UpdateManifest _manifest({String? signingCertSha256}) => UpdateManifest(
  version: '2.0.0',
  versionCode: 2,
  downloadUrl: Uri.parse('https://example.com/app.apk'),
  sha256: 'expected-sha',
  signingCertSha256: signingCertSha256,
);

http.Client _manifestClient(Map<String, dynamic> json, {int statusCode = 200}) {
  return MockClient((request) async => http.Response(jsonEncode(json), statusCode));
}

void main() {
  final originalPlatform = DigitInstallerPlatform.instance;
  tearDown(() => DigitInstallerPlatform.instance = originalPlatform);

  // install() reads the verified file's size from disk (as the real
  // PackageInstaller session needs to), so tests that reach install() need a
  // real file on disk, not just a fake path string.
  late Directory tempDir;
  late String tempApkPath;

  setUpAll(() async {
    tempDir = await Directory.systemTemp.createTemp('digit_installer_facade_test');
    tempApkPath = '${tempDir.path}/update.apk';
    await File(tempApkPath).writeAsBytes([1, 2, 3, 4]);
  });

  tearDownAll(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('checkForUpdate', () {
    test('emits Checking then Available when versionCode is newer', () async {
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(_manifest().toJson()),
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');

      expect(states[0], isA<UpdateChecking>());
      expect(states[1], isA<UpdateAvailable>());
      expect((states[1] as UpdateAvailable).manifest.versionCode, 2);
    });

    test('emits UpToDate when the manifest versionCode is not newer', () async {
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(_manifest().toJson()),
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 5, currentVersion: '5.0.0');

      expect(states.last, isA<UpdateUpToDate>());
    });

    test('emits ManifestParseFailure for invalid JSON', () async {
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: MockClient((request) async => http.Response('not json', 200)),
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');

      expect(states.last, isA<UpdateFailed>());
      expect((states.last as UpdateFailed).reason, isA<ManifestParseFailure>());
    });

    test('emits NetworkFailure for a non-200 response', () async {
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(_manifest().toJson(), statusCode: 500),
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');

      expect(states.last, isA<UpdateFailed>());
      expect((states.last as UpdateFailed).reason, isA<NetworkFailure>());
    });
  });

  group('download + verify', () {
    test('maps Completed to Verified when no signing cert is pinned', () async {
      DigitInstallerPlatform.instance = _FakePlatform();
      final manifest = _manifest();
      final downloader = _FakeDownloader([
        const downloads.DownloadInProgress(
          downloads.DownloadProgress(bytesReceived: 50, totalBytes: 100, bytesPerSecond: 0, chunksTotal: 1, chunksCompleted: 0),
        ),
        downloads.DownloadCompleted(tempApkPath),
      ]);
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(manifest.toJson()),
        downloader: downloader,
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');
      await installer.download();

      expect(states.whereType<UpdateDownloading>(), isNotEmpty);
      expect(states.last, isA<UpdateVerified>());
      expect((states.last as UpdateVerified).filePath, tempApkPath);
    });

    test('skips signature verification on platforms that do not support it', () async {
      // e.g. desktop: signatureVerificationSupported is false, so a pinned
      // signingCertSha256 must not block verification even though
      // apkSigningCertSha256 (never called) would mismatch.
      DigitInstallerPlatform.instance = _FakePlatform(
        signatureVerificationSupported: false,
        apkSigningCertSha256: 'wrong-cert',
      );
      final manifest = _manifest(signingCertSha256: 'expected-cert');
      final downloader = _FakeDownloader([downloads.DownloadCompleted(tempApkPath)]);
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(manifest.toJson()),
        downloader: downloader,
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');
      await installer.download();

      expect(states.last, isA<UpdateVerified>());
    });

    test('verifies signing cert and fails on mismatch', () async {
      DigitInstallerPlatform.instance = _FakePlatform(apkSigningCertSha256: 'wrong-cert');
      final manifest = _manifest(signingCertSha256: 'expected-cert');
      final downloader = _FakeDownloader([downloads.DownloadCompleted(tempApkPath)]);
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(manifest.toJson()),
        downloader: downloader,
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');
      await installer.download();

      expect(states.last, isA<UpdateFailed>());
      expect((states.last as UpdateFailed).reason, isA<SignatureMismatch>());
    });

    test('passes when signing cert matches', () async {
      DigitInstallerPlatform.instance = _FakePlatform(apkSigningCertSha256: 'expected-cert');
      final manifest = _manifest(signingCertSha256: 'expected-cert');
      final downloader = _FakeDownloader([downloads.DownloadCompleted(tempApkPath)]);
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(manifest.toJson()),
        downloader: downloader,
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');
      await installer.download();

      expect(states.last, isA<UpdateVerified>());
    });

    test('maps DownloadFailed(ChecksumMismatch) through to UpdateFailed(ChecksumMismatch)', () async {
      final manifest = _manifest();
      final downloader = _FakeDownloader(const [
        downloads.DownloadFailed(
          downloads.DownloadChecksumMismatch(expectedSha256: 'a', actualSha256: 'b'),
        ),
      ]);
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(manifest.toJson()),
        downloader: downloader,
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');
      await installer.download();

      expect(states.last, isA<UpdateFailed>());
      expect((states.last as UpdateFailed).reason, isA<ChecksumMismatch>());
    });

    test('emits UpdatePaused when the downloader reports Paused', () async {
      final manifest = _manifest();
      final downloader = _FakeDownloader(const [
        downloads.DownloadPaused(
          downloads.DownloadProgress(bytesReceived: 20, totalBytes: 100, bytesPerSecond: 0, chunksTotal: 1, chunksCompleted: 0),
        ),
      ]);
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(manifest.toJson()),
        downloader: downloader,
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');
      await installer.download();

      expect(states.last, isA<UpdatePaused>());
    });

    test('pauseDownload/cancelDownload forward the correct taskId to the downloader', () async {
      final manifest = _manifest();
      final downloader = _FakeDownloader(const []);
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(manifest.toJson()),
        downloader: downloader,
      );

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');
      await installer.pauseDownload();
      await installer.cancelDownload();

      final expectedTaskId = 'digit_installer.${manifest.versionCode}.${manifest.sha256}';
      expect(downloader.lastPausedTaskId, expectedTaskId);
      expect(downloader.lastCancelledTaskId, expectedTaskId);
    });
  });

  group('install', () {
    test('emits Installing then Installed on success', () async {
      DigitInstallerPlatform.instance = _FakePlatform(
        installEvents: const [InstallProgress(0.5), InstallSucceeded()],
      );
      final manifest = _manifest();
      final downloader = _FakeDownloader([downloads.DownloadCompleted(tempApkPath)]);
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(manifest.toJson()),
        downloader: downloader,
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');
      await installer.download();
      await installer.install();

      expect(states.any((s) => s is UpdateInstalling), isTrue);
      expect(states.last, isA<UpdateInstalled>());
      expect((states.last as UpdateInstalled).installedVersion, manifest.version);
    });

    test('maps a cancelled install to UserCancelled', () async {
      DigitInstallerPlatform.instance = _FakePlatform(
        installEvents: const [InstallFailed(nativeStatusCode: 2, userCancelled: true)],
      );
      final manifest = _manifest();
      final downloader = _FakeDownloader([downloads.DownloadCompleted(tempApkPath)]);
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(manifest.toJson()),
        downloader: downloader,
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');
      await installer.download();
      await installer.install();

      expect(states.last, isA<UpdateFailed>());
      expect((states.last as UpdateFailed).reason, isA<UserCancelled>());
    });

    test('emits UnsupportedPlatform when the platform does not support install', () async {
      DigitInstallerPlatform.instance = _FakePlatform(installSupported: false);
      final manifest = _manifest();
      final downloader = _FakeDownloader([downloads.DownloadCompleted(tempApkPath)]);
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(manifest.toJson()),
        downloader: downloader,
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');
      await installer.download();
      await installer.install();

      expect(states.last, isA<UpdateFailed>());
      expect((states.last as UpdateFailed).reason, isA<UnsupportedPlatform>());
    });

    test('emits InstallUnknownAppsNotPermitted when permission is not granted', () async {
      DigitInstallerPlatform.instance = _FakePlatform(canRequestInstalls: false);
      final manifest = _manifest();
      final downloader = _FakeDownloader([downloads.DownloadCompleted(tempApkPath)]);
      final installer = DigitInstaller(
        DigitInstallerConfig(manifestUrl: Uri.parse('https://example.com/manifest.json')),
        httpClient: _manifestClient(manifest.toJson()),
        downloader: downloader,
      );
      final states = <UpdateState>[];
      installer.updates.listen(states.add);

      await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');
      await installer.download();
      await installer.install();

      expect(states.last, isA<UpdateFailed>());
      expect((states.last as UpdateFailed).reason, isA<InstallUnknownAppsNotPermitted>());
    });

    test(
      'silentDeviceOwner mode falls back to non-silent install when not eligible',
      () async {
        final receivedSilentArgs = <bool>[];
        DigitInstallerPlatform.instance = _RecordingInstallPlatform(
          silentEligibility: const SilentInstallNotDeviceOwner(),
          onInstall: receivedSilentArgs.add,
        );
        final manifest = _manifest();
        final downloader = _FakeDownloader([downloads.DownloadCompleted(tempApkPath)]);
        final installer = DigitInstaller(
          DigitInstallerConfig(
            manifestUrl: Uri.parse('https://example.com/manifest.json'),
            installMode: InstallMode.silentDeviceOwner,
          ),
          httpClient: _manifestClient(manifest.toJson()),
          downloader: downloader,
        );

        await installer.checkForUpdate(currentVersionCode: 1, currentVersion: '1.0.0');
        await installer.download();
        await installer.install();

        expect(receivedSilentArgs, [false]);
      },
    );
  });
}

class _RecordingInstallPlatform extends DigitInstallerPlatform {
  _RecordingInstallPlatform({required this.silentEligibility, required this.onInstall});
  final SilentInstallEligibility silentEligibility;
  final void Function(bool silent) onInstall;

  @override
  bool get supportsInstall => true;

  @override
  Future<bool> canRequestPackageInstalls() async => true;

  @override
  Future<SilentInstallEligibility> checkSilentInstallEligibility() async => silentEligibility;

  @override
  Stream<InstallProgressEvent> install({
    required String apkFilePath,
    required int sizeBytes,
    required bool silent,
    required bool reopenAfterInstall,
  }) {
    onInstall(silent);
    return Stream.fromIterable(const [InstallSucceeded()]);
  }
}
