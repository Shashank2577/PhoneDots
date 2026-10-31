Future<String?> writeTextFile(String? dir, String name, String content) async => null;

Future<String?> readTextFile(String path, {int maxChars = 200000}) async => null;

Future<String> importFile(String? dir, String sourcePath, String name) async => sourcePath;

int fileLength(String path) => 0;

Future<String?> writeBytesFile(String? dir, String name, List<int> bytes) async => null;

Future<void> appendTextFile(String path, String text) async {}

Future<void> deleteFileAt(String path) async {}

bool fileExists(String path) => false;
