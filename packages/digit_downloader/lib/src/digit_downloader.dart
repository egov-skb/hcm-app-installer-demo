import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:http/http.dart' as http;
import 'package:just_storage/just_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'downloader.dart';
import 'engine/chunk_planner.dart';
import 'engine/chunk_worker.dart';
import 'engine/download_snapshot.dart';
import 'engine/json_key_value_store.dart';
import 'engine/just_storage_adapter.dart';
import 'engine/native_background_bridge.dart';
import 'engine/resumable_download_store.dart';
import 'models/background_download_mode.dart';
import 'models/byte_range.dart';
import 'models/cert_pin.dart';
import 'models/download_request.dart';
import 'security/certificate_pinner.dart';
import 'security/checksum_verifier.dart';
import 'state/download_failure.dart';
import 'state/download_progress.dart';
import 'state/download_state.dart';

/// Generic background resumable/chunked HTTP downloader.
///
/// One [DigitDownloader] instance can drive any number of concurrent
/// downloads, keyed by [DownloadRequest.taskId]. There is no separate
/// "resume" method: calling [start] again with the same `taskId` resumes
/// automatically whenever matching resume state exists on disk.
class DigitDownloader implements Downloader {
  DigitDownloader({JsonKeyValueStore? store, http.Client Function(CertificatePinSet?)? clientFactory})
    : _injectedStore = store,
      _clientFactory = clientFactory ?? createPinnedClient;

  final JsonKeyValueStore? _injectedStore;
  final http.Client Function(CertificatePinSet?) _clientFactory;
  JsonKeyValueStore? _resolvedStore;

  final _pauseFlags = <String, bool>{};
  final _cancelFlags = <String, bool>{};

  // Tracks which engine each active taskId actually resolved to — not just
  // what was requested — so pause/cancel (which only take a taskId, not
  // the original request) route correctly even when systemManaged silently
  // fell back to appLifecycle (unsupported platform).
  final _usingNativeEngine = <String, bool>{};
  final _nativeBridge = NativeBackgroundBridge();

  static bool get _nativeEngineAvailable =>
      !kIsWeb && (defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS);

  Future<JsonKeyValueStore> _store() async {
    final injected = _injectedStore;
    if (injected != null) return injected;
    if (_resolvedStore != null) return _resolvedStore!;
    final storage = await JustStorage.standard();
    return _resolvedStore = JustStorageAdapter(storage);
  }

  @override
  Stream<DownloadState> start(DownloadRequest request) {
    final useNative = request.backgroundMode == BackgroundDownloadMode.systemManaged && _nativeEngineAvailable;
    _usingNativeEngine[request.taskId] = useNative;

    if (useNative) {
      return _nativeBridge.start(request);
    }

    final controller = StreamController<DownloadState>();
    _pauseFlags[request.taskId] = false;
    _cancelFlags[request.taskId] = false;
    unawaited(_run(request, controller));
    return controller.stream;
  }

  /// Cancels in-flight chunk fetches and keeps the persisted offsets so a
  /// future [start] call with the same `taskId` continues from here.
  @override
  Future<void> pause(String taskId) async {
    if (_usingNativeEngine[taskId] == true) {
      await _nativeBridge.pause(taskId);
      return;
    }
    _pauseFlags[taskId] = true;
  }

  /// Cancels in-flight chunk fetches and discards both the partial file and
  /// the resume metadata.
  @override
  Future<void> cancel(String taskId) async {
    if (_usingNativeEngine[taskId] == true) {
      await _nativeBridge.cancel(taskId);
      return;
    }
    _cancelFlags[taskId] = true;
  }

