package com.egov.digit_installer

import android.app.admin.DevicePolicyManager
import android.content.Context

/**
 * Fully silent installs (no system confirmation dialog) are only possible
 * for apps enrolled as a Device Owner (MDM/kiosk). This must be checked
 * before ever attempting [PackageInstaller.SessionParams.setRequireUserAction]
 * with `USER_ACTION_NOT_REQUIRED` — regular apps must never blindly attempt
 * the silent path.
 */
class DeviceOwnerChecker(private val context: Context) {
    fun isDeviceOwner(): Boolean {
        val dpm =
            context.getSystemService(Context.DEVICE_POLICY_SERVICE) as? DevicePolicyManager
                ?: return false
        return dpm.isDeviceOwnerApp(context.packageName)
    }
}
