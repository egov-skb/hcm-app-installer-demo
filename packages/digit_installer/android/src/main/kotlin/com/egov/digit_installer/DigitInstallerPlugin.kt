package com.egov.digit_installer

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
import io.flutter.plugin.common.StandardMethodCodec

/** DigitInstallerPlugin */
class DigitInstallerPlugin :
    FlutterPlugin,
    MethodCallHandler,
    ActivityAware,
    PluginRegistry.RequestPermissionsResultListener {

    private lateinit var channel: MethodChannel
    private lateinit var eventChannel: EventChannel
    private lateinit var applicationContext: Context

    private lateinit var sessionManager: InstallSessionManager
    private lateinit var signatureVerifier: SignatureVerifier
    private lateinit var deviceOwnerChecker: DeviceOwnerChecker
    private lateinit var permissionHelper: InstallPermissionHelper

    // requestPermissions()/onMethodCall (via the background TaskQueue) can
    // run off the main thread; permission requests touch the Activity's
    // window, so they're marshalled here the same way InstallSessionManager
    // marshals its EventSink calls. Lazy so plain-JVM unit tests that never
    // reach ensureNotificationPermission() don't touch Looper.getMainLooper()
    // (unmocked in that environment) just by constructing the plugin.
    private val mainHandler by lazy { Handler(Looper.getMainLooper()) }

    private var activity: Activity? = null
    private var pendingNotificationPermissionResult: Result? = null

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext

        // commitSession() copies a whole APK (100+ MB) to the PackageInstaller
        // session and getApkSigningCertSha256() parses the APK's signing
        // block — both real I/O/CPU work. Every call on this channel runs on
        // the platform thread by default, which on Android is the main/UI
        // thread; a background TaskQueue moves the whole channel off it so
        // neither call janks Flutter's UI rendering. None of these methods
        // touch Android Views, so none require the main thread.
        channel =
            MethodChannel(
                binding.binaryMessenger,
                "com.egov.digit_installer",
                StandardMethodCodec.INSTANCE,
                binding.binaryMessenger.makeBackgroundTaskQueue(),
            )
        channel.setMethodCallHandler(this)

        sessionManager = InstallSessionManager(applicationContext)
        eventChannel = EventChannel(binding.binaryMessenger, "com.egov.digit_installer/install_events")
        eventChannel.setStreamHandler(sessionManager)

        signatureVerifier = SignatureVerifier(applicationContext)
        deviceOwnerChecker = DeviceOwnerChecker(applicationContext)
        permissionHelper = InstallPermissionHelper(applicationContext)
    }

    override fun onMethodCall(
        call: MethodCall,
        result: Result,
    ) {
        when (call.method) {
            "getApkSigningCertSha256" -> {
                val path = call.argument<String>("path")
                if (path == null) {
                    result.error("invalid_args", "path is required", null)
                    return
                }
                runCatching { signatureVerifier.getApkSigningCertSha256(path) }
                    .fold(result::success) { e -> result.error("signature_error", e.message, null) }
            }
            "getInstalledSigningCertSha256" -> {
                runCatching { signatureVerifier.getInstalledSigningCertSha256() }
                    .fold(result::success) { e -> result.error("signature_error", e.message, null) }
            }
            "isDeviceOwner" -> result.success(deviceOwnerChecker.isDeviceOwner())
            "checkSilentInstallEligibility" -> {
                val eligibility =
                    when {
                        Build.VERSION.SDK_INT < Build.VERSION_CODES.S -> "unsupported_api_level"
                        !deviceOwnerChecker.isDeviceOwner() -> "not_device_owner"
                        else -> "eligible"
                    }
                result.success(mapOf("eligibility" to eligibility, "sdkInt" to Build.VERSION.SDK_INT))
            }
            "canRequestPackageInstalls" -> result.success(permissionHelper.canRequestPackageInstalls())
            "openInstallUnknownAppsSettings" -> {
                permissionHelper.openInstallUnknownAppsSettings(activity)
                result.success(null)
            }
            "ensureNotificationPermission" -> ensureNotificationPermission(result)
            "createInstallSession" -> {
                val sizeBytes = call.argument<Number>("sizeBytes")?.toLong() ?: -1L
                val silent = call.argument<Boolean>("silent") ?: false
                val reopenAfterInstall = call.argument<Boolean>("reopenAfterInstall") ?: false
                PostInstallRelaunchReceiver.Prefs.writeReopenAfterInstall(applicationContext, reopenAfterInstall)
                runCatching { sessionManager.createSession(sizeBytes, silent) }
                    .fold(result::success) { e -> result.error("session_error", e.message, null) }
            }
            "commitSession" -> {
                val sessionId = call.argument<Int>("sessionId")
                val apkFilePath = call.argument<String>("apkFilePath")
                if (sessionId == null || apkFilePath == null) {
                    result.error("invalid_args", "sessionId and apkFilePath are required", null)
                    return
                }
                runCatching { sessionManager.commitSession(sessionId, apkFilePath) }
                    .fold({ result.success(null) }, { e -> result.error("session_error", e.message, null) })
            }
            "abandonSession" -> {
                val sessionId = call.argument<Int>("sessionId")
                if (sessionId == null) {
                    result.error("invalid_args", "sessionId is required", null)
                    return
                }
                sessionManager.abandonSession(sessionId)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    /**
     * Requests `POST_NOTIFICATIONS` (API 33+ only — the permission didn't
     * exist before, and notifications just needed the user's general
     * per-app toggle) so the "tap to reopen" notification in
     * [PostInstallRelaunchReceiver] can actually show. Best-effort: the
     * install itself proceeds regardless of the result.
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
            // No foreground Activity to attach the system dialog to (e.g.
            // install triggered from a background isolate) — report the
            // current state rather than hanging on an impossible request.
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

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        sessionManager.dispose()
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
        const val NOTIFICATION_PERMISSION_REQUEST_CODE = 4712
    }
}
