package com.egov.digit_installer

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.pm.PackageInstaller
import io.flutter.plugin.common.EventChannel

/**
 * Receives the result of a [PackageInstaller.Session.commit] broadcast.
 *
 * `STATUS_PENDING_USER_ACTION` is handled entirely here: it starts the
 * system confirmation activity itself and returns — it is never forwarded to
 * Dart as a failure. Only the eventual terminal status (success/failure)
 * reaches Dart, via the [EventChannel.EventSink] that [InstallSessionManager]
 * registers here while a Dart listener is attached.
 *
 * Declared as a static receiver in the manifest (see AndroidManifest.xml) so
 * it survives the app backgrounding/dying during the few seconds after the
 * user responds to the confirmation dialog.
 */
class InstallResultReceiver : BroadcastReceiver() {

    companion object {
        var eventSink: EventChannel.EventSink? = null
    }

    @Suppress("DEPRECATION")
    override fun onReceive(context: Context, intent: Intent) {
        val status = intent.getIntExtra(PackageInstaller.EXTRA_STATUS, PackageInstaller.STATUS_FAILURE)
        val sessionId = intent.getIntExtra(PackageInstaller.EXTRA_SESSION_ID, -1)
        val message = intent.getStringExtra(PackageInstaller.EXTRA_STATUS_MESSAGE)

        if (status == PackageInstaller.STATUS_PENDING_USER_ACTION) {
            val confirmIntent = intent.getParcelableExtra<Intent>(Intent.EXTRA_INTENT)
            confirmIntent?.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            confirmIntent?.let { context.startActivity(it) }
            return
        }

        eventSink?.success(
            mapOf(
                "sessionId" to sessionId,
                "kind" to "status",
                "status" to status,
                "message" to message,
            ),
        )
    }
}
