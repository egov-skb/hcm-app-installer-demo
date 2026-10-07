import 'dart:io';

import 'package:crypto/crypto.dart';

/// Streaming SHA-256 verification — never loads the whole file into memory.
abstract final class ChecksumVerifier {
  static Future<String> sha256OfFile(File file) async {
    final output = _DigestSink();
    final input = sha256.startChunkedConversion(output);
    await for (final chunk in file.openRead()) {
      input.add(chunk);
    }
    input.close();
    return output.value.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get value => _digest!;

  @override
  void add(Digest data) => _digest = data;

  @override
  void close() {}
}
