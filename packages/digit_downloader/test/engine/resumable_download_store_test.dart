import 'package:flutter_test/flutter_test.dart';
import 'package:digit_downloader/src/engine/download_snapshot.dart';
import 'package:digit_downloader/src/engine/json_key_value_store.dart';
import 'package:digit_downloader/src/engine/resumable_download_store.dart';
import 'package:digit_downloader/src/models/byte_range.dart';

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

void main() {
  group('ResumableDownloadStore', () {
    late _FakeJsonKeyValueStore fake;
    late ResumableDownloadStore store;

    setUp(() {
      fake = _FakeJsonKeyValueStore();
      store = ResumableDownloadStore(fake);
    });

    test('round-trips a snapshot through JSON encode/decode', () async {
      final snapshot = DownloadSnapshot(
        taskId: 'task-1',
        totalBytes: 1000,
        etag: 'etag-abc',
        ranges: const [ByteRange(0, 499), ByteRange(500, 999)],
        chunkReceivedBytes: const [200, 999],
      );

      await store.write(snapshot);
      final read = await store.read('task-1');

      expect(read, isNotNull);
      expect(read!.taskId, 'task-1');
      expect(read.totalBytes, 1000);
      expect(read.etag, 'etag-abc');
      expect(read.ranges, const [ByteRange(0, 499), ByteRange(500, 999)]);
      expect(read.chunkReceivedBytes, const [200, 999]);
    });

    test('returns null for a taskId with no snapshot', () async {
      expect(await store.read('missing'), isNull);
    });

    test('delete removes the snapshot', () async {
      final snapshot = DownloadSnapshot(
        taskId: 'task-2',
        totalBytes: 10,
        etag: null,
        ranges: const [ByteRange(0, 9)],
        chunkReceivedBytes: const [0],
      );
      await store.write(snapshot);
      await store.delete('task-2');
      expect(await store.read('task-2'), isNull);
    });

    test('different taskIds do not collide', () async {
      await store.write(
        DownloadSnapshot(
          taskId: 'a',
          totalBytes: 1,
          etag: null,
          ranges: const [ByteRange(0, 0)],
          chunkReceivedBytes: const [0],
        ),
      );
      await store.write(
        DownloadSnapshot(
          taskId: 'b',
          totalBytes: 2,
          etag: null,
          ranges: const [ByteRange(0, 1)],
          chunkReceivedBytes: const [0],
        ),
      );

      expect((await store.read('a'))!.totalBytes, 1);
      expect((await store.read('b'))!.totalBytes, 2);
    });
  });
}
