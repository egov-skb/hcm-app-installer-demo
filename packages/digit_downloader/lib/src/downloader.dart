import 'models/download_request.dart';
import 'state/download_state.dart';

/// Public interface implemented by [DigitDownloader] — exposed so consumers
/// (including `just_installer`) can fake the downloader in their own tests
/// without depending on a concrete HTTP/file-system implementation.
abstract interface class Downloader {
  Stream<DownloadState> start(DownloadRequest request);

  Future<void> pause(String taskId);

  Future<void> cancel(String taskId);

  Future<bool> hasResumableDownload(String taskId);

  /// Whether [request]'s destination file already exists in full and
  /// matches [DownloadRequest.expectedSha256] — i.e. a previous [start]
  /// already completed this exact download and it was never moved/deleted.
  /// Always false when [DownloadRequest.expectedSha256] is null, since
  /// completeness can't be verified without it.
  Future<bool> isComplete(DownloadRequest request);
}
