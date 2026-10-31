import 'dart:io';

String _unique(String dir, String name) {
  final safe = name.replaceAll(RegExp(r'[/\\:]'), '_');
  var path = '$dir/$safe';
  final dot = safe.lastIndexOf('.');
  final base = dot > 0 ? safe.substring(0, dot) : safe;
  final ext = dot > 0 ? safe.substring(dot) : '';
  var i = 1;
  while (File(path).existsSync()) {
    path = '$dir/$base-${i++}$ext';
  }
  return path;
}

Future<String?> writeTextFile(String? dir, String name, String content) async {
  if (dir == null) return null;
  final path = _unique(dir, name);
  await File(path).writeAsString(content);
  return path;
}

Future<String?> readTextFile(String path, {int maxChars = 200000}) async {
  final f = File(path);
  if (!f.existsSync()) return null;
  final s = await f.readAsString();
  return s.length > maxChars ? s.substring(0, maxChars) : s;
}

Future<String> importFile(String? dir, String sourcePath, String name) async {
  if (dir == null) return sourcePath;
  final dest = _unique(dir, name);
  await File(sourcePath).copy(dest);
  return dest;
}

int fileLength(String path) {
  final f = File(path);
  return f.existsSync() ? f.lengthSync() : 0;
}

Future<String?> writeBytesFile(String? dir, String name, List<int> bytes) async {
  if (dir == null) return null;
  final path = _unique(dir, name);
  await File(path).writeAsBytes(bytes);
  return path;
}

Future<void> appendTextFile(String path, String text) async {
  await File(path).writeAsString(text, mode: FileMode.append, flush: false);
}

Future<void> deleteFileAt(String path) async {
  final f = File(path);
  if (f.existsSync()) await f.delete();
}

bool fileExists(String path) => File(path).existsSync();
