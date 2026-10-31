import 'files_io.dart' if (dart.library.js_interop) 'files_web.dart' as impl;

/// Writes [content] to [dir]/[name] (de-duplicating the name) and returns the path.
Future<String?> writeTextFile(String? dir, String name, String content) => impl.writeTextFile(dir, name, content);

Future<String?> readTextFile(String path, {int maxChars = 200000}) => impl.readTextFile(path, maxChars: maxChars);

/// Copies a picked file into app storage so it outlives the picker cache.
Future<String> importFile(String? dir, String sourcePath, String name) => impl.importFile(dir, sourcePath, name);

int fileLength(String path) => impl.fileLength(path);

/// Writes raw bytes (e.g. a downloaded cover image) and returns the path.
Future<String?> writeBytesFile(String? dir, String name, List<int> bytes) => impl.writeBytesFile(dir, name, bytes);
