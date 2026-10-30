import 'downloader_io.dart' if (dart.library.js_interop) 'downloader_web.dart' as impl;

class DownloadProgress {
  const DownloadProgress(this.received, this.total);
  final int received;
  final int total;
  double get fraction => total <= 0 ? 0 : received / total;
}

class DownloadCancelled implements Exception {
  @override
  String toString() => 'Download cancelled';
}

class ChecksumMismatch implements Exception {
  ChecksumMismatch(this.expected, this.actual);
  final String expected;
  final String actual;
  @override
  String toString() => 'Checksum mismatch: expected $expected, got $actual';
}

class CancelToken {
  bool cancelled = false;
  void cancel() => cancelled = true;
}

/// Resumable download into [destPath] (via `.part`), verified by SHA-256.
Stream<DownloadProgress> downloadFile({
  required String url,
  required String destPath,
  String? sha256,
  Map<String, String> headers = const {},
  required CancelToken token,
}) => impl.downloadFile(url: url, destPath: destPath, sha256: sha256, headers: headers, token: token);

bool fileExists(String path) => impl.fileExists(path);

int fileSize(String path) => impl.fileSize(path);

Future<void> deleteFile(String path) => impl.deleteFile(path);
