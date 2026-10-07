package com.egov.digit_installer

import android.content.Context
import android.content.pm.PackageInfo
import android.content.pm.PackageManager
import android.os.Build
import java.security.MessageDigest

/**
 * Extracts an APK's signing-certificate SHA-256 via [PackageManager] —
 * verifying APK v2/v3 signatures requires OS-level ZIP/certificate parsing
 * that isn't feasible in pure Dart, so this is delegated to the platform.
 */
@Suppress("DEPRECATION")
class SignatureVerifier(private val context: Context) {

    fun getApkSigningCertSha256(apkFilePath: String): String? {
        val info = context.packageManager.getPackageArchiveInfo(apkFilePath, signingCertFlags())
            ?: return null
        return extractSigningCertSha256(info)
    }

    fun getInstalledSigningCertSha256(): String? {
        val info = context.packageManager.getPackageInfo(context.packageName, signingCertFlags())
        return extractSigningCertSha256(info)
    }

    private fun signingCertFlags(): Int {
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            PackageManager.GET_SIGNING_CERTIFICATES
        } else {
            PackageManager.GET_SIGNATURES
        }
    }

    private fun extractSigningCertSha256(info: PackageInfo): String? {
        val signature =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val signingInfo = info.signingInfo ?: return null
                val signers =
                    if (signingInfo.hasMultipleSigners()) {
                        signingInfo.apkContentsSigners
                    } else {
                        signingInfo.signingCertificateHistory
                    }
                signers?.firstOrNull()
            } else {
                info.signatures?.firstOrNull()
            } ?: return null

        val digest = MessageDigest.getInstance("SHA-256").digest(signature.toByteArray())
        return digest.joinToString("") { "%02x".format(it) }
    }
}
