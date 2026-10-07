// UNVERIFIED — written without access to Xcode/macOS to compile or run
// this. See the package README's "iOS background downloads" section
// before relying on it; build and debug on a real Mac/device first.

import Flutter
import UIKit

public class DigitDownloaderPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
    private var eventSink: FlutterEventSink?

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(name: "com.egov.digit_downloader", binaryMessenger: registrar.messenger())
        let eventChannel = FlutterEventChannel(name: "com.egov.digit_downloader/events", binaryMessenger: registrar.messenger())

        let instance = DigitDownloaderPlugin()
        registrar.addMethodCallDelegate(instance, channel: channel)
        eventChannel.setStreamHandler(instance)

        BackgroundDownloadManager.shared.onEvent = { [weak instance] _, event in
            DispatchQueue.main.async {
                instance?.eventSink?(event)
            }
        }
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        guard let args = call.arguments as? [String: Any] else {
            result(FlutterError(code: "invalid_args", message: "arguments must be a map", details: nil))
            return
        }

        switch call.method {
        case "start":
            guard let taskId = args["taskId"] as? String, let urlString = args["url"] as? String, let url = URL(string: urlString) else {
                result(FlutterError(code: "invalid_args", message: "taskId and url are required", details: nil))
                return
            }
            let headers = (args["headers"] as? [String: Any])?.mapValues { "\($0)" } ?? [:]
            let pinsRaw = args["certificatePins"] as? [String: Any] ?? [:]
            let pins = pinsRaw.mapValues { value -> Set<String> in
                Set((value as? [Any])?.map { "\($0)" } ?? [])
            }
            let spec = DownloadSpec(
                taskId: taskId, url: url,
                destinationPath: args["destinationPath"] as? String,
                chunkCount: args["chunkCount"] as? Int ?? 4,
                minChunkSize: Int64(args["minChunkSize"] as? Int ?? 1024 * 1024),
                maxRetriesPerChunk: args["maxRetriesPerChunk"] as? Int ?? 3,
                expectedSha256: args["expectedSha256"] as? String,
                headers: headers, pinsByHost: pins,
                notificationConfig: NotificationConfig.from(args["notification"] as? [String: Any]))
            BackgroundDownloadManager.shared.start(spec)
            result(nil)
        case "pause":
            guard let taskId = args["taskId"] as? String else {
                result(FlutterError(code: "invalid_args", message: "taskId is required", details: nil))
                return
            }
            BackgroundDownloadManager.shared.pause(taskId: taskId)
            result(nil)
        case "cancel":
            guard let taskId = args["taskId"] as? String else {
                result(FlutterError(code: "invalid_args", message: "taskId is required", details: nil))
                return
            }
            BackgroundDownloadManager.shared.cancel(taskId: taskId)
            result(nil)
        case "hasResumable":
            guard let taskId = args["taskId"] as? String else {
                result(FlutterError(code: "invalid_args", message: "taskId is required", details: nil))
                return
            }
            result(BackgroundDownloadManager.shared.hasResumableDownload(taskId: taskId))
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
        eventSink = events
        return nil
    }

    public func onCancel(withArguments arguments: Any?) -> FlutterError? {
        eventSink = nil
        return nil
    }
}
