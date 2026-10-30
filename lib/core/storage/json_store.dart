import 'json_store_io.dart' if (dart.library.js_interop) 'json_store_web.dart' as impl;

/// Small persistent JSON documents keyed by name (conversations, memory,
/// recipes, the knowledge index). Files on device, browser storage on web.
abstract class JsonStore {
  static Future<JsonStore> open() => impl.openStore();

  Future<Object?> read(String key);

  Future<void> write(String key, Object? value);

  Future<void> delete(String key);

  Future<List<String>> keys(String prefix);

  /// Directory for downloaded models, or null where files are unavailable.
  String? get modelsDir;

  /// Directory for imported attachments (photos, audio, documents).
  String? get filesDir;
}
