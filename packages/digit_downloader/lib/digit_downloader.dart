/// A generic background resumable/chunked download engine for Dart & Flutter.
library;

export 'src/downloader.dart';
export 'src/digit_downloader.dart';
export 'src/models/background_download_mode.dart';
export 'src/models/byte_range.dart';
export 'src/models/cert_pin.dart';
export 'src/models/download_notification_config.dart' show DownloadNotificationConfig, DownloadNotificationImportance;
export 'src/models/download_request.dart';
export 'src/state/download_failure.dart';
export 'src/state/download_progress.dart';
export 'src/state/download_state.dart';
