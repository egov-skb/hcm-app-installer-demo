import '../platform_interface/digit_installer_platform.dart';

/// iOS is explicitly unsupported for install in v1 — Apple doesn't allow
/// apps to silently install arbitrary binaries outside the App Store.
/// `DigitInstaller.checkForUpdate` (a plain HTTP GET) still works regardless;
/// only install-related calls surface `UnsupportedPlatform` (the facade
/// checks [supportsInstall] before ever reaching this class's `install()`).
/// A future version may add an App Store/TestFlight redirect or enterprise
/// itms-services OTA flow — this class is the extension point for that.
class DigitInstallerIos extends DigitInstallerPlatform {
  static void registerWith() {
    DigitInstallerPlatform.instance = DigitInstallerIos();
  }
}
