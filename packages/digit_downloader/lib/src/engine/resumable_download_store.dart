import 'download_snapshot.dart';
import 'json_key_value_store.dart';

/// Persists/reads [DownloadSnapshot]s so a paused or killed download can
/// resume from disk state rather than just an in-memory pause.
class ResumableDownloadStore {
  ResumableDownloadStore(this._store);

  final JsonKeyValueStore _store;

  static const _prefix = 'digit_downloader.snapshot.';

  Future<DownloadSnapshot?> read(String taskId) {
    return _store.readJson<DownloadSnapshot>(
      '$_prefix$taskId',
      DownloadSnapshot.fromJson,
    );
  }

  Future<void> write(DownloadSnapshot snapshot) {
    return _store.writeJson<DownloadSnapshot>(
      '$_prefix${snapshot.taskId}',
      snapshot,
      (s) => s.toJson(),
    );
  }

  Future<void> delete(String taskId) => _store.delete('$_prefix$taskId');
}
