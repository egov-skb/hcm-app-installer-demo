import 'dart:io';

import '../platform_interface/digit_installer_platform.dart';

/// Windows/macOS/Linux: there's no unified OS-level "install session" API
/// like Android's PackageInstaller, so `install()` (the Android-style
/// progress-stream flow) isn't supported here — [supportsInstall] stays
/// `false`. Instead, once a download is checksum-verified, the host app
/// explicitly calls `DigitInstaller.runDownloadedInstaller()` (a direct
/// user-tap response, never triggered automatically) which reaches
/// [runInstaller] below: launch the platform-native installer/executable
/// and let the user drive it, without this package auto-quitting the
/// running app on its own initiative.
class DigitInstallerDesktop extends DigitInstallerPlatform {
  static void registerWith() {
    DigitInstallerPlatform.instance = DigitInstallerDesktop();
  }

  @override
  Future<void> runInstaller(String filePath) async {
    if (Platform.isWindows) {
      await Process.start(filePath, const [], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await Process.start('open', [filePath], mode: ProcessStartMode.detached);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [filePath], mode: ProcessStartMode.detached);
    }
  }

  @override
  Future<void> revealInFileManager(String filePath) async {
    if (Platform.isWindows) {
      await Process.start('explorer', ['/select,$filePath'], mode: ProcessStartMode.detached);
    } else if (Platform.isMacOS) {
      await Process.start('open', ['-R', filePath], mode: ProcessStartMode.detached);
    } else if (Platform.isLinux) {
      await Process.start('xdg-open', [File(filePath).parent.path], mode: ProcessStartMode.detached);
    }
  }
}
