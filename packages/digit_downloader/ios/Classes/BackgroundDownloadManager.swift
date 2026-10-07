// UNVERIFIED — written without access to Xcode/macOS to compile or run
// this. See the package README's "iOS background downloads" section
// before relying on it; build and debug on a real Mac/device first.
//
// iOS's background URLSession only supports upload/download tasks (no
// data tasks), and a URLSessionDownloadTask either completes a chunk in
// full or doesn't — there's no simple mid-chunk byte offset the way a raw
// streamed connection gives Dart/Android. Resumability here is therefore
// per-chunk, not per-byte: see DownloadSnapshot.chunkCompleted.

import Foundation
import UserNotifications

struct DownloadSpec {
    let taskId: String
    let url: URL
    let destinationPath: String?
    let chunkCount: Int
    let minChunkSize: Int64
    let maxRetriesPerChunk: Int
    let expectedSha256: String?
    let headers: [String: String]
    let pinsByHost: [String: Set<String>]
    let notificationConfig: NotificationConfig
}

private final class ActiveDownload {
    let spec: DownloadSpec
    var totalBytes: Int64 = 0
    var etag: String?
    var ranges: [ByteRange] = []
    var chunkCompleted: [Bool] = []
    var chunkBytesInFlight: [Int64] = []
    var chunkRetryCount: [Int] = []
    var destinationURL: URL!
    var paused = false
    var lastNotifiedPercent = -1
    var lastProgressEmitMillis: Double = 0

    init(spec: DownloadSpec) {
        self.spec = spec
    }

    var bytesReceived: Int64 {
        var total: Int64 = 0
        for (index, range) in ranges.enumerated() {
            if chunkCompleted[index] {
                total += range.length
            } else {
                total += chunkBytesInFlight[index]
            }
        }
        return total
    }

    var chunksCompletedCount: Int { chunkCompleted.filter { $0 }.count }
}

/// Native side of `BackgroundDownloadMode.systemManaged` on iOS. One shared
/// background `URLSession` drives every download; chunks of the same
/// download are separate `URLSessionDownloadTask`s within it.
public final class BackgroundDownloadManager: NSObject {
    public static let shared = BackgroundDownloadManager()

    /// Set by DigitDownloaderPlugin when Dart is listening; events are always
    /// computed regardless, just not forwarded when nil.
    var onEvent: ((String, [String: Any?]) -> Void)?

    /// Stashed by the host app's AppDelegate via
    /// `application(_:handleEventsForBackgroundURLSession:completionHandler:)`
    /// — see the package README for the required AppDelegate wiring. Called
    /// once this session finishes delivering all its pending events.
    public var backgroundCompletionHandler: (() -> Void)?

    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.egov.digit_downloader.background")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1 // serializes delegate callbacks; see file header
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    private let snapshotStore = SnapshotStore()
    private var downloads: [String: ActiveDownload] = [:]
    private var taskMap: [Int: (taskId: String, chunkIndex: Int)] = [:]
    private let workQueue = DispatchQueue(label: "com.egov.digit_downloader.work")

