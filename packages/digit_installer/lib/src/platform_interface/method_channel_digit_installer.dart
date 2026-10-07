import 'dart:async';

import 'package:flutter/services.dart';

import '../state/install_progress_event.dart';
import '../state/silent_install_eligibility.dart';
import 'digit_installer_platform.dart';

/// The Android implementation — the only platform with real native code.
/// Registered as the `android` `dartPluginClass` in pubspec.yaml directly
/// (no separate wrapper class): [registerWith] is what Flutter's generated
/// plugin registrant calls on Android.
///
/// Also serves as [DigitInstallerPlatform]'s static default instance — on any
/// platform where nothing has registered a replacement (i.e. every platform
/// other than Android, before its own pure-Dart `dartPluginClass` runs),
/// invoking these methods surfaces a clear `MissingPluginException` rather
/// than silently doing nothing.
class MethodChannelDigitInstaller extends DigitInstallerPlatform {
  static const MethodChannel _channel = MethodChannel('com.egov.digit_installer');
  static const EventChannel _eventChannel = EventChannel(
    'com.egov.digit_installer/install_events',
  );

  static void registerWith() {
    DigitInstallerPlatform.instance = MethodChannelDigitInstaller();
  }

  @override
  bool get supportsInstall => true;

  @override
  bool get supportsSignatureVerification => true;

  @override
  Future<String?> getApkSigningCertSha256(String apkFilePath) {
    return _channel.invokeMethod<String>('getApkSigningCertSha256', {'path': apkFilePath});
  }

  @override
  Future<String?> getInstalledSigningCertSha256() {
    return _channel.invokeMethod<String>('getInstalledSigningCertSha256');
  }

  @override
  Future<SilentInstallEligibility> checkSilentInstallEligibility() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('checkSilentInstallEligibility');
    switch (result?['eligibility']) {
      case 'eligible':
        return const SilentInstallEligible();
      case 'unsupported_api_level':
        return SilentInstallUnsupportedApiLevel(result?['sdkInt'] as int? ?? 0);
      case 'not_device_owner':
      default:
        return const SilentInstallNotDeviceOwner();
    }
  }

  @override
  Future<bool> canRequestPackageInstalls() async {
    return (await _channel.invokeMethod<bool>('canRequestPackageInstalls')) ?? false;
  }

  @override
  Future<void> openInstallUnknownAppsSettings() {
    return _channel.invokeMethod('openInstallUnknownAppsSettings');
  }

  @override
  Future<bool> ensureNotificationPermission() async {
    return (await _channel.invokeMethod<bool>('ensureNotificationPermission')) ?? false;
  }

  @override
  Stream<InstallProgressEvent> install({
    required String apkFilePath,
    required int sizeBytes,
    required bool silent,
    required bool reopenAfterInstall,
  }) {
    late final StreamController<InstallProgressEvent> controller;
    StreamSubscription<dynamic>? eventSubscription;

    controller = StreamController<InstallProgressEvent>(
      onListen: () async {
        try {
          final sessionId = await _channel.invokeMethod<int>('createInstallSession', {
            'sizeBytes': sizeBytes,
            'silent': silent,
            'reopenAfterInstall': reopenAfterInstall,
          });

          eventSubscription = _eventChannel.receiveBroadcastStream().listen((event) {
            final map = Map<String, dynamic>.from(event as Map);
            if (map['sessionId'] != sessionId) return;

            if (map['kind'] == 'progress') {
              controller.add(InstallProgress((map['progress'] as num).toDouble()));
              return;
            }

            final status = map['status'] as int;
            if (status == 0) {
              controller.add(const InstallSucceeded());
            } else {
              controller.add(
                InstallFailed(
                  nativeStatusCode: status,
                  message: map['message'] as String?,
                  // Android STATUS_FAILURE_ABORTED == 2: the user declined
                  // the confirmation dialog.
                  userCancelled: status == 2,
                ),
              );
            }
            eventSubscription?.cancel();
            controller.close();
          });

          await _channel.invokeMethod('commitSession', {
            'sessionId': sessionId,
            'apkFilePath': apkFilePath,
          });
        } catch (e) {
          controller.add(InstallFailed(message: e.toString(), userCancelled: false));
          await eventSubscription?.cancel();
          await controller.close();
        }
      },
      onCancel: () => eventSubscription?.cancel(),
    );

    return controller.stream;
  }
}
