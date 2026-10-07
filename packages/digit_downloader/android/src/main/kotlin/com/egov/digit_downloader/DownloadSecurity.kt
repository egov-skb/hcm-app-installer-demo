package com.egov.digit_downloader

import java.io.File
import java.io.FileInputStream
import java.security.MessageDigest
import java.security.SecureRandom
import java.security.cert.CertificateException
import java.security.cert.X509Certificate
import javax.net.ssl.HttpsURLConnection
import javax.net.ssl.SSLContext
import javax.net.ssl.SSLSocketFactory
import javax.net.ssl.X509TrustManager

/** Streaming SHA-256 — mirrors `ChecksumVerifier.sha256OfFile` in the Dart engine. */
object ChecksumUtil {
    fun sha256OfFile(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        FileInputStream(file).use { input ->
            val buffer = ByteArray(64 * 1024)
            while (true) {
                val read = input.read(buffer)
                if (read == -1) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}

/**
 * TLS certificate pinning, matching `createPinnedClient`/`isPinnedMatch` in
 * the Dart engine's `certificate_pinner_io.dart`: pins are checked against
 * the SHA-256 of the full leaf certificate DER, and a host with no
 * configured pin fails closed (no fallback to normal CA trust) rather than
 * silently accepting it — pinning that quietly no-ops for unlisted hosts
 * would defeat the point.
 */
class PinningTrustManager(
    private val host: String,
    private val pinsByHost: Map<String, Set<String>>,
) : X509TrustManager {
    override fun checkClientTrusted(
        chain: Array<out X509Certificate>?,
        authType: String?,
    ) = throw CertificateException("Client certificates are not supported")

    override fun checkServerTrusted(
        chain: Array<out X509Certificate>?,
        authType: String?,
    ) {
        val leaf = chain?.firstOrNull() ?: throw CertificateException("No certificate presented by $host")
        val expected = pinsByHost[host]
        if (expected.isNullOrEmpty()) {
            throw CertificateException("No certificate pin configured for $host")
        }
        val digest = MessageDigest.getInstance("SHA-256")
        val actual = digest.digest(leaf.encoded).joinToString("") { "%02x".format(it) }
        if (actual !in expected) {
            throw CertificateException("Certificate for $host did not match any pinned SHA-256")
        }
    }

    override fun getAcceptedIssuers(): Array<X509Certificate> = emptyArray()

    companion object {
        /**
         * `null` when [pinsByHost] is empty (no pinning configured for this
         * download) or doesn't cover [host] with an entry — in that case
         * the caller should use the platform's normal default trust rather
         * than calling this at all.
         */
        fun socketFactoryFor(
            host: String,
            pinsByHost: Map<String, Set<String>>,
        ): SSLSocketFactory? {
            if (pinsByHost.isEmpty()) return null
            val context = SSLContext.getInstance("TLS")
            context.init(null, arrayOf(PinningTrustManager(host, pinsByHost)), SecureRandom())
            return context.socketFactory
        }

        /** Applies pinning to [connection] in place, if [pinsByHost] covers its host. */
        fun applyIfConfigured(
            connection: HttpsURLConnection,
            pinsByHost: Map<String, Set<String>>,
        ) {
            val factory = socketFactoryFor(connection.url.host, pinsByHost) ?: return
            connection.sslSocketFactory = factory
        }
    }
}