    private override init() {
        super.init()
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // iOS silently drops the visual presentation of any notification
        // posted while the app is in the foreground unless a delegate
        // explicitly opts in via willPresent below — without this, progress/
        // completion notifications would only ever show while backgrounded.
        // Note: UNUserNotificationCenter has a single global delegate: if
        // the host app also needs to be one (e.g. to handle notification
        // taps of its own), it must coordinate with this rather than
        // overwrite it outright.
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - Public API (called from DigitDownloaderPlugin)

    func start(_ spec: DownloadSpec) {
        workQueue.async { [weak self] in
            self?.startLocked(spec)
        }
    }

    func pause(taskId: String) {
        workQueue.async { [weak self] in
            guard let self, let download = self.downloads[taskId] else { return }
            download.paused = true
            self.session.getAllTasks { tasks in
                for task in tasks where self.taskMap[task.taskIdentifier]?.taskId == taskId {
                    task.cancel()
                }
            }
            self.persistSnapshot(taskId: taskId, download: download)
            self.emit(taskId: taskId, event: [
                "taskId": taskId, "kind": "paused",
                "bytesReceived": download.bytesReceived, "totalBytes": download.totalBytes,
                "chunksTotal": download.ranges.count, "chunksCompleted": download.chunksCompletedCount,
            ])
            self.downloads.removeValue(forKey: taskId)
            self.clearNotification(taskId: taskId)
        }
    }

    func cancel(taskId: String) {
        workQueue.async { [weak self] in
            guard let self else { return }
            let download = self.downloads[taskId]
            self.session.getAllTasks { tasks in
                for task in tasks where self.taskMap[task.taskIdentifier]?.taskId == taskId {
                    task.cancel()
                }
            }
            if let destination = download?.destinationURL {
                try? FileManager.default.removeItem(at: destination)
            }
            self.snapshotStore.delete(taskId: taskId)
            self.emit(taskId: taskId, event: ["taskId": taskId, "kind": "failed", "failureKind": "cancelled"])
            self.downloads.removeValue(forKey: taskId)
            self.clearNotification(taskId: taskId)
        }
    }

    func hasResumableDownload(taskId: String) -> Bool {
        snapshotStore.read(taskId: taskId) != nil
    }

    // MARK: - Download orchestration

    private func startLocked(_ spec: DownloadSpec) {
        if downloads[spec.taskId] != nil { return } // already running

        let destinationPath = spec.destinationPath ?? Self.defaultDestinationPath(taskId: spec.taskId)
        let destinationURL = URL(fileURLWithPath: destinationPath)
        try? FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        probeHead(spec: spec) { [weak self] totalBytes, etag, acceptsRanges in
            guard let self else { return }
            self.workQueue.async {
                self.afterHead(spec: spec, destinationURL: destinationURL, totalBytes: totalBytes, etag: etag, acceptsRanges: acceptsRanges)
            }
        }
    }

    private func afterHead(spec: DownloadSpec, destinationURL: URL, totalBytes: Int64, etag: String?, acceptsRanges: Bool) {
        // Already downloaded and verified by a previous run that was never
        // consumed — mirrors the same fast path in the Dart/Android engines.
        if let expected = spec.expectedSha256,
            FileManager.default.fileExists(atPath: destinationURL.path),
            (try? FileManager.default.attributesOfItem(atPath: destinationURL.path)[.size] as? Int64) == totalBytes,
            ChecksumUtil.sha256OfFile(at: destinationURL) == expected
        {
            snapshotStore.delete(taskId: spec.taskId)
            emit(taskId: spec.taskId, event: ["taskId": spec.taskId, "kind": "completed", "filePath": destinationURL.path])
            return
        }

        let existing = snapshotStore.read(taskId: spec.taskId)
        let canResume =
            existing != nil && existing!.totalBytes == totalBytes && existing!.etag == etag
            && FileManager.default.fileExists(atPath: destinationURL.path)

        let download = ActiveDownload(spec: spec)
        download.totalBytes = totalBytes
        download.etag = etag
        download.destinationURL = destinationURL

        if canResume, let snapshot = existing {
            download.ranges = snapshot.ranges
            download.chunkCompleted = snapshot.chunkCompleted
        } else {
            let effectiveChunkCount = acceptsRanges ? spec.chunkCount : 1
            download.ranges = ChunkPlanner.plan(totalBytes: totalBytes, chunkCount: effectiveChunkCount, minChunkSize: spec.minChunkSize)
            download.chunkCompleted = Array(repeating: false, count: download.ranges.count)
            FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
            if let handle = try? FileHandle(forWritingTo: destinationURL) {
                try? handle.truncate(atOffset: UInt64(max(totalBytes, 0)))
                try? handle.close()
            }
        }
        download.chunkBytesInFlight = Array(repeating: 0, count: download.ranges.count)
        download.chunkRetryCount = Array(repeating: 0, count: download.ranges.count)

        downloads[spec.taskId] = download
        persistSnapshot(taskId: spec.taskId, download: download)

        for index in download.ranges.indices where !download.chunkCompleted[index] {
            startChunkTask(taskId: spec.taskId, chunkIndex: index)
        }

        if download.ranges.allSatisfy({ _ in false }) {
            // No ranges at all (shouldn't happen — ChunkPlanner always
            // returns at least one) — nothing to do.
        }
    }

    private func startChunkTask(taskId: String, chunkIndex: Int) {
        guard let download = downloads[taskId] else { return }
        let range = download.ranges[chunkIndex]

        var request = URLRequest(url: download.spec.url)
        let rangeHeader = range.endInclusive < 0 ? "bytes=\(range.start)-" : "bytes=\(range.start)-\(range.endInclusive)"
        request.setValue(rangeHeader, forHTTPHeaderField: "Range")
        for (key, value) in download.spec.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let task = session.downloadTask(with: request)
        taskMap[task.taskIdentifier] = (taskId, chunkIndex)
        task.resume()
    }

    private func probeHead(spec: DownloadSpec, completion: @escaping (Int64, String?, Bool) -> Void) {
        var request = URLRequest(url: spec.url)
        request.httpMethod = "HEAD"
        for (key, value) in spec.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }
        // A plain (non-background) session for this one-shot metadata
        // probe — background sessions don't support data/HEAD tasks.
        let probeSession = URLSession(configuration: .ephemeral, delegate: PinningProbeDelegate(pinsByHost: spec.pinsByHost), delegateQueue: nil)
        probeSession.dataTask(with: request) { _, response, _ in
            let http = response as? HTTPURLResponse
            let totalBytes = Int64(http?.value(forHTTPHeaderField: "Content-Length") ?? "") ?? (http?.expectedContentLength ?? -1)
            let etag = http?.value(forHTTPHeaderField: "ETag")
            let acceptsRanges = http?.value(forHTTPHeaderField: "Accept-Ranges") == "bytes"
            completion(max(totalBytes, 0), etag, acceptsRanges)
        }.resume()
    }