  @override
  Future<bool> hasResumableDownload(String taskId) async {
    final snapshot = await ResumableDownloadStore(await _store()).read(taskId);
    if (snapshot != null) return true;

    // Not tracked by this Dart-side store — might still be a native
    // background download left over from a previous process (e.g. the app
    // was killed and relaunched), so ask the native side too. Any failure
    // to reach it (unsupported platform, no plugin registered, no binding
    // in a plain `test()` environment) just means "not resumable via
    // native", not an error worth surfacing.
    try {
      return await _nativeBridge.hasResumableDownload(taskId);
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> isComplete(DownloadRequest request) async {
    final expectedSha256 = request.expectedSha256;
    if (expectedSha256 == null) return false;
    final destinationPath = request.destinationPath ?? await _defaultDestinationPath(request.taskId);
    final file = File(destinationPath);
    if (!await file.exists()) return false;
    return await ChecksumVerifier.sha256OfFile(file) == expectedSha256;
  }

  Future<void> _run(DownloadRequest request, StreamController<DownloadState> controller) async {
    controller.add(const DownloadStarting());
    final client = _clientFactory(request.certificatePins);
    final store = ResumableDownloadStore(await _store());

    try {
      final headers = await request.headersBuilder?.call() ?? <String, String>{};
      final headResponse = await client.send(http.Request('HEAD', request.url)..headers.addAll(headers));
      final totalBytes = int.tryParse(headResponse.headers['content-length'] ?? '') ?? 0;
      final etag = headResponse.headers['etag'];
      final acceptsRanges = headResponse.headers['accept-ranges'] == 'bytes';

      final destinationPath = request.destinationPath ?? await _defaultDestinationPath(request.taskId);
      final file = File(destinationPath);
      await file.parent.create(recursive: true);

      // A prior [start] for this exact request may have already completed
      // (e.g. downloaded but never installed/consumed) and left a valid
      // file sitting at this destination. Skip straight to completion
      // rather than re-fetching every byte over the network again.
      if (request.expectedSha256 != null && await file.exists() && await file.length() == totalBytes) {
        final actual = await ChecksumVerifier.sha256OfFile(file);
        if (actual == request.expectedSha256) {
          await store.delete(request.taskId);
          controller.add(DownloadCompleted(file.path));
          return;
        }
      }

      var snapshot = await store.read(request.taskId);
      final canResume = snapshot != null &&
          snapshot.totalBytes == totalBytes &&
          snapshot.etag == etag &&
          await file.exists() &&
          await file.length() == totalBytes;

      List<ByteRange> ranges;
      List<int> receivedPerChunk;
      if (canResume) {
        ranges = snapshot.ranges;
        receivedPerChunk = List.of(snapshot.chunkReceivedBytes);
      } else {
        final effectiveChunkCount = acceptsRanges ? request.chunkCount : 1;
        ranges = ChunkPlanner.plan(
          totalBytes: totalBytes,
          chunkCount: effectiveChunkCount,
          minChunkSize: request.minChunkSize,
        );
        receivedPerChunk = List.filled(ranges.length, 0);
        final raf = await file.open(mode: FileMode.write);
        await raf.truncate(totalBytes);
        await raf.close();
        snapshot = DownloadSnapshot(
          taskId: request.taskId,
          totalBytes: totalBytes,
          etag: etag,
          ranges: ranges,
          chunkReceivedBytes: receivedPerChunk,
        );
        await store.write(snapshot);
      }

      var lastPersist = DateTime.now();
      void reportProgress() {
        final received = receivedPerChunk.fold<int>(0, (a, b) => a + b);
        final completed = [
          for (var i = 0; i < ranges.length; i++)
            if (receivedPerChunk[i] >= ranges[i].length) 1,
        ].length;
        controller.add(
          DownloadInProgress(
            DownloadProgress(
              bytesReceived: received,
              totalBytes: totalBytes,
              bytesPerSecond: 0,
              chunksTotal: ranges.length,
              chunksCompleted: completed,
            ),
          ),
        );
        final now = DateTime.now();
        if (now.difference(lastPersist).inMilliseconds > 250) {
          lastPersist = now;
          unawaited(store.write(snapshot!.copyWith(chunkReceivedBytes: receivedPerChunk)));
        }
      }

      final openFiles = <RandomAccessFile>[];
      final futures = <Future<void>>[];
      for (var i = 0; i < ranges.length; i++) {
        final workerFile = await file.open(mode: FileMode.append);
        openFiles.add(workerFile);
        final worker = ChunkWorker(
          client: client,
          url: request.url,
          range: ranges[i],
          file: workerFile,
          headersBuilder: request.headersBuilder,
          maxRetries: request.maxRetriesPerChunk,
          onBytes: (delta) {
            receivedPerChunk[i] += delta;
            reportProgress();
          },
          isPaused: () => _pauseFlags[request.taskId] ?? false,
          isCancelled: () => _cancelFlags[request.taskId] ?? false,
        );
        futures.add(worker.run(startFromByte: receivedPerChunk[i]));
      }

      try {
        await Future.wait(futures);
      } finally {
        for (final f in openFiles) {
          await f.close();
        }
      }

      await store.write(snapshot.copyWith(chunkReceivedBytes: receivedPerChunk));

      if (_cancelFlags[request.taskId] == true) {
        if (await file.exists()) await file.delete();
        await store.delete(request.taskId);
        controller.add(const DownloadFailed(DownloadCancelled()));
        return;
      }

      if (_pauseFlags[request.taskId] == true) {
        final received = receivedPerChunk.fold<int>(0, (a, b) => a + b);
        controller.add(
          DownloadPaused(
            DownloadProgress(
              bytesReceived: received,
              totalBytes: totalBytes,
              bytesPerSecond: 0,
              chunksTotal: ranges.length,
              chunksCompleted: 0,
            ),
          ),
        );
        return;
      }

      if (request.expectedSha256 != null) {
        final actual = await ChecksumVerifier.sha256OfFile(file);
        if (actual != request.expectedSha256) {
          await store.delete(request.taskId);
          controller.add(
            DownloadFailed(
              DownloadChecksumMismatch(
                expectedSha256: request.expectedSha256!,
                actualSha256: actual,
              ),
            ),
          );
          return;
        }
      }

      await store.delete(request.taskId);
      controller.add(DownloadCompleted(file.path));
    } catch (e, st) {
      controller.add(DownloadFailed(_mapError(e, st)));
    } finally {
      await controller.close();
    }
  }

  DownloadFailure _mapError(Object e, StackTrace st) {
    if (e is SocketException || e is HttpException || e is TimeoutException || e is http.ClientException) {
      return DownloadNetworkFailure(e.toString(), e);
    }
    return DownloadUnknownFailure(e, st);
  }

  Future<String> _defaultDestinationPath(String taskId) async {
    final dir = await getApplicationSupportDirectory();
    return '${dir.path}${Platform.pathSeparator}digit_downloader${Platform.pathSeparator}$taskId';
  }
}
