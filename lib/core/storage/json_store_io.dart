import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'json_store.dart';

Future<JsonStore> openStore() async {
  final support = await getApplicationSupportDirectory();
  final data = Directory('${support.path}/data')..createSync(recursive: true);
  final models = Directory('${support.path}/models')..createSync(recursive: true);
  final files = Directory('${support.path}/files')..createSync(recursive: true);
  return _FileStore(data, models.path, files.path);
}

class _FileStore implements JsonStore {
  _FileStore(this._dir, this.modelsDir, this.filesDir);

  final Directory _dir;

  @override
  final String modelsDir;

  @override
  final String filesDir;

  File _file(String key) => File('${_dir.path}/${Uri.encodeComponent(key)}.json');

  @override
  Future<Object?> read(String key) async {
    final f = _file(key);
    if (!f.existsSync()) return null;
    try {
      return jsonDecode(await f.readAsString());
    } on FormatException {
      return null;
    }
  }

  @override
  Future<void> write(String key, Object? value) async {
    final f = _file(key);
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(value), flush: true);
    await tmp.rename(f.path);
  }

  @override
  Future<void> delete(String key) async {
    final f = _file(key);
    if (f.existsSync()) await f.delete();
  }

  @override
  Future<List<String>> keys(String prefix) async => _dir
      .listSync()
      .whereType<File>()
      .map((f) => f.uri.pathSegments.last)
      .where((n) => n.endsWith('.json'))
      .map((n) => Uri.decodeComponent(n.substring(0, n.length - 5)))
      .where((k) => k.startsWith(prefix))
      .toList();
}
