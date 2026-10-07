import 'package:flutter_test/flutter_test.dart';
import 'package:digit_downloader/digit_downloader.dart';

void main() {
  test('public API is exported from the barrel file', () {
    expect(const DownloadIdle(), isA<DownloadState>());
    expect(const CertificatePinSet([]), isA<CertificatePinSet>());
  });
}
