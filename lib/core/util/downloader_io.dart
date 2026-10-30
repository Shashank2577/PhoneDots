import 'dart:async';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;

import 'downloader.dart';

Stream<DownloadProgress> downloadFile({
  required String url,
  required String destPath,
  String? sha256,
  Map<String, String> headers = const {},
  required CancelToken token,
}) async* {
  final part = File('$destPath.part');
  var existing = part.existsSync() ? part.lengthSync() : 0;
  final client = HttpClient()..autoUncompress = false;
  try {
    final request = await client.getUrl(Uri.parse(url));
    headers.forEach(request.headers.set);
    if (existing > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$existing-');
    final response = await request.close();
    if (response.statusCode == 416) {
      // Server says the range is past the end: the part file is complete.
      await response.drain<void>();
    } else {
      if (response.statusCode != 200 && response.statusCode != 206) {
        throw HttpException('HTTP ${response.statusCode} for $url');
      }
      if (response.statusCode == 200) existing = 0; // Server ignored the range.
      final total = existing + (response.contentLength < 0 ? 0 : response.contentLength);
      final sink = part.openWrite(mode: existing > 0 ? FileMode.append : FileMode.write);
      var received = existing;
      var lastEmit = DateTime.now();
      try {
        await for (final chunk in response) {
          if (token.cancelled) throw DownloadCancelled();
          sink.add(chunk);
          received += chunk.length;
          final now = DateTime.now();
          if (now.difference(lastEmit).inMilliseconds > 200) {
            lastEmit = now;
            yield DownloadProgress(received, total);
          }
        }
      } finally {
        await sink.close();
      }
      yield DownloadProgress(received, total);
    }
    if (sha256 != null) {
      final digest = await crypto.sha256.bind(part.openRead()).first;
      if (digest.toString() != sha256) {
        await part.delete();
        throw ChecksumMismatch(sha256, digest.toString());
      }
    }
    await part.rename(destPath);
  } finally {
    client.close(force: true);
  }
}

bool fileExists(String path) => File(path).existsSync();

int fileSize(String path) {
  final f = File(path);
  return f.existsSync() ? f.lengthSync() : 0;
}

Future<void> deleteFile(String path) async {
  for (final p in [path, '$path.part']) {
    final f = File(p);
    if (f.existsSync()) await f.delete();
  }
}
