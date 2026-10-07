/// How [DigitInstaller.install] should attempt to install the update on
/// Android.
enum InstallMode {
  /// The `PackageInstaller` Session API with a single system confirmation
  /// dialog and real-time progress. Works for any app.
  consumerConfirm,

  /// Attempts a fully silent install (no confirmation dialog at all) using
  /// `setRequireUserAction(USER_ACTION_NOT_REQUIRED)`, API 31+. Only takes
  /// effect when the app is confirmed to be a Device Owner (MDM/kiosk) —
  /// see [DigitInstaller.checkSilentInstallEligibility]. Falls back to
  /// [consumerConfirm] behavior otherwise; never attempted blindly.
  silentDeviceOwner,
}
