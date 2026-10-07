/// A modern, self-hosted APK auto-updater for Flutter — no Play Store or
/// Play Services required.
library;

export 'src/digit_installer.dart';
export 'src/models/install_mode.dart';
export 'src/models/installer_config.dart';
export 'src/models/update_manifest.dart';
export 'src/platform_desktop/digit_installer_desktop.dart';
export 'src/platform_interface/digit_installer_platform.dart';
export 'src/platform_interface/method_channel_digit_installer.dart';
export 'src/platform_ios/digit_installer_ios.dart';
export 'src/state/install_progress_event.dart';
export 'src/state/silent_install_eligibility.dart';
export 'src/state/update_failure.dart';
export 'src/state/update_state.dart';
