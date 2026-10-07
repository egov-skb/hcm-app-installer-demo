import 'package:flutter_test/flutter_test.dart';
import 'package:digit_installer/digit_installer.dart';

void main() {
  group('UpdateManifest', () {
    test('round-trips through JSON with all fields present', () {
      final manifest = UpdateManifest(
        version: '1.2.0',
        versionCode: 12,
        downloadUrl: Uri.parse('https://example.com/app.apk'),
        sha256: 'abc123',
        signingCertSha256: 'def456',
        size: 1024,
        releaseNotes: 'Bug fixes',
        mandatory: true,
      );

      final decoded = UpdateManifest.fromJson(manifest.toJson());

      expect(decoded.version, manifest.version);
      expect(decoded.versionCode, manifest.versionCode);
      expect(decoded.downloadUrl, manifest.downloadUrl);
      expect(decoded.sha256, manifest.sha256);
      expect(decoded.signingCertSha256, manifest.signingCertSha256);
      expect(decoded.size, manifest.size);
      expect(decoded.releaseNotes, manifest.releaseNotes);
      expect(decoded.mandatory, isTrue);
    });

    test('optional fields are null-safe when absent from JSON', () {
      final manifest = UpdateManifest.fromJson({
        'version': '1.0.0',
        'versionCode': 1,
        'downloadUrl': 'https://example.com/app.apk',
        'sha256': 'abc123',
      });

      expect(manifest.signingCertSha256, isNull);
      expect(manifest.size, isNull);
      expect(manifest.releaseNotes, isNull);
      expect(manifest.mandatory, isFalse);
    });
  });
}
