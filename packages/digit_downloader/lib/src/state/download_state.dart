import 'download_failure.dart';
import 'download_progress.dart';

/// The lifecycle of a single download, as a Dart 3 sealed class so consumers
/// can pattern-match exhaustively with a `switch` (no `default`/`_` branch
/// needed).
sealed class DownloadState {
  const DownloadState();
}

final class DownloadIdle extends DownloadState {
  const DownloadIdle();
}

final class DownloadStarting extends DownloadState {
  const DownloadStarting();
}

final class DownloadInProgress extends DownloadState {
  const DownloadInProgress(this.progress);
  final DownloadProgress progress;
}

/// A paused download keeps its partial file and resume metadata on disk.
/// There is no separate "resume" call — calling [DigitDownloader.start] again
/// with the same [DownloadRequest.taskId] resumes automatically.
final class DownloadPaused extends DownloadState {
  const DownloadPaused(this.progress);
  final DownloadProgress progress;
}

final class DownloadCompleted extends DownloadState {
  const DownloadCompleted(this.filePath);
  final String filePath;
}

final class DownloadFailed extends DownloadState {
  const DownloadFailed(this.reason);
  final DownloadFailure reason;
}
