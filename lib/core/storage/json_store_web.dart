import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'json_store.dart';

Future<JsonStore> openStore() async => _PrefsStore(await SharedPreferences.getInstance());

class _PrefsStore implements JsonStore {
  _PrefsStore(this._prefs);

  final SharedPreferences _prefs;
  static const _ns = 'pd.';

  @override
  String? get modelsDir => null;

  @override
  String? get filesDir => null;

  @override
  Future<Object?> read(String key) async {
    final s = _prefs.getString('$_ns$key');
    return s == null ? null : jsonDecode(s);
  }

  @override
  Future<void> write(String key, Object? value) => _prefs.setString('$_ns$key', jsonEncode(value));

  @override
  Future<void> delete(String key) => _prefs.remove('$_ns$key');

  @override
  Future<List<String>> keys(String prefix) async => _prefs
      .getKeys()
      .where((k) => k.startsWith('$_ns$prefix'))
      .map((k) => k.substring(_ns.length))
      .toList();
}
