import 'neural_voice_stub.dart' if (dart.library.io) 'neural_voice_io.dart' as impl;
import 'wav.dart';

/// The on-device neural voice (Pocket TTS through sherpa-onnx), run in a
/// background isolate so speaking never stalls the screen.
abstract class NeuralVoice {
  factory NeuralVoice() = impl.NeuralVoiceImpl;

  bool get ready;

  /// Loads the engine from its extracted folder. Throws with a readable
  /// message when it can't.
  Future<void> load(String engineDir, {int threads = 4});

  /// Speaks [text] in the voice and tone of the reference clip at [clipPath].
  Future<Pcm> speak(String text, {required String clipPath, double speed = 1.0});

  Future<void> dispose();
}

/// Unpacks a downloaded .tar.bz2 into [outDir] (in the background).
Future<void> extractArchive(String archivePath, String outDir) => impl.extractArchive(archivePath, outDir);
