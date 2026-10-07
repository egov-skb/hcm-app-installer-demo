package com.egov.digit_installer

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings

/**
 * On API 26+, installing from an unknown source is granted per-app rather
 * than via a single global toggle; this surfaces that state and a deep link
 * to the settings screen so the host app can prompt the user distinctly from
 * a generic error, rather than a cryptic install failure.
 */
class InstallPermissionHelper(private val context: Context) {

    fun canRequestPackageInstalls(): Boolean {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            context.packageManager.canRequestPackageInstalls()
        } else {
            // Pre-O: governed by a single global "Unknown sources" toggle, not per-app.
            true
        }
    }

    fun openInstallUnknownAppsSettings(activity: Activity?) {
        val host: Context = activity ?: context
        val intent =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES).apply {
                    data = Uri.parse("package:${context.packageName}")
                }
            } else {
                Intent(Settings.ACTION_SECURITY_SETTINGS)
            }
        if (activity == null) {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }
        host.startActivity(intent)
    }
}
