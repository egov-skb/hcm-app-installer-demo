/// The raw event shape the platform interface's `install()` stream emits.
/// Internal to the package — [DigitInstaller] maps these onto the public
/// [UpdateState] sealed hierarchy (`UpdateInstalling`/`UpdateInstalled`/
/// `UpdateFailed`).
sealed class InstallProgressEvent {
  const InstallProgressEvent();
}

final class InstallProgress extends InstallProgressEvent {
  const InstallProgress(this.fraction);
  final double fraction;
}

final class InstallSucceeded extends InstallProgressEvent {
  const InstallSucceeded();
}

final class InstallFailed extends InstallProgressEvent {
  const InstallFailed({this.nativeStatusCode, this.message, required this.userCancelled});
  final int? nativeStatusCode;
  final String? message;

  /// True when the platform reported the user explicitly declined the
  /// confirmation dialog (Android `STATUS_FAILURE_ABORTED`), as opposed to a
  /// genuine installer error.
  final bool userCancelled;
}