    // MARK: - Progress / persistence / notifications

    private func persistSnapshot(taskId: String, download: ActiveDownload) {
        snapshotStore.write(
            DownloadSnapshot(
                taskId: taskId, totalBytes: download.totalBytes, etag: download.etag,
                ranges: download.ranges, chunkCompleted: download.chunkCompleted))
    }

    private func reportProgress(taskId: String) {
        guard let download = downloads[taskId] else { return }
        let now = Date().timeIntervalSince1970 * 1000
        emit(taskId: taskId, event: [
            "taskId": taskId, "kind": "progress",
            "bytesReceived": download.bytesReceived, "totalBytes": download.totalBytes,
            "bytesPerSecond": 0.0,
            "chunksTotal": download.ranges.count, "chunksCompleted": download.chunksCompletedCount,
        ])

        let percent = download.totalBytes > 0 ? Int(Double(download.bytesReceived) / Double(download.totalBytes) * 100) : 0
        if percent != download.lastNotifiedPercent && now - download.lastProgressEmitMillis > 500 {
            download.lastNotifiedPercent = percent
            download.lastProgressEmitMillis = now
            showProgressNotification(taskId: taskId, percent: percent, config: download.spec.notificationConfig)
        }
    }

    private func emit(taskId: String, event: [String: Any?]) {
        onEvent?(taskId, event)
    }

    // MARK: - Notifications
    //
    // iOS has no direct equivalent of Android's animated in-notification
    // progress bar without Live Activities (which need a Widget Extension
    // target — not something addable via plain file edits). This instead
    // periodically replaces a notification with the same identifier,
    // showing the current percentage in its body.

