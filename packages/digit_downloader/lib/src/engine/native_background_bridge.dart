import 'dart:async';

import 'package:flutter/services.dart';

import '../models/download_request.dart';
import '../state/download_failure.dart';
import '../state/download_progress.dart';
import '../state/download_state.dart';

/// Drives [DownloadRequest]s with [DownloadRequest.backgroundMode] set to
/// [BackgroundDownloadMode.systemManaged] through the native background
/// download engine — an Android foreground `Service` or an iOS background
/// `URLSession`, both speaking the same channel protocol so this one Dart
/// class covers both; the platform difference lives entirely in the native
/// implementations, not here.
class NativeBackgroundBridge {
  static const MethodChannel _channel = MethodChannel('com.egov.digit_downloader');
  static const EventChannel _eventChannel = EventChannel('com.egov.digit_downloader/events');

  // One shared broadcast stream for every in-flight native download,
  // demultiplexed by taskId below — mirrors how just_installer's
  // EventChannel is filtered by sessionId.
  static Stream<Map<String, dynamic>>? _sharedEvents;

  static Stream<Map<String, dynamic>> get _events {
    return _sharedEvents ??= _eventChannel
        .receiveBroadcastStream()
        .map((event) => Map<String, dynamic>.from(event as Map))
        .asBroadcastStream();
  }

  Stream<DownloadState> start(DownloadRequest request) {
    late final StreamController<DownloadState> controller;
    StreamSubscription<Map<String, dynamic>>? subscription;

    controller = StreamController<DownloadState>(
      onListen: () async {
        // Emitted immediately, before any of the setup below — permission
        // checks, the method-channel round trip, native service startup,
        // and the HEAD request all take real time, and the caller should
        // see *something* the instant start() is called rather than
        // silence until the first real progress event. Matches
        // DigitDownloader._run's pure-Dart path, which does the same as its
        // very first line.
        controller.add(const DownloadStarting());

        subscription = _events.where((event) => event['taskId'] == request.taskId).listen((event) {
          final state = _mapEvent(event);
          controller.add(state);
          if (state is DownloadCompleted || state is DownloadFailed) {
            subscription?.cancel();
            controller.close();
          }
        });

        try {
          await ensureNotificationPermission();
          final headers = await request.headersBuilder?.call() ?? <String, String>{};
          await _channel.invokeMethod('start', {
            'taskId': request.taskId,
            'url': request.url.toString(),
            'destinationPath': request.destinationPath,
            'chunkCount': request.chunkCount,
            'minChunkSize': request.minChunkSize,
            'maxRetriesPerChunk': request.maxRetriesPerChunk,
            'expectedSha256': request.expectedSha256,
            'headers': headers,
            'certificatePins': _encodeCertificatePins(request),
            'notification': request.notificationConfig.toJson(),
          });
        } catch (e) {
          controller.add(DownloadFailed(DownloadUnknownFailure(e)));
          await subscription?.cancel();
          await controller.close();
        }
      },
      onCancel: () => subscription?.cancel(),
    );

    return controller.stream;
  }

  /// Android 13+: requests `POST_NOTIFICATIONS`, needed for the native
  /// download-progress notification to actually show — the manifest
  /// declaration alone doesn't grant it. Best-effort: [start] proceeds
  /// regardless of the result. No-op (`true`) on platforms where this
  /// isn't relevant.
  Future<bool> ensureNotificationPermission() async {
    try {
      return (await _channel.invokeMethod<bool>('ensureNotificationPermission')) ?? false;
    } catch (_) {
      return false;
    }
  }

  Future<void> pause(String taskId) => _channel.invokeMethod('pause', {'taskId': taskId});

  Future<void> cancel(String taskId) => _channel.invokeMethod('cancel', {'taskId': taskId});

  Future<bool> hasResumableDownload(String taskId) async {
    return (await _channel.invokeMethod<bool>('hasResumable', {'taskId': taskId})) ?? false;
  }

  Map<String, dynamic>? _encodeCertificatePins(DownloadRequest request) {
    final pins = request.certificatePins;
    if (pins == null) return null;
    return {
      for (final pin in pins.pins) pin.host: pin.sha256Pins.toList(),
    };
  }

  DownloadState _mapEvent(Map<String, dynamic> event) {
    switch (event['kind'] as String?) {
      case 'progress':
        return DownloadInProgress(_progressFrom(event));
      case 'paused':
        return DownloadPaused(_progressFrom(event));
      case 'completed':
        return DownloadCompleted(event['filePath'] as String);
      case 'failed':
        return DownloadFailed(_mapFailure(event));
      default:
        return const DownloadStarting();
    }
  }

  DownloadProgress _progressFrom(Map<String, dynamic> event) => DownloadProgress(
    bytesReceived: event['bytesReceived'] as int? ?? 0,
    totalBytes: event['totalBytes'] as int? ?? 0,
    bytesPerSecond: (event['bytesPerSecond'] as num?)?.toDouble() ?? 0,
    chunksTotal: event['chunksTotal'] as int? ?? 1,
    chunksCompleted: event['chunksCompleted'] as int? ?? 0,
  );

  DownloadFailure _mapFailure(Map<String, dynamic> event) {
    switch (event['failureKind'] as String?) {
      case 'checksumMismatch':
        return DownloadChecksumMismatch(
          expectedSha256: event['expectedSha256'] as String? ?? '',
          actualSha256: event['actualSha256'] as String? ?? '',
        );
      case 'certificatePinningFailure':
        return DownloadCertificatePinningFailure(event['host'] as String? ?? '');
      case 'cancelled':
        return const DownloadCancelled();
      case 'incomplete':
        return DownloadIncomplete(
          bytesReceived: event['bytesReceived'] as int? ?? 0,
          totalBytes: event['totalBytes'] as int? ?? 0,
        );
      case 'network':
      default:
        return DownloadNetworkFailure(event['message'] as String? ?? 'Unknown native download failure');
    }
  }
}
