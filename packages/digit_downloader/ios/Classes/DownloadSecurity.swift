// UNVERIFIED — written without access to Xcode/macOS to compile or run
// this. See the package README before relying on it; build and debug on
// a real Mac/device before shipping.

import CryptoKit
import Foundation

/// Streaming SHA-256 — mirrors `ChecksumVerifier.sha256OfFile` (Dart) and
/// `ChecksumUtil.sha256OfFile` (Android).
enum ChecksumUtil {
    static func sha256OfFile(at url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        var hasher = SHA256()
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// TLS certificate pinning, matching `isPinnedMatch`/`createPinnedClient` in
/// the Dart engine and `PinningTrustManager` in the Android engine: pins are
/// checked against the SHA-256 of the full leaf certificate DER, and a host
/// with no configured pin fails closed (no fallback to normal system trust)
/// — pinning that quietly no-ops for unlisted hosts would defeat the point.
enum CertificatePinning {
    /// Call from `URLSessionDelegate.urlSession(_:didReceive:completionHandler:)`.
    /// `pinsByHost` empty means pinning isn't configured for this download at
    /// all — falls back to normal system trust evaluation.
    static func evaluate(
        challenge: URLAuthenticationChallenge,
        pinsByHost: [String: Set<String>]
    ) -> (URLSession.AuthChallengeDisposition, URLCredential?) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
            let serverTrust = challenge.protectionSpace.serverTrust
        else {
            return (.performDefaultHandling, nil)
        }

        if pinsByHost.isEmpty {
            return (.performDefaultHandling, nil)
        }

        let host = challenge.protectionSpace.host
        guard let expected = pinsByHost[host], !expected.isEmpty else {
            // Pinning is configured for this download but not for this
            // specific host — fail closed rather than silently trusting it.
            return (.cancelAuthenticationChallenge, nil)
        }

        guard let chain = SecTrustCopyCertificateChain(serverTrust) as? [SecCertificate],
            let leaf = chain.first
        else {
            return (.cancelAuthenticationChallenge, nil)
        }

        let der = SecCertificateCopyData(leaf) as Data
        let actual = SHA256.hash(data: der).map { String(format: "%02x", $0) }.joined()

        if expected.contains(actual) {
            return (.useCredential, URLCredential(trust: serverTrust))
        }
        return (.cancelAuthenticationChallenge, nil)
    }
}
