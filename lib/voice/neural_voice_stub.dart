import 'neural_voice.dart';
import 'wav.dart';

class NeuralVoiceImpl implements NeuralVoice {
  @override
  bool get ready => false;

  @override
  Future<void> load(String engineDir, {int threads = 4}) async =>
      throw UnsupportedError('Neural voices need the Android or iOS app.');

  @override
  Future<Pcm> speak(String text, {required String clipPath, double speed = 1.0}) async =>
      throw UnsupportedError('Neural voices need the Android or iOS app.');

  @override
  Future<void> dispose() async {}
}

Future<void> extractArchive(String archivePath, String outDir) async => throw UnsupportedError('Not available here.');
