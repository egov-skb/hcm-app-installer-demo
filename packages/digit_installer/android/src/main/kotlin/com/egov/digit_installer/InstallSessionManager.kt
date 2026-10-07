package com.egov.digit_installer

import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.EventChannel
import java.io.File
import java.io.FileInputStream
import java.io.OutputStream

/**
 * Wraps the [PackageInstaller] Session API: real-time install progress via
 * [PackageInstaller.SessionCallback], and structured success/failure via
 * [InstallResultReceiver] rather than firing an [Intent] into a black box
 * (the legacy `ACTION_VIEW` approach). No FileProvider/content URI is
 * needed — the session's own [PackageInstaller.Session.openWrite] stream is
 * written to directly.
 */
class InstallSessionManager(private val context: Context) : EventChannel.StreamHandler {

    private val packageInstaller = context.packageManager.packageInstaller
    private var sessionCallback: PackageInstaller.SessionCallback? = null

    // commitSession() now runs on the plugin's background TaskQueue thread
    // (not the main thread), but EventChannel.EventSink calls are expected
    // on the main thread — same as the existing onProgressChanged callback
    // and InstallResultReceiver, both of which already fire there. Routing
    // every emission through this Handler keeps that invariant regardless
    // of which thread triggered it.
    private val mainHandler = Handler(Looper.getMainLooper())

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        val callback =
            object : PackageInstaller.SessionCallback() {
                override fun onCreated(sessionId: Int) = Unit

                override fun onBadgingChanged(sessionId: Int) = Unit

                override fun onActiveChanged(
                    sessionId: Int,
                    active: Boolean,
                ) = Unit

                override fun onProgressChanged(
                    sessionId: Int,
                    progress: Float,
                ) {
                    // This phase (verification + apply, post-commit) picks
                    // up where the copy phase in commitSession() left off,
                    // so it's rescaled into the remaining share instead of
                    // restarting the progress bar from zero.
                    postProgress(sessionId, COPY_PHASE_WEIGHT + (1f - COPY_PHASE_WEIGHT) * progress)
                }

                override fun onFinished(
                    sessionId: Int,
                    success: Boolean,
                ) = Unit
            }
        sessionCallback = callback
        packageInstaller.registerSessionCallback(callback)
        InstallResultReceiver.eventSink = events
    }

    private fun postProgress(
        sessionId: Int,
        fraction: Float,
    ) {
        mainHandler.post {
            InstallResultReceiver.eventSink?.success(
                mapOf(
                    "sessionId" to sessionId,
                    "kind" to "progress",
                    "progress" to fraction,
                ),
            )
        }
    }

    override fun onCancel(arguments: Any?) {
        sessionCallback?.let { packageInstaller.unregisterSessionCallback(it) }
        sessionCallback = null
        InstallResultReceiver.eventSink = null
    }

    /**
     * [silent] only takes effect on API 31+ and is meaningless unless the
     * caller has already confirmed Device Owner status — this class doesn't
     * re-check that itself, callers must gate it (see [DeviceOwnerChecker]).
     */
    fun createSession(
        sizeBytes: Long,
        silent: Boolean,
    ): Int {
        val params = PackageInstaller.SessionParams(PackageInstaller.SessionParams.MODE_FULL_INSTALL)
        if (sizeBytes > 0) params.setSize(sizeBytes)
        if (silent && Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            params.setRequireUserAction(PackageInstaller.SessionParams.USER_ACTION_NOT_REQUIRED)
        }
        return packageInstaller.createSession(params)
    }

    fun commitSession(
        sessionId: Int,
        apkFilePath: String,
    ) {
        val file = File(apkFilePath)
        val totalBytes = file.length()
        packageInstaller.openSession(sessionId).use { session ->
            session.openWrite("digit_installer_$sessionId", 0, totalBytes).use { out ->
                copyWithProgress(file, out, sessionId, totalBytes)
                session.fsync(out)
            }

            val intent = Intent(context, InstallResultReceiver::class.java)
            val flags =
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_MUTABLE
                } else {
                    PendingIntent.FLAG_UPDATE_CURRENT
                }
            val pendingIntent = PendingIntent.getBroadcast(context, sessionId, intent, flags)
            session.commit(pendingIntent.intentSender)
        }
    }

    /**
     * Copies [file] into [out] in chunks (rather than one blocking
     * [FileInputStream.copyTo] call) so progress can be reported along the
     * way — this alone can take a while for a 100+ MB APK. Reported into
     * the first [COPY_PHASE_WEIGHT] share of the overall progress range;
     * see [onProgressChanged] for the remaining share.
     */
    private fun copyWithProgress(
        file: File,
        out: OutputStream,
        sessionId: Int,
        totalBytes: Long,
    ) {
        FileInputStream(file).use { input ->
            if (totalBytes <= 0) {
                input.copyTo(out)
                return
            }
            val buffer = ByteArray(COPY_BUFFER_SIZE)
            val reportThreshold = (totalBytes / 100).coerceAtLeast(COPY_BUFFER_SIZE.toLong())
            var copiedBytes = 0L
            var lastReportedBytes = 0L
            while (true) {
                val read = input.read(buffer)
                if (read == -1) break
                out.write(buffer, 0, read)
                copiedBytes += read
                if (copiedBytes - lastReportedBytes >= reportThreshold) {
                    lastReportedBytes = copiedBytes
                    postProgress(sessionId, COPY_PHASE_WEIGHT * (copiedBytes.toFloat() / totalBytes))
                }
            }
        }
        postProgress(sessionId, COPY_PHASE_WEIGHT)
    }

    fun abandonSession(sessionId: Int) {
        try {
            packageInstaller.openSession(sessionId).abandon()
        } catch (_: Exception) {
            // Session already gone (committed/abandoned) — nothing else to do.
        }
    }

    fun dispose() {
        sessionCallback?.let { packageInstaller.unregisterSessionCallback(it) }
        sessionCallback = null
    }

    private companion object {
        const val COPY_BUFFER_SIZE = 64 * 1024

        /**
         * Share of the overall [0, 1] progress range spent copying the APK
         * into the session, before [PackageInstaller.Session.commit]'s own
         * verification/apply progress (the remaining share) begins.
         */
        const val COPY_PHASE_WEIGHT = 0.5f
    }
}
