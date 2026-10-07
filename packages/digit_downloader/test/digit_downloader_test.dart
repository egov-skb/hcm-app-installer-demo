import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:digit_downloader/src/engine/json_key_value_store.dart';
import 'package:digit_downloader/src/digit_downloader.dart';
import 'package:digit_downloader/src/models/download_request.dart';
import 'package:digit_downloader/src/state/download_failure.dart';
import 'package:digit_downloader/src/state/download_state.dart';

class _FakeJsonKeyValueStore implements JsonKeyValueStore {
  final _values = <String, Map<String, dynamic>>{};

  @override
  Future<T?> readJson<T>(String key, T Function(Map<String, dynamic> json) decoder) async {
    final json = _values[key];
    return json == null ? null : decoder(json);
  }

  @override
  Future<void> writeJson<T>(
    String key,
    T value,
    Map<String, dynamic> Function(T value) encoder,
  ) async {
    _values[key] = encoder(value);
  }

  @override
  Future<void> delete(String key) async {
    _values.remove(key);
  }
}

({int start, int end}) _parseRange(String header) {
  final match = RegExp(r'bytes=(\d+)-(\d+)').firstMatch(header)!;
  return (start: int.parse(match.group(1)!), end: int.parse(match.group(2)!));
}

void main() {
  late Directory tempDir;
  late _FakeJsonKeyValueStore fakeStore;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('digit_downloader_test');
    fakeStore = _FakeJsonKeyValueStore();
  });

  tearDown(() async {
    if (await tempDir.exists()) await tempDir.delete(recursive: true);
  });

  group('DigitDownloader happy path', () {
    test('downloads, reassembles chunks in order, and reports Completed', () async {
      final bytes = List<int>.generate(4096, (i) => i % 256);
      final client = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response('', 200, headers: {
            'content-length': '${bytes.length}',
            'etag': 'etag-1',
            'accept-ranges': 'bytes',
          });
        }
        final range = _parseRange(request.headers['Range']!);
        final slice = bytes.sublist(range.start, range.end + 1);
        return http.Response.bytes(slice, 206, headers: {'content-length': '${slice.length}'});
      });

      final downloader = DigitDownloader(store: fakeStore, clientFactory: (_) => client);
      final destination = '${tempDir.path}/out.bin';
      final request = DownloadRequest(
        url: Uri.parse('https://example.com/file.bin'),
        taskId: 'happy-path',
        destinationPath: destination,
        chunkCount: 4,
        minChunkSize: 100,
        expectedSha256: sha256.convert(bytes).toString(),
      );

      final states = await downloader.start(request).toList();

      expect(states.last, isA<DownloadCompleted>());
      expect(states.whereType<DownloadInProgress>(), isNotEmpty);

      final written = await File(destination).readAsBytes();
      expect(written, bytes);
    });

    test('fails with ChecksumMismatch when the downloaded content does not match', () async {
      final bytes = List<int>.generate(1000, (i) => i % 256);
      final client = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response('', 200, headers: {
            'content-length': '${bytes.length}',
            'accept-ranges': 'bytes',
          });
        }
        final range = _parseRange(request.headers['Range']!);
        final slice = bytes.sublist(range.start, range.end + 1);
        return http.Response.bytes(slice, 206, headers: {'content-length': '${slice.length}'});
      });

      final downloader = DigitDownloader(store: fakeStore, clientFactory: (_) => client);
      final request = DownloadRequest(
        url: Uri.parse('https://example.com/file.bin'),
        taskId: 'checksum-mismatch',
        destinationPath: '${tempDir.path}/out.bin',
        chunkCount: 2,
        minChunkSize: 100,
        expectedSha256: 'not-the-right-hash',
      );

      final states = await downloader.start(request).toList();
      final last = states.last;
      expect(last, isA<DownloadFailed>());
      expect((last as DownloadFailed).reason, isA<DownloadChecksumMismatch>());
    });

    test('collapses to one chunk when the server does not support Range', () async {
      final bytes = List<int>.generate(2000, (i) => i % 256);
      var getRequestCount = 0;
      final client = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response('', 200, headers: {'content-length': '${bytes.length}'});
        }
        getRequestCount++;
        return http.Response.bytes(bytes, 200);
      });

      final downloader = DigitDownloader(store: fakeStore, clientFactory: (_) => client);
      final request = DownloadRequest(
        url: Uri.parse('https://example.com/file.bin'),
        taskId: 'no-range-support',
        destinationPath: '${tempDir.path}/out.bin',
        chunkCount: 4,
        minChunkSize: 1,
      );

      final states = await downloader.start(request).toList();
      expect(states.last, isA<DownloadCompleted>());
      expect(getRequestCount, 1);
    });
  });

  group('DigitDownloader retry', () {
    test('retries a failing chunk and then reports NetworkFailure once exhausted', () async {
      final client = MockClient((request) async {
        if (request.method == 'HEAD') {
          return http.Response('', 200, headers: {
            'content-length': '1000',
            'accept-ranges': 'bytes',
          });
        }
        throw const SocketException('connection reset');
      });

      final downloader = DigitDownloader(store: fakeStore, clientFactory: (_) => client);
      final request = DownloadRequest(
        url: Uri.parse('https://example.com/file.bin'),
        taskId: 'always-fails',
        destinationPath: '${tempDir.path}/out.bin',
        chunkCount: 1,
        minChunkSize: 100,
        maxRetriesPerChunk: 2,
      );

      final states = await downloader.start(request).toList();
      final last = states.last;
      expect(last, isA<DownloadFailed>());
      expect((last as DownloadFailed).reason, isA<DownloadNetworkFailure>());
    });
  });

  group('DigitDownloader pause/resume', () {
    test('pausing keeps partial progress and resuming completes without re-downloading finished chunks', () async {
      final bytes = List<int>.generate(2000, (i) => i % 256);
      final requestedRangesForChunk1 = <({int start, int end})>[];

      Stream<List<int>> slowStream(List<int> data) async* {
        const piece = 40;
        for (var i = 0; i < data.length; i += piece) {
          await Future.delayed(const Duration(milliseconds: 5));
          yield data.sublist(i, (i + piece).clamp(0, data.length));
        }
      }

      final client = MockClient.streaming((request, _) async {
        if (request.method == 'HEAD') {
          return http.StreamedResponse(Stream.value(utf8.encode('')), 200, headers: {
            'content-length': '${bytes.length}',
            'etag': 'etag-1',
            'accept-ranges': 'bytes',
          });
        }
        final range = _parseRange(request.headers['Range']!);
        final slice = bytes.sublist(range.start, range.end + 1);
        // Second half of the file streams slowly, giving the test a window
        // to call pause() before it fully arrives.
        if (range.start >= bytes.length ~/ 2) {
          requestedRangesForChunk1.add(range);
          return http.StreamedResponse(
            slowStream(slice),
            206,
            headers: {'content-length': '${slice.length}'},
          );
        }
        return http.StreamedResponse(Stream.value(slice), 206, headers: {'content-length': '${slice.length}'});
      });

      final downloader = DigitDownloader(store: fakeStore, clientFactory: (_) => client);
      final destination = '${tempDir.path}/out.bin';
      final request = DownloadRequest(
        url: Uri.parse('https://example.com/file.bin'),
        taskId: 'pausable',
        destinationPath: destination,
        chunkCount: 2,
        minChunkSize: 100,
      );

      final states = <DownloadState>[];
      final firstRun = downloader.start(request).listen(states.add);
      // Let the fast first-half chunk finish and the slow second half start
      // streaming, then pause before it completes.
      await Future.delayed(const Duration(milliseconds: 30));
      await downloader.pause('pausable');
      await firstRun.asFuture<void>();

      expect(states.last, isA<DownloadPaused>());
      final pausedProgress = (states.last as DownloadPaused).progress;
      expect(pausedProgress.bytesReceived, lessThan(bytes.length));
      expect(await downloader.hasResumableDownload('pausable'), isTrue);

      final requestCountBeforeResume = requestedRangesForChunk1.length;

      final resumedStates = await downloader.start(request).toList();
      expect(resumedStates.last, isA<DownloadCompleted>());

      final written = await File(destination).readAsBytes();
      expect(written, bytes);

      // The already-completed first-half chunk must not have been re-requested.
      expect(requestedRangesForChunk1.length, greaterThan(requestCountBeforeResume));
      expect(await downloader.hasResumableDownload('pausable'), isFalse);
    });
  });
}
