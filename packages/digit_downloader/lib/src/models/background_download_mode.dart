/// How resilient a download needs to be to the app being backgrounded or
/// killed outright. Selected per request via [DownloadRequest.backgroundMode].
enum BackgroundDownloadMode {
  /// Runs entirely inside the Dart isolate that started it — today's
  /// behavior, unchanged. Keeps going while the app is backgrounded but its
  /// process is still alive; the download dies if the OS or the user kills
  /// the app outright. No native code involved, no notification shown.
  appLifecycle,

  /// Delegates the transfer to a native background engine — an Android
  /// foreground `Service`, an iOS background `URLSession` — that survives
  /// full process death, complete with a live progress notification.
  /// Falls back to [appLifecycle] on platforms without a native
  /// implementation (desktop, web).
  systemManaged,
}
