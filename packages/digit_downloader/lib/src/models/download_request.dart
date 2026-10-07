import 'background_download_mode.dart';
import 'cert_pin.dart';
import 'download_notification_config.dart';

/// Describes a single download: what to fetch, where to put it, and how to
/// authenticate/verify it.
///
/// [taskId] is the stable key used for resume-state persistence — it must be
/// unique per logical download (e.g. include the version/hash of what you're
/// fetching) so an unrelated download never resumes from the wrong snapshot.
class DownloadRequest {
  const DownloadRequest({
    required this.url,
    required this.taskId,
    this.destinationPath,
    this.headersBuilder,
    this.chunkCount = 4,
    this.minChunkSize = 1024 * 1024,
    this.maxRetriesPerChunk = 3,
    this.expectedSha256,
    this.certificatePins,
    this.backgroundMode = BackgroundDownloadMode.appLifecycle,
    this.notificationConfig = const DownloadNotificationConfig(),
  });

  final Uri url;
  final String taskId;

  /// Where to write the downloaded file. If `null`, defaults to
  /// `<application support directory>/digit_downloader/<taskId>`.
  final String? destinationPath;

  /// Rebuilt on every request (not just once), so short-lived bearer tokens
  /// stay fresh across a long chunked download.
  final Future<Map<String, String>> Function()? headersBuilder;

  /// Preferred number of concurrent chunks. Collapses to 1 when the file is
  /// smaller than [minChunkSize] or the server doesn't support `Range`.
  final int chunkCount;

  final int minChunkSize;

  final int maxRetriesPerChunk;

  /// If set, the downloaded file's SHA-256 is verified before [DownloadCompleted]
  /// is emitted; a mismatch emits `DownloadFailed(DownloadChecksumMismatch)`.
  final String? expectedSha256;

  /// If set, enables TLS certificate pinning for every request this download
  /// makes.
  final CertificatePinSet? certificatePins;

  /// Whether this download needs to survive the app being backgrounded
  /// ([BackgroundDownloadMode.appLifecycle], the default) or fully killed
  /// ([BackgroundDownloadMode.systemManaged]).
  final BackgroundDownloadMode backgroundMode;

  /// Only relevant under [BackgroundDownloadMode.systemManaged] — see
  /// [DownloadNotificationConfig].
  final DownloadNotificationConfig notificationConfig;
}