    private func showProgressNotification(taskId: String, percent: Int, config: NotificationConfig) {
        guard config.showProgress else { return }
        let content = UNMutableNotificationContent()
        content.title = config.progressTitle
        content.body = config.progressText.replacingOccurrences(of: "{percent}", with: "\(percent)")
        content.sound = nil
        let request = UNNotificationRequest(identifier: notificationId(taskId), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func showTerminalNotification(taskId: String, success: Bool, errorText: String?, config: NotificationConfig) {
        if success && !config.showCompleted { return }
        if !success && !config.showFailed { return }

        let content = UNMutableNotificationContent()
        if success {
            content.title = config.completedTitle
            if let text = config.completedText { content.body = text }
        } else {
            content.title = config.failedTitle
            if let template = config.failedText {
                content.body = template.replacingOccurrences(of: "{error}", with: errorText ?? "")
            } else if let errorText {
                content.body = errorText
            }
        }
        content.sound = success ? .default : nil
        let request = UNNotificationRequest(identifier: notificationId(taskId), content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func clearNotification(taskId: String) {
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [notificationId(taskId)])
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [notificationId(taskId)])
    }

    private func notificationId(_ taskId: String) -> String { "digit_downloader.\(taskId)" }

    static func defaultDestinationPath(taskId: String) -> String {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("digit_downloader").appendingPathComponent(taskId).path
    }
}

// MARK: - URLSessionDownloadDelegate

extension BackgroundDownloadManager: URLSessionDownloadDelegate {
    func urlSession(
        _ session: URLSession, downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64
    ) {
        workQueue.async { [weak self] in
            guard let self, let (taskId, chunkIndex) = self.taskMap[downloadTask.taskIdentifier],
                let download = self.downloads[taskId]
            else { return }
            download.chunkBytesInFlight[chunkIndex] = totalBytesWritten
            self.reportProgress(taskId: taskId)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Must read the temp file synchronously here — the OS deletes it
        // once this method returns.
        let data = try? Data(contentsOf: location)

        workQueue.async { [weak self] in
            guard let self, let (taskId, chunkIndex) = self.taskMap[downloadTask.taskIdentifier],
                let download = self.downloads[taskId], let data
            else { return }

            let range = download.ranges[chunkIndex]
            if let handle = try? FileHandle(forWritingTo: download.destinationURL) {
                handle.seek(toFileOffset: UInt64(range.start))
                handle.write(data)
                try? handle.close()
            }

            download.chunkCompleted[chunkIndex] = true
            download.chunkBytesInFlight[chunkIndex] = 0
            self.taskMap.removeValue(forKey: downloadTask.taskIdentifier)
            self.persistSnapshot(taskId: taskId, download: download)

            if download.chunkCompleted.allSatisfy({ $0 }) {
                self.finish(taskId: taskId, download: download)
            } else {
                self.reportProgress(taskId: taskId)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error, let (taskId, chunkIndex) = taskMap[task.taskIdentifier] else { return }
        workQueue.async { [weak self] in
            guard let self, let download = self.downloads[taskId] else { return }
            self.taskMap.removeValue(forKey: task.taskIdentifier)

            if download.paused { return } // expected — pause() cancels in-flight tasks itself

            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled { return }

            download.chunkRetryCount[chunkIndex] += 1
            if download.chunkRetryCount[chunkIndex] > download.spec.maxRetriesPerChunk {
                self.downloads.removeValue(forKey: taskId)
                self.emit(taskId: taskId, event: [
                    "taskId": taskId, "kind": "failed", "failureKind": "network", "message": error.localizedDescription,
                ])
                self.showTerminalNotification(
                    taskId: taskId, success: false, errorText: error.localizedDescription,
                    config: download.spec.notificationConfig)
                return
            }
            let delay = 0.3 * Double(download.chunkRetryCount[chunkIndex])
            self.workQueue.asyncAfter(deadline: .now() + delay) {
                self.startChunkTask(taskId: taskId, chunkIndex: chunkIndex)
            }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let pins = taskMap[task.taskIdentifier].flatMap { downloads[$0.taskId]?.spec.pinsByHost } ?? [:]
        let (disposition, credential) = CertificatePinning.evaluate(challenge: challenge, pinsByHost: pins)
        completionHandler(disposition, credential)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async { [weak self] in
            self?.backgroundCompletionHandler?()
            self?.backgroundCompletionHandler = nil
        }
    }

    private func finish(taskId: String, download: ActiveDownload) {
        if let expected = download.spec.expectedSha256 {
            let actual = ChecksumUtil.sha256OfFile(at: download.destinationURL)
            if actual != expected {
                snapshotStore.delete(taskId: taskId)
                downloads.removeValue(forKey: taskId)
                emit(taskId: taskId, event: [
                    "taskId": taskId, "kind": "failed", "failureKind": "checksumMismatch",
                    "expectedSha256": expected, "actualSha256": actual,
                ])
                showTerminalNotification(
                    taskId: taskId, success: false, errorText: "Checksum did not match",
                    config: download.spec.notificationConfig)
                return
            }
        }
        snapshotStore.delete(taskId: taskId)
        downloads.removeValue(forKey: taskId)
        emit(taskId: taskId, event: ["taskId": taskId, "kind": "completed", "filePath": download.destinationURL.path])
        showTerminalNotification(taskId: taskId, success: true, errorText: nil, config: download.spec.notificationConfig)
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension BackgroundDownloadManager: UNUserNotificationCenterDelegate {
    /// Without this, `UNUserNotificationCenter.add` silently delivers the
    /// notification with no visible banner/sound while the app is in the
    /// foreground — the default behavior since iOS 10. Explicitly opting
    /// in here is what makes progress/completion notifications show
    /// regardless of whether the app is foregrounded or not.
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        if #available(iOS 14.0, *) {
            completionHandler([.banner, .sound, .list])
        } else {
            completionHandler([.alert, .sound])
        }
    }
}

/// Handles the HEAD probe's own certificate pinning — separate from the
/// main manager's delegate since the probe uses its own throwaway session.
private final class PinningProbeDelegate: NSObject, URLSessionDelegate {
    let pinsByHost: [String: Set<String>]
    init(pinsByHost: [String: Set<String>]) { self.pinsByHost = pinsByHost }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge, completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let (disposition, credential) = CertificatePinning.evaluate(challenge: challenge, pinsByHost: pinsByHost)
        completionHandler(disposition, credential)
    }
}
