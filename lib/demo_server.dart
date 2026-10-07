/// Local dev-server fallback used when `githubReleaseHost` in
/// `update_config.dart` is left blank. Serves the bundled placeholder
/// update artifact (`assets/demo/sample-update.bin`) plus a matching
/// manifest.json, so the full check → download → checksum-verify pipeline
/// can be exercised on any platform without a real backend.
///
/// Not a real APK — the install step only makes sense against a real
/// release (see the README's "Publishing a real demo release" section).
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:shelf_router/shelf_router.dart';

class DemoUpdateServer {
  DemoUpdateServer({this.versionCode = 2, this.version = '1.1.0-demo'});

  final int versionCode;
  final String version;

  HttpServer? _server;
  Uri? _boundUri;

  Uri get manifestUrl => _requireBound().replace(path: '/manifest.json');

  Uri _requireBound() {
    final uri = _boundUri;
    if (uri == null) throw StateError('DemoUpdateServer.start() has not completed yet');
    return uri;
  }

  Future<Uri> start() async {
    final assetBytes = (await rootBundle.load('assets/demo/sample-update.bin')).buffer.asUint8List();
    final sha256Hex = sha256.convert(assetBytes).toString();

    final router = Router()
      ..get(
        '/sample-update.bin',
        (Request request) => Response.ok(assetBytes, headers: {'content-type': 'application/octet-stream'}),
      )
      ..get('/manifest.json', (Request request) {
        final body = jsonEncode({
          'version': version,
          'versionCode': versionCode,
          'downloadUrl': _requireBound().replace(path: '/sample-update.bin').toString(),
          'sha256': sha256Hex,
          'size': assetBytes.length,
          'releaseNotes': 'Local demo server placeholder release',
          'mandatory': false,
        });
        return Response.ok(body, headers: {'content-type': 'application/json'});
      });

    final server = await shelf_io.serve(router.call, InternetAddress.loopbackIPv4, 0);
    _server = server;
    _boundUri = Uri(scheme: 'http', host: server.address.address, port: server.port);
    return _boundUri!;
  }

  Future<void> stop() async {
    await _server?.close(force: true);
    _server = null;
    _boundUri = null;
  }
}
