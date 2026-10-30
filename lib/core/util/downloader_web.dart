import 'downloader.dart';

Stream<DownloadProgress> downloadFile({
  required String url,
  required String destPath,
  String? sha256,
  Map<String, String> headers = const {},
  required CancelToken token,
}) => Stream.error(UnsupportedError('Model files are only stored on phones.'));

bool fileExists(String path) => false;

int fileSize(String path) => 0;

Future<void> deleteFile(String path) async {}
