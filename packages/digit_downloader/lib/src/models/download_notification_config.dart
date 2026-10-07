/// Android notification channel importance — controls how noticeable the
/// progress notification is. `low` (no sound, no heads-up peek) is easy to
/// miss while the app is in the foreground and you're not deliberately
/// checking the notification shade; `normal` is the default for exactly
/// that reason. No iOS equivalent — iOS doesn't have channels.
enum DownloadNotificationImportance {
  low,
  normal,
  high;

  /// The `android.app.NotificationManager.IMPORTANCE_*` constant this maps
  /// to, encoded as an int since the enum itself can't cross a
  /// MethodChannel.
  int get androidValue => switch (this) {
    DownloadNotificationImportance.low => 2, // IMPORTANCE_LOW
    DownloadNotificationImportance.normal => 3, // IMPORTANCE_DEFAULT
    DownloadNotificationImportance.high => 4, // IMPORTANCE_HIGH
  };
}

/// Customizes the notification(s) shown by a
/// [BackgroundDownloadMode.systemManaged] download — Android's live
/// progress notification and both platforms' terminal (complete/failed)
/// notification. Has no effect under [BackgroundDownloadMode.appLifecycle],
/// which never shows a notification at all.
///
/// [progressText] and [failedText] support a `{percent}` / `{error}`
/// placeholder respectively, substituted natively (Android/iOS) on every
/// update — not a Dart callback, since that would mean a platform-channel
/// round trip on every single progress tick.
class DownloadNotificationConfig {
  const DownloadNotificationConfig({
    this.channelId = 'digit_downloader_progress',
    this.channelName = 'Downloads',
    this.channelDescription,
    this.channelImportance = DownloadNotificationImportance.normal,
    this.smallIconResourceName,
    this.showProgress = true,
    this.progressTitle = 'Downloading update',
    this.progressText = '{percent}%',
    this.showCompleted = true,
    this.completedTitle = 'Download complete',
    this.completedText,
    this.showFailed = true,
    this.failedTitle = 'Download failed',
    this.failedText,
  });

  /// Android notification channel id. Changing this from one call to the
  /// next effectively creates a separate channel — the user's per-channel
  /// notification settings (sound, importance, etc.) follow the id, not
  /// [channelName].
  final String channelId;

  /// Android notification channel display name, shown in system settings.
  final String channelName;

  final String? channelDescription;

  /// Android only. Defaults to `normal` — `low` is silent/unobtrusive
  /// enough that it's easy to genuinely never notice while the app is in
  /// the foreground.
  final DownloadNotificationImportance channelImportance;

  /// Android only: a drawable/mipmap resource name (e.g. `'ic_notification'`)
  /// resolved at runtime via the host app's own resources. `null` falls
  /// back to the app's launcher icon. No iOS equivalent — the system uses
  /// the app icon automatically there.
  final String? smallIconResourceName;

  /// Whether to show a notification at all while a download is in
  /// progress. `false` still runs the download (and, on Android, still
  /// requires *a* foreground-service notification to exist while running —
  /// it's shown silently/minimally rather than omitted outright).
  final bool showProgress;
  final String progressTitle;
  final String progressText;

  final bool showCompleted;
  final String completedTitle;
  final String? completedText;

  final bool showFailed;
  final String failedTitle;

  /// Supports a `{error}` placeholder, substituted with a short
  /// human-readable failure description.
  final String? failedText;

  Map<String, dynamic> toJson() => {
    'channelId': channelId,
    'channelName': channelName,
    'channelDescription': channelDescription,
    'channelImportance': channelImportance.androidValue,
    'smallIconResourceName': smallIconResourceName,
    'showProgress': showProgress,
    'progressTitle': progressTitle,
    'progressText': progressText,
    'showCompleted': showCompleted,
    'completedTitle': completedTitle,
    'completedText': completedText,
    'showFailed': showFailed,
    'failedTitle': failedTitle,
    'failedText': failedText,
  };
}
