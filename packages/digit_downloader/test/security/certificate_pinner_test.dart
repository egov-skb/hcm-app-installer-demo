import 'package:flutter_test/flutter_test.dart';
import 'package:digit_downloader/src/models/cert_pin.dart';
import 'package:digit_downloader/src/security/certificate_pinner_io.dart';

void main() {
  group('isPinnedMatch', () {
    const pins = CertificatePinSet([
      CertificatePin(host: 'api.example.com', sha256Pins: {'aaaa', 'bbbb'}),
    ]);

    test('accepts a certificate whose hash matches a configured pin', () {
      expect(
        isPinnedMatch(host: 'api.example.com', certSha256Hex: 'aaaa', pins: pins),
        isTrue,
      );
    });

    test('supports multiple simultaneous pins for rotation', () {
      expect(
        isPinnedMatch(host: 'api.example.com', certSha256Hex: 'bbbb', pins: pins),
        isTrue,
      );
    });

    test('rejects a certificate whose hash matches no configured pin', () {
      expect(
        isPinnedMatch(host: 'api.example.com', certSha256Hex: 'cccc', pins: pins),
        isFalse,
      );
    });

    test('fails closed for a host with no configured pins at all', () {
      expect(
        isPinnedMatch(host: 'unpinned.example.com', certSha256Hex: 'aaaa', pins: pins),
        isFalse,
      );
    });
  });
}
