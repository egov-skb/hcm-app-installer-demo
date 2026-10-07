import 'package:digit_downloader/digit_downloader.dart' show DownloadProgress;

import '../models/update_manifest.dart';
import 'update_failure.dart';

/// The full lifecycle of an update, as a Dart 3 sealed class so consumers
/// can pattern-match exhaustively with a `switch` (no `default`/`_` branch
/// needed).
sealed class UpdateState {
  const UpdateState();
}

final class UpdateIdle extends UpdateState {
  const UpdateIdle();
}

final class UpdateChecking extends UpdateState {
  const UpdateChecking();
}

final class UpdateAvailable extends UpdateState {
  const UpdateAvailable(this.manifest);
  final UpdateManifest manifest;
}

final class UpdateUpToDate extends UpdateState {
  const UpdateUpToDate(this.currentVersion);
  final String currentVersion;
}

/// Between [DigitInstaller.download] being called and the first real
/// progress update — permission checks, a method-channel round trip,
/// native service startup, and the initial HEAD request all take real
/// time before any bytes move. Without this, hosts have nothing to show
/// during that gap; [UpdateAvailable]'s "Download" affordance would look
/// unresponsive until [UpdateDownloading] finally arrives.
final class UpdateInitializing extends UpdateState {
  const UpdateInitializing();
}

/// Carries [DownloadProgress] straight from `digit_downloader` rather than a
/// redefined duplicate — the download engine lives there, this package only
/// orchestrates it.
final class UpdateDownloading extends UpdateState {
  const UpdateDownloading(this.progress);
  final DownloadProgress progress;
}

/// A paused download keeps its partial file and resume metadata on disk.
/// There is no separate "resume" call — calling [DigitInstaller.download]
/// again resumes automatically.
final class UpdatePaused extends UpdateState {
  const UpdatePaused(this.progress);
  final DownloadProgress progress;
}

final class UpdateVerifying extends UpdateState {
  const UpdateVerifying(this.filePath);
  final String filePath;
}

/// Checksum (and, on Android, signing-certificate) verification passed —
/// ready for [DigitInstaller.install].
final class UpdateVerified extends UpdateState {
  const UpdateVerified(this.filePath, this.manifest);
  final String filePath;
  final UpdateManifest manifest;
}

final class UpdateInstalling extends UpdateState {
  const UpdateInstalling(this.fraction);
  final double fraction;
}

final class UpdateInstalled extends UpdateState {
  const UpdateInstalled(this.installedVersion);
  final String installedVersion;
}

final class UpdateFailed extends UpdateState {
  const UpdateFailed(this.reason);
  final UpdateFailure reason;
}
