import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:digit_installer/src/platform_interface/method_channel_digit_installer.dart';
import 'package:digit_installer/src/state/install_progress_event.dart';
import 'package:digit_installer/src/state/silent_install_eligibility.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const methodChannel = MethodChannel('com.egov.digit_installer');
  const eventChannel = EventChannel('com.egov.digit_installer/install_events');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late MethodChannelDigitInstaller platform;
  final log = <MethodCall>[];

  setUp(() {
    platform = MethodChannelDigitInstaller();
    log.clear();
    messenger.setMockMethodCallHandler(methodChannel, (call) async {
      log.add(call);
      switch (call.method) {
        case 'getApkSigningCertSha256':
          return 'apk-cert-hash';
        case 'getInstalledSigningCertSha256':
          return 'installed-cert-hash';
        case 'checkSilentInstallEligibility':
          return {'eligibility': 'eligible', 'sdkInt': 33};
        case 'canRequestPackageInstalls':
          return true;
        case 'openInstallUnknownAppsSettings':
          return null;
        case 'createInstallSession':
          return 42;
        case 'commitSession':
          return null;
        case 'abandonSession':
          return null;
        default:
          return null;
      }
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockStreamHandler(eventChannel, null);
  });

  test('getApkSigningCertSha256 forwards the path argument and returns the result', () async {
    final result = await platform.getApkSigningCertSha256('/tmp/app.apk');
    expect(result, 'apk-cert-hash');
    expect(log.single.method, 'getApkSigningCertSha256');
    expect(log.single.arguments, {'path': '/tmp/app.apk'});
  });

  test('getInstalledSigningCertSha256 returns the native result', () async {
    expect(await platform.getInstalledSigningCertSha256(), 'installed-cert-hash');
  });

  test('checkSilentInstallEligibility maps "eligible"', () async {
    expect(await platform.checkSilentInstallEligibility(), isA<SilentInstallEligible>());
  });

  test('checkSilentInstallEligibility maps "unsupported_api_level" with sdkInt', () async {
    messenger.setMockMethodCallHandler(
      methodChannel,
      (call) async => {'eligibility': 'unsupported_api_level', 'sdkInt': 28},
    );
    final eligibility = await platform.checkSilentInstallEligibility();
    expect(eligibility, isA<SilentInstallUnsupportedApiLevel>());
    expect((eligibility as SilentInstallUnsupportedApiLevel).currentSdkInt, 28);
  });

  test('checkSilentInstallEligibility maps "not_device_owner"', () async {
    messenger.setMockMethodCallHandler(methodChannel, (call) async => {'eligibility': 'not_device_owner'});
    expect(await platform.checkSilentInstallEligibility(), isA<SilentInstallNotDeviceOwner>());
  });

  test('canRequestPackageInstalls returns the native bool', () async {
    expect(await platform.canRequestPackageInstalls(), isTrue);
  });

  test(
    'install() creates a session, commits it, and streams events filtered by sessionId',
    () async {
      messenger.setMockStreamHandler(
        eventChannel,
        MockStreamHandler.inline(
          onListen: (arguments, events) {
            events.success({'sessionId': 42, 'kind': 'progress', 'progress': 0.5});
            // A different, unrelated session's events must be filtered out.
            events.success({'sessionId': 99, 'kind': 'progress', 'progress': 0.9});
            events.success({'sessionId': 42, 'kind': 'status', 'status': 0});
          },
        ),
      );

      final events = await platform.install(apkFilePath: '/tmp/app.apk', sizeBytes: 100, silent: false, reopenAfterInstall: false).toList();

      expect(events.length, 2);
      expect(events[0], isA<InstallProgress>());
      expect((events[0] as InstallProgress).fraction, 0.5);
      expect(events[1], isA<InstallSucceeded>());
      expect(log.map((c) => c.method), containsAllInOrder(['createInstallSession', 'commitSession']));
    },
  );

  test('install() maps status 2 (STATUS_FAILURE_ABORTED) to userCancelled', () async {
    messenger.setMockStreamHandler(
      eventChannel,
      MockStreamHandler.inline(
        onListen: (arguments, events) {
          events.success({'sessionId': 42, 'kind': 'status', 'status': 2, 'message': 'aborted'});
        },
      ),
    );

    final events = await platform.install(apkFilePath: '/tmp/app.apk', sizeBytes: 100, silent: false, reopenAfterInstall: false).toList();

    expect(events.single, isA<InstallFailed>());
    expect((events.single as InstallFailed).userCancelled, isTrue);
  });
}
