/// A set of pinned SHA-256 certificate hashes for a single host.
///
/// Multiple pins per host are supported so a certificate can be rotated
/// without breaking clients that only trust the old pin mid-rollout: add the
/// new pin ahead of time, keep the old one until the rotation is complete.
class CertificatePin {
  const CertificatePin({required this.host, required this.sha256Pins});

  /// The hostname this pin applies to (e.g. `api.example.com`).
  final String host;

  /// Hex-encoded SHA-256 digests of the full certificate DER. Any one match
  /// is accepted.
  final Set<String> sha256Pins;
}

/// A collection of [CertificatePin]s, one per host, used to enable TLS
/// certificate pinning for a download.
class CertificatePinSet {
  const CertificatePinSet(this.pins);

  final List<CertificatePin> pins;

  /// Returns the pinned hashes for [host], or `null` if the host has no
  /// configured pin.
  Set<String>? forHost(String host) {
    for (final pin in pins) {
      if (pin.host == host) return pin.sha256Pins;
    }
    return null;
  }
}
