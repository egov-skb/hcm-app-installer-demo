package com.egov.digit_downloader

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import io.flutter.plugin.common.PluginRegistry

/**
 * Native side of `BackgroundDownloadMode.systemManaged` — starts/controls
 * [BackgroundDownloadService] and forwards its [DownloadEventBus] events to
 * Dart while a listener is actually attached. The service itself has no
 * dependency on this plugin (or on Flutter being loaded at all), which is
 * what lets a download survive the app process being killed.
 */
class DigitDownloaderPlugin :
    FlutterPlugin,
    MethodCallHandler,
    EventChannel.StreamHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {
    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var applicationContext: Context

    private val mainHandler = Handler(Looper.getMainLooper())
    private var eventSink: EventChannel.EventSink? = null

    private var activity: Activity? = null
    private var pendingNotificationPermissionResult: Result? = null

    private val busListener: (Map<String, Any?>) -> Unit = { event ->
        mainHandler.post { eventSink?.success(event) }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext

        channel = MethodChannel(binding.binaryMessenger, "com.egov.digit_downloader")
        channel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, "com.egov.digit_downloader/events")
        eventChannel.setStreamHandler(this)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result,
    ) {
        when (call.method) {
            "ensureNotificationPermission" -> ensureNotificationPermission(result)
            "start" -> {
                val taskId = call.argument<String>("taskId")
                val url = call.argument<String>("url")
                if (taskId == null || url == null) {
                    result.error("invalid_args", "taskId and url are required", null)
                    return
                }
                @Suppress("UNCHECKED_CAST")
                val headers = (call.argument<Map<String, Any?>>("headers") ?: emptyMap()).mapValues { it.value.toString() }
                @Suppress("UNCHECKED_CAST")
                val pinsRaw = call.argument<Map<String, Any?>>("certificatePins") ?: emptyMap()
                val pins =
                    pinsRaw.mapValues { (_, v) -> (v as? List<*>)?.map { it.toString() }?.toSet() ?: emptySet() }
                @Suppress("UNCHECKED_CAST")
                val notificationRaw = call.argument<Map<String, Any?>>("notification")
                val notificationConfig =
                    if (notificationRaw == null) {
                        NotificationConfig.DEFAULT
                    } else {
                        NotificationConfig(
                            channelId = notificationRaw["channelId"] as? String ?: NotificationConfig.DEFAULT.channelId,
                            channelName = notificationRaw["channelName"] as? String ?: NotificationConfig.DEFAULT.channelName,
                            channelDescription = notificationRaw["channelDescription"] as? String,
                            channelImportance = (notificationRaw["channelImportance"] as? Number)?.toInt()
                                ?: NotificationConfig.DEFAULT.channelImportance,
                            smallIconResourceName = notificationRaw["smallIconResourceName"] as? String,
                            showProgress = notificationRaw["showProgress"] as? Boolean ?: true,
                            progressTitle = notificationRaw["progressTitle"] as? String ?: NotificationConfig.DEFAULT.progressTitle,
                            progressText = notificationRaw["progressText"] as? String ?: NotificationConfig.DEFAULT.progressText,
                            showCompleted = notificationRaw["showCompleted"] as? Boolean ?: true,
                            completedTitle = notificationRaw["completedTitle"] as? String ?: NotificationConfig.DEFAULT.completedTitle,
                            completedText = notificationRaw["completedText"] as? String,
                            showFailed = notificationRaw["showFailed"] as? Boolean ?: true,
                            failedTitle = notificationRaw["failedTitle"] as? String ?: NotificationConfig.DEFAULT.failedTitle,
                            failedText = notificationRaw["failedText"] as? String,
                        )
                    }

                val spec =
                    DownloadSpec(
                        taskId = taskId,
                        url = url,
                        destinationPath = call.argument<String>("destinationPath"),
                        chunkCount = call.argument<Int>("chunkCount") ?: 4,
                        minChunkSize = (call.argument<Number>("minChunkSize") ?: 1024 * 1024).toLong(),
                        maxRetriesPerChunk = call.argument<Int>("maxRetriesPerChunk") ?: 3,
                        expectedSha256 = call.argument<String>("expectedSha256"),
                        headers = headers,
                        pinsByHost = pins,
                        notificationConfig = notificationConfig,
                    )
                BackgroundDownloadService.enqueueStart(applicationContext, spec)
                result.success(null)
            }
            "pause" -> {
                val taskId = call.argument<String>("taskId")
                if (taskId == null) {
                    result.error("invalid_args", "taskId is required", null)
                    return
                }
                BackgroundDownloadService.enqueuePause(applicationContext, taskId)
                result.success(null)
            }
            "cancel" -> {
                val taskId = call.argument<String>("taskId")
                if (taskId == null) {
                    result.error("invalid_args", "taskId is required", null)
                    return
                }
                BackgroundDownloadService.enqueueCancel(applicationContext, taskId)
                result.success(null)
            }
            "hasResumable" -> {
                val taskId = call.argument<String>("taskId")
                if (taskId == null) {
                    result.error("invalid_args", "taskId is required", null)
                    return
                }
                result.success(SnapshotStore(applicationContext).read(taskId) != null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Requests `POST_NOTIFICATIONS` (API 33+ only) so the download-progress
     * notification [BackgroundDownloadService] posts can actually show —
     * without this, the manifest declaration alone does nothing on API 33+;
     * `NotificationManager.notify()` just silently drops the notification.
     * Best-effort: the download itself proceeds regardless of the result.
     */
    private fun ensureNotificationPermission(result: Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            result.success(true)
            return
        }

        if (ActivityCompat.checkSelfPermission(applicationContext, Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }

        val currentActivity = activity
        if (currentActivity == null) {
            result.success(NotificationManagerCompat.from(applicationContext).areNotificationsEnabled())
            return
        }

        pendingNotificationPermissionResult = result
        mainHandler.post {
            ActivityCompat.requestPermissions(
                currentActivity,
                arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                NOTIFICATION_PERMISSION_REQUEST_CODE,
            )
        }
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ): Boolean {
        if (requestCode != NOTIFICATION_PERMISSION_REQUEST_CODE) return false
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingNotificationPermissionResult?.success(granted)
        pendingNotificationPermissionResult = null
        return true
    }

    override fun onListen(
        arguments: Any?,
        events: EventChannel.EventSink?,
    ) {
        eventSink = events
        DownloadEventBus.addListener(busListener)
    }

    override fun onCancel(arguments: Any?) {
        DownloadEventBus.removeListener(busListener)
        eventSink = null
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        DownloadEventBus.removeListener(busListener)
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        activity = null
    }

    private companion object {
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 4713
    }
}
