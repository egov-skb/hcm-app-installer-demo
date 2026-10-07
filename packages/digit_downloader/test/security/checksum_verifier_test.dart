import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:digit_downloader/src/security/checksum_verifier.dart';

void main() {
  group('ChecksumVerifier', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('digit_downloader_checksum_test');
    });

    tearDown(() async {
      if (await tempDir.exists()) await tempDir.delete(recursive: true);
    });

    test('matches crypto.sha256 computed directly over the same bytes', () async {
      final bytes = utf8.encode('hello digit_downloader' * 1000);
      final file = File('${tempDir.path}/data.bin');
      await file.writeAsBytes(bytes);

      final actual = await ChecksumVerifier.sha256OfFile(file);
      final expected = sha256.convert(bytes).toString();

      expect(actual, expected);
    });

    test('reads the file in chunks rather than loading it whole', () async {
      // Not directly observable from the public API, but a large file should
      // still hash correctly, which would fail if chunking corrupted offsets.
      final bytes = List<int>.generate(5 * 1024 * 1024, (i) => i % 256);
      final file = File('${tempDir.path}/large.bin');
      await file.writeAsBytes(bytes);

      final actual = await ChecksumVerifier.sha256OfFile(file);
      final expected = sha256.convert(bytes).toString();

      expect(actual, expected);
    });
  });
}
