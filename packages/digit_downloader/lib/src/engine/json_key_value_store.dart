/// The narrow slice of `just_storage`'s `JustStandardStorage` API that the
/// resumable-download store actually needs. Kept as an interface (rather than
/// depending on the concrete class directly) purely as a test seam — real
/// usage is backed by `just_storage` via `JustStorageAdapter`.
abstract interface class JsonKeyValueStore {
  Future<T?> readJson<T>(String key, T Function(Map<String, dynamic> json) decoder);

  Future<void> writeJson<T>(
    String key,
    T value,
    Map<String, dynamic> Function(T value) encoder,
  );

  Future<void> delete(String key);
}
