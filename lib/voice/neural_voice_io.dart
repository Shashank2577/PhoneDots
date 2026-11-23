import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart' as archive;
import 'package:sherpa_onnx/sherpa_onnx.dart' as sherpa;

import 'neural_voice.dart';
import 'voice_catalog.dart';
import 'wav.dart';

class NeuralVoiceImpl implements NeuralVoice {
  SendPort? _worker;
  Isolate? _isolate;
  String? _loadedDir;

  @override
  bool get ready => _worker != null && _loadedDir != null;

  Future<Object?> _call(List<Object?> msg) async {
    final reply = ReceivePort();
    _worker!.send([...msg, reply.sendPort]);
    final r = await reply.first;
    reply.close();
    if (r is List && r.isNotEmpty && r.first == 'error') throw StateError('${r[1]}');
    return r;
  }

  @override
  Future<void> load(String engineDir, {int threads = 4}) async {
    if (_loadedDir == engineDir && _worker != null) return;
    for (final f in PocketEngine.files) {
      if (!File('$engineDir/$f').existsSync()) {
        throw StateError('The voice engine is incomplete ($f is missing). Download it again.');
      }
    }
    if (_worker == null) {
      final ready = ReceivePort();
      _isolate = await Isolate.spawn(_workerMain, ready.sendPort, debugName: 'phonedots-voice');
      _worker = await ready.first as SendPort;
      ready.close();
    }
    await _call(['load', engineDir, threads]);
    _loadedDir = engineDir;
  }

  @override
  Future<Pcm> speak(String text, {required String clipPath, double speed = 1.0}) async {
    if (!ready) throw StateError('The voice engine is not loaded.');
    final r = await _call(['speak', text, clipPath, speed]) as List;
    final samples = (r[1] as TransferableTypedData).materialize().asFloat32List();
    return Pcm(samples, r[2] as int);
  }

  @override
  Future<void> dispose() async {
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _worker = null;
    _loadedDir = null;
  }
}

/// The background isolate: owns the sherpa-onnx engine and the decoded clips.
void _workerMain(SendPort ready) {
  final port = ReceivePort();
  ready.send(port.sendPort);
  sherpa.OfflineTts? tts;
  final clips = <String, Pcm>{};
  port.listen((msg) {
    final m = msg as List;
    final reply = m.last as SendPort;
    try {
      switch (m.first) {
        case 'load':
          sherpa.initBindings();
          final dir = m[1] as String;
          tts?.free();
          tts = sherpa.OfflineTts(
            sherpa.OfflineTtsConfig(
              model: sherpa.OfflineTtsModelConfig(
                pocket: sherpa.OfflineTtsPocketModelConfig(
                  lmFlow: '$dir/lm_flow.int8.onnx',
                  lmMain: '$dir/lm_main.int8.onnx',
                  encoder: '$dir/encoder.onnx',
                  decoder: '$dir/decoder.int8.onnx',
                  textConditioner: '$dir/text_conditioner.onnx',
                  vocabJson: '$dir/vocab.json',
                  tokenScoresJson: '$dir/token_scores.json',
                ),
                numThreads: m[2] as int,
              ),
            ),
          );
          reply.send(['ok']);
        case 'speak':
          final engine = tts ?? (throw StateError('not loaded'));
          final path = m[2] as String;
          final clip = clips[path] ??=
              decodeWav(File(path).readAsBytesSync()) ?? (throw StateError('Unreadable voice clip.'));
          final audio = engine.generateWithConfig(
            text: m[1] as String,
            config: sherpa.OfflineTtsGenerationConfig(
              speed: (m[3] as num).toDouble(),
              referenceAudio: clip.samples,
              referenceSampleRate: clip.sampleRate,
            ),
          );
          if (audio.samples.isEmpty) throw StateError('The voice engine produced no audio.');
          reply.send([
            'ok',
            TransferableTypedData.fromList([audio.samples]),
            audio.sampleRate,
          ]);
        default:
          reply.send(['error', 'unknown request ${m.first}']);
      }
    } catch (e) {
      reply.send(['error', '$e']);
    }
  });
}

Future<void> extractArchive(String archivePath, String outDir) =>
    Isolate.run(() => archive.extractFileToDisk(archivePath, outDir, verify: true));
