import 'package:flutter_test/flutter_test.dart';
import 'package:digit_downloader/src/engine/chunk_planner.dart';
import 'package:digit_downloader/src/models/byte_range.dart';

void main() {
  group('ChunkPlanner', () {
    test('splits evenly divisible sizes into equal chunks', () {
      final ranges = ChunkPlanner.plan(totalBytes: 4000, chunkCount: 4, minChunkSize: 100);
      expect(ranges, [
        const ByteRange(0, 999),
        const ByteRange(1000, 1999),
        const ByteRange(2000, 2999),
        const ByteRange(3000, 3999),
      ]);
    });

    test('distributes remainder bytes across the first chunks', () {
      final ranges = ChunkPlanner.plan(totalBytes: 10, chunkCount: 3, minChunkSize: 1);
      // 10 / 3 = 3 remainder 1 -> sizes [4, 3, 3]
      expect(ranges, [
        const ByteRange(0, 3),
        const ByteRange(4, 6),
        const ByteRange(7, 9),
      ]);
      final covered = ranges.fold<int>(0, (sum, r) => sum + r.length);
      expect(covered, 10);
    });

    test('collapses to a single chunk when smaller than minChunkSize', () {
      final ranges = ChunkPlanner.plan(totalBytes: 500, chunkCount: 4, minChunkSize: 1024 * 1024);
      expect(ranges, [const ByteRange(0, 499)]);
    });

    test('collapses to fewer chunks when not enough bytes for chunkCount', () {
      // 3 minChunkSize-sized chunks possible out of a requested 8
      final ranges = ChunkPlanner.plan(totalBytes: 3000, chunkCount: 8, minChunkSize: 1000);
      expect(ranges.length, 3);
    });

    test('every byte is covered by exactly one contiguous range', () {
      final ranges = ChunkPlanner.plan(totalBytes: 12345, chunkCount: 4, minChunkSize: 100);
      var expectedStart = 0;
      for (final range in ranges) {
        expect(range.start, expectedStart);
        expectedStart = range.end + 1;
      }
      expect(expectedStart, 12345);
    });
  });
}
