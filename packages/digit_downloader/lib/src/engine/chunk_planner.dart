import '../models/byte_range.dart';

/// Splits a file of [totalBytes] into disjoint, contiguous [ByteRange]s for
/// concurrent chunk workers.
///
/// Collapses to a single chunk whenever the file is smaller than
/// [minChunkSize], or when there simply aren't enough bytes to fill
/// [chunkCount] chunks of at least [minChunkSize] each. Any remainder bytes
/// (when [totalBytes] doesn't divide evenly) are distributed one-per-chunk
/// across the first chunks, so every byte is covered by exactly one range.
abstract final class ChunkPlanner {
  static List<ByteRange> plan({
    required int totalBytes,
    required int chunkCount,
    required int minChunkSize,
  }) {
    if (totalBytes <= 0) {
      return const [ByteRange(0, -1)];
    }

    final maxPossibleChunks = totalBytes ~/ minChunkSize;
    final effectiveCount = maxPossibleChunks < 1
        ? 1
        : (chunkCount < maxPossibleChunks ? chunkCount : maxPossibleChunks);

    final baseSize = totalBytes ~/ effectiveCount;
    final remainder = totalBytes % effectiveCount;

    final ranges = <ByteRange>[];
    var start = 0;
    for (var i = 0; i < effectiveCount; i++) {
      final size = baseSize + (i < remainder ? 1 : 0);
      final end = start + size - 1;
      ranges.add(ByteRange(start, end));
      start = end + 1;
    }
    return ranges;
  }
}
