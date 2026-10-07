import '../models/byte_range.dart';

/// Persisted resume state for one [DownloadRequest.taskId]: enough to decide
/// whether a future `start()` call can continue an interrupted download
/// (matching [totalBytes]/[etag] and an on-disk file of the right length) or
/// must restart clean.
class DownloadSnapshot {
  const DownloadSnapshot({
    required this.taskId,
    required this.totalBytes,
    required this.etag,
    required this.ranges,
    required this.chunkReceivedBytes,
  });

  final String taskId;
  final int totalBytes;
  final String? etag;
  final List<ByteRange> ranges;

  /// Bytes already written for each entry in [ranges], same index order.
  final List<int> chunkReceivedBytes;

  Map<String, dynamic> toJson() => {
    'taskId': taskId,
    'totalBytes': totalBytes,
    'etag': etag,
    'ranges': ranges.map((r) => r.toJson()).toList(),
    'chunkReceivedBytes': chunkReceivedBytes,
  };

  factory DownloadSnapshot.fromJson(Map<String, dynamic> json) => DownloadSnapshot(
    taskId: json['taskId'] as String,
    totalBytes: json['totalBytes'] as int,
    etag: json['etag'] as String?,
    ranges: (json['ranges'] as List)
        .map((e) => ByteRange.fromJson(e as List))
        .toList(),
    chunkReceivedBytes: (json['chunkReceivedBytes'] as List)
        .map((e) => e as int)
        .toList(),
  );

  DownloadSnapshot copyWith({List<int>? chunkReceivedBytes}) => DownloadSnapshot(
    taskId: taskId,
    totalBytes: totalBytes,
    etag: etag,
    ranges: ranges,
    chunkReceivedBytes: chunkReceivedBytes ?? this.chunkReceivedBytes,
  );
}
