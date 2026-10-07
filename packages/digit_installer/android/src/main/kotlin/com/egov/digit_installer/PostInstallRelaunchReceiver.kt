package com.egov.digit_installer

import android.annotation.SuppressLint
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat

/**
 * Installing an update over the running app always kills its process — the
 * OS won't let new code load into a live process — so there is no Dart (or
 * even Kotlin) code left running to relaunch the UI once the install
 * finishes. `ACTION_MY_PACKAGE_REPLACED` is the system's own notification
 * that this app was just updated, delivered to a fresh process; declared
 * statically (not context-registered) for the same reason as
 * [InstallResultReceiver] — nothing is running to register it dynamically
 * by the time it fires.
 *
 * This does *not* call [Context.startActivity] directly: Android blocks
 * apps from starting an Activity from a background context like a
 * broadcast receiver (no crash, the call is just silently dropped by the
 * OS) unless the app is already in the foreground — see
 * https://developer.android.com/guide/components/activities/background-starts.
 * Posting a notification with a [PendingIntent] is the sanctioned
 * equivalent: tapping it counts as direct user interaction, so the launch
 * is allowed.
 *
 * Whether to show it at all is read from [Prefs], written by
 * [InstallSessionManager.createSession] before the install that's about to
 * kill this process even starts.
 */
class PostInstallRelaunchReceiver : BroadcastReceiver() {
    override fun onReceive(
        context: Context,
        intent: Intent,
    ) {
        if (intent.action != Intent.ACTION_MY_PACKAGE_REPLACED) return
        if (!Prefs.readReopenAfterInstall(context)) return

        val launchIntent =
            context.packageManager.getLaunchIntentForPackage(context.packageName)
                ?: return
        launchIntent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)

        showReopenNotification(context, launchIntent)
    }

    // POST_NOTIFICATIONS is checked via areNotificationsEnabled() below,
    // which covers both the API 33+ runtime permission and the pre-33
    // per-app notification toggle — lint can't see that, hence the
    // suppression rather than a redundant checkSelfPermission call.
    @SuppressLint("MissingPermission")
    private fun showReopenNotification(
        context: Context,
        launchIntent: Intent,
    ) {
        val notificationManager = NotificationManagerCompat.from(context)
        if (!notificationManager.areNotificationsEnabled()) return

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            notificationManager.createNotificationChannel(
                NotificationChannel(CHANNEL_ID, "App updates", NotificationManager.IMPORTANCE_DEFAULT),
            )
        }

        val flags =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            } else {
                PendingIntent.FLAG_UPDATE_CURRENT
            }
        val pendingIntent = PendingIntent.getActivity(context, 0, launchIntent, flags)

        val notification =
            NotificationCompat.Builder(context, CHANNEL_ID)
                .setSmallIcon(context.applicationInfo.icon)
                .setContentTitle("Update installed")
                .setContentText("Tap to reopen")
                .setContentIntent(pendingIntent)
                .setAutoCancel(true)
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()

        notificationManager.notify(NOTIFICATION_ID, notification)
    }

    object Prefs {
        private const val FILE_NAME = "digit_installer_prefs"
        private const val KEY_REOPEN_AFTER_INSTALL = "reopen_after_install"

        fun writeReopenAfterInstall(
            context: Context,
            value: Boolean,
        ) {
            context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
                .edit()
                .putBoolean(KEY_REOPEN_AFTER_INSTALL, value)
                .apply()
        }

        fun readReopenAfterInstall(context: Context): Boolean {
            return context.getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
                .getBoolean(KEY_REOPEN_AFTER_INSTALL, false)
        }
    }

    private companion object {
        const val CHANNEL_ID = "digit_installer_reopen"
        const val NOTIFICATION_ID = 4712
    }
}
