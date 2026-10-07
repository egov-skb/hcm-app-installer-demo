// UNVERIFIED — written without access to Xcode/macOS to compile or run
// this. See the package README before relying on it; build and debug on
// a real Mac/device before shipping.

import Foundation

/// An inclusive byte range `[start, endInclusive]`, mirroring `ByteRange` in
/// the Dart engine and `ByteRange` in the Android native engine.
struct ByteRange: Codable {
    let start: Int64
    let endInclusive: Int64

    var length: Int64 { endInclusive - start + 1 }
}

/// A Swift port of `ChunkPlanner` — kept behaviorally identical to the Dart
/// and Kotlin versions so a download planned by any one of the three
/// engines resumes correctly if picked up by another.
enum ChunkPlanner {
    static func plan(totalBytes: Int64, chunkCount: Int, minChunkSize: Int64) -> [ByteRange] {
        if totalBytes <= 0 {
            return [ByteRange(start: 0, endInclusive: -1)]
        }

        let maxPossibleChunks = totalBytes / minChunkSize
        let effectiveCount: Int
        if maxPossibleChunks < 1 {
            effectiveCount = 1
        } else if Int64(chunkCount) < maxPossibleChunks {
            effectiveCount = chunkCount
        } else {
            effectiveCount = Int(maxPossibleChunks)
        }

        let baseSize = totalBytes / Int64(effectiveCount)
        let remainder = totalBytes % Int64(effectiveCount)

        var ranges: [ByteRange] = []
        var start: Int64 = 0
        for i in 0..<effectiveCount {
            let size = baseSize + (Int64(i) < remainder ? 1 : 0)
            let end = start + size - 1
            ranges.append(ByteRange(start: start, endInclusive: end))
            start = end + 1
        }
        return ranges
    }
}

/// Resume state for one taskId.
///
/// iOS's granularity is coarser than the Dart/Android engines: a
/// `URLSessionDownloadTask` either completes a chunk in full or it doesn't
/// — there's no simple mid-chunk byte offset to persist the way a raw
/// streamed connection gives you, so `chunkCompleted` tracks whole chunks
/// rather than exact bytes-per-chunk. A resumed download re-downloads any
/// chunk that wasn't already fully completed, rather than continuing it
/// from a partial byte offset.
struct DownloadSnapshot: Codable {
    let taskId: String
    let totalBytes: Int64
    let etag: String?
    let ranges: [ByteRange]
    var chunkCompleted: [Bool]
}

/// Customizes the notification(s) shown for one download — a Swift mirror
/// of `DownloadNotificationConfig` in the Dart engine. `progressText` and
/// `failedText` support `{percent}` / `{error}` placeholders, substituted
/// here rather than via a Dart callback, since that would mean a
/// platform-channel round trip on every single progress tick.
///
/// iOS has no small-icon-per-notification concept the way Android does —
/// the system always uses the app icon — so there's no iOS equivalent of
/// `smallIconResourceName`.
struct NotificationConfig {
    var showProgress = true
    var progressTitle = "Downloading update"
    var progressText = "{percent}%"

    var showCompleted = true
    var completedTitle = "Download complete"
    var completedText: String?

    var showFailed = true
    var failedTitle = "Download failed"
    var failedText: String?

    static let `default` = NotificationConfig()

    static func from(_ raw: [String: Any]?) -> NotificationConfig {
        guard let raw else { return .default }
        var config = NotificationConfig()
        config.showProgress = raw["showProgress"] as? Bool ?? true
        config.progressTitle = raw["progressTitle"] as? String ?? config.progressTitle
        config.progressText = raw["progressText"] as? String ?? config.progressText
        config.showCompleted = raw["showCompleted"] as? Bool ?? true
        config.completedTitle = raw["completedTitle"] as? String ?? config.completedTitle
        config.completedText = raw["completedText"] as? String
        config.showFailed = raw["showFailed"] as? Bool ?? true
        config.failedTitle = raw["failedTitle"] as? String ?? config.failedTitle
        config.failedText = raw["failedText"] as? String
        return config
    }
}

/// Persists `DownloadSnapshot`s in `UserDefaults` — separate from anything
/// Dart-side, since this must be readable/writable with no Dart isolate (or
/// even Flutter engine) attached, which is the whole point of
/// `BackgroundDownloadMode.systemManaged`.
final class SnapshotStore {
    private let defaults = UserDefaults.standard
    private static let keyPrefix = "digit_downloader.snapshot."

    func read(taskId: String) -> DownloadSnapshot? {
        guard let data = defaults.data(forKey: Self.keyPrefix + taskId) else { return nil }
        return try? JSONDecoder().decode(DownloadSnapshot.self, from: data)
    }

    func write(_ snapshot: DownloadSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: Self.keyPrefix + snapshot.taskId)
    }

    func delete(taskId: String) {
        defaults.removeObject(forKey: Self.keyPrefix + taskId)
    }
}
