import 'dart:convert';

import 'json_store.dart';

/// In-memory store for tests. Values round-trip through JSON exactly like the
/// file store, so anything that would fail to save on a phone fails here too.
class MemoryJsonStore implements JsonStore {
  final Map<String, Object?> data = {};

  @override
  String? get modelsDir => null;

  @override
  String? get filesDir => null;

  @override
  Future<Object?> read(String key) async => data[key] == null ? null : jsonDecode(data[key] as String);

  @override
  Future<void> write(String key, Object? value) async => data[key] = jsonEncode(value);

  @override
  Future<void> delete(String key) async => data.remove(key);

  @override
  Future<List<String>> keys(String prefix) async => data.keys.where((k) => k.startsWith(prefix)).toList();
}
