import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/io_client.dart';

import '../models/cert_pin.dart';

/// The pure pin-matching decision, factored out of [createPinnedClient] so it
/// can be unit-tested without a real TLS handshake (`X509Certificate` has no
/// public constructor). A host with no configured pins fails closed rather
/// than falling back to default trust.
bool isPinnedMatch({
  required String host,
  required String certSha256Hex,
  required CertificatePinSet pins,
}) {
  final expected = pins.forHost(host);
  if (expected == null || expected.isEmpty) return false;
  return expected.contains(certSha256Hex);
}

/// Builds an [http.Client] that enforces TLS certificate pinning.
///
/// `HttpClient.badCertificateCallback` alone only fires when the *default*
/// trust evaluation fails — a validly CA-trusted-but-compromised certificate
/// would never reach it, defeating the point of pinning. Instead, trust
/// nothing by default (`SecurityContext(withTrustedRoots: false)`) so the
/// callback always fires, then manually compare the presented certificate's
/// SHA-256 (over the full DER — Dart doesn't expose SPKI extraction without a
/// hand-rolled ASN.1 parser) against the configured pin set.
http.Client createPinnedClient(CertificatePinSet? pins) {
  if (pins == null || pins.pins.isEmpty) {
    return http.Client();
  }

  final context = SecurityContext(withTrustedRoots: false);
  final inner = HttpClient(context: context);
  inner.badCertificateCallback = (X509Certificate cert, String host, int port) {
    final actual = sha256.convert(cert.der).toString();
    return isPinnedMatch(host: host, certSha256Hex: actual, pins: pins);
  };
  return IOClient(inner);
}
