import 'package:just_storage/just_storage.dart';

import 'json_key_value_store.dart';

/// Adapts `just_storage`'s `JustStandardStorage` to [JsonKeyValueStore].
class JustStorageAdapter implements JsonKeyValueStore {
  JustStorageAdapter(this._storage);

  final JustStandardStorage _storage;

  @override
  Future<T?> readJson<T>(String key, T Function(Map<String, dynamic>) decoder) =>
      _storage.readJson<T>(key, decoder);

  @override
  Future<void> writeJson<T>(
    String key,
    T value,
    Map<String, dynamic> Function(T) encoder,
  ) => _storage.writeJson<T>(key, value, encoder);

  @override
  Future<void> delete(String key) => _storage.delete(key);
}
