import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;

import '../models/byte_range.dart';

/// Downloads one [ByteRange] via HTTP `Range` requests, writing bytes
/// directly into its own [RandomAccessFile] handle at the correct offset.
///
/// Ranges never overlap between workers, so each worker owning its own file
/// handle is safe without additional locking.
class ChunkWorker {
  ChunkWorker({
    required this.client,
    required this.url,
    required this.range,
    required this.file,
    required this.headersBuilder,
    required this.maxRetries,
    required this.onBytes,
    required this.isPaused,
    required this.isCancelled,
  });

  final http.Client client;
  final Uri url;
  final ByteRange range;
  final RandomAccessFile file;
  final Future<Map<String, String>> Function()? headersBuilder;
  final int maxRetries;
  final void Function(int deltaBytes) onBytes;
  final bool Function() isPaused;
  final bool Function() isCancelled;

  /// Resumes from [startFromByte] bytes already received *within this
  /// chunk* (i.e. an offset from [ByteRange.start], not an absolute file
  /// offset). Returns normally both on completion and on pause/cancel — the
  /// caller distinguishes those via [isPaused]/[isCancelled] afterwards.
  Future<void> run({required int startFromByte}) async {
    var position = range.start + startFromByte;
    var attempt = 0;

    while (position <= range.end) {
      if (isPaused() || isCancelled()) return;
      try {
        await _fetchFrom(position);
        return;
      } catch (_) {
        attempt++;
        if (attempt > maxRetries) rethrow;
        await Future.delayed(Duration(milliseconds: 300 * attempt));
      }
    }
  }

  Future<void> _fetchFrom(int startPosition) async {
    final headers = await headersBuilder?.call() ?? <String, String>{};
    headers['Range'] = 'bytes=$startPosition-${range.end}';
    final request = http.Request('GET', url)..headers.addAll(headers);
    final streamedResponse = await client.send(request);

    if (streamedResponse.statusCode != 206 && streamedResponse.statusCode != 200) {
      throw HttpException(
        'Unexpected status ${streamedResponse.statusCode} for ranged request',
      );
    }

    var position = startPosition;
    final completer = Completer<void>();
    late final StreamSubscription<List<int>> subscription;
    subscription = streamedResponse.stream.listen(
      (bytes) {
        subscription.pause();
        Future(() async {
          await file.setPosition(position);
          await file.writeFrom(bytes);
          position += bytes.length;
          onBytes(bytes.length);

          if (isPaused() || isCancelled()) {
            await subscription.cancel();
            if (!completer.isCompleted) completer.complete();
            return;
          }
          subscription.resume();
        }).catchError((Object e, StackTrace st) {
          subscription.cancel();
          if (!completer.isCompleted) completer.completeError(e, st);
        });
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (Object e, StackTrace st) {
        if (!completer.isCompleted) completer.completeError(e, st);
      },
      cancelOnError: true,
    );

    await completer.future;
  }
}
