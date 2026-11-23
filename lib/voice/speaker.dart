import 'dart:async';
import 'dart:collection';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_tts/flutter_tts.dart';

import '../core/app_log.dart';
import '../core/settings.dart';
import '../core/util/files.dart';
import 'neural_voice.dart';
import 'speech_text.dart';
import 'voice_manager.dart';
import 'wav.dart';

/// Speaks sentences one after another, making the next while the current
/// one plays, in the chosen neural voice (with its mood) or the phone's own.
class Speaker extends ChangeNotifier {
  Speaker({required this.voices, required this.settings, required this.filesDir, this.neural});

  final VoiceManager voices;
  final AppSettings settings;
  final String? filesDir;
  final NeuralVoice? neural;

  final _queue = Queue<SpeechChunk>();
  bool speaking = false;
  Mood mood = Mood.neutral;
  String current = '';
  int _generation = 0;
  AudioPlayer? _player;
  FlutterTts? _system;
  Completer<void>? _idle;
  int _tmp = 0;

  /// Finished when everything queued has been spoken (or stopped).
  Future<void> get whenIdle => speaking ? (_idle ??= Completer<void>()).future : Future.value();

  void say(SpeechChunk c) {
    if (c.text.trim().isEmpty) return;
    _queue.add(c);
    if (!speaking) unawaited(_run(_generation));
  }

  void sayAll(String text) {
    final s = SentenceStreamer(minChars: 0);
    for (final c in [...s.update(text), ...s.finish()]) {
      say(c);
    }
  }

  /// Stops at once: for interruptions.
  Future<void> stop() async {
    _generation++;
    _queue.clear();
    try {
      await _player?.stop();
    } catch (_) {}
    try {
      await _system?.stop();
    } catch (_) {}
    _done();
  }

  void _done() {
    speaking = false;
    current = '';
    notifyListeners();
    _idle?.complete();
    _idle = null;
  }

  Future<void> _run(int gen) async {
    speaking = true;
    notifyListeners();
    // Make sentence n+1 while sentence n plays.
    Future<String?>? next;
    SpeechChunk? nextChunk;
    try {
      while (gen == _generation && (_queue.isNotEmpty || next != null)) {
        final chunk = nextChunk ?? _queue.removeFirst();
        final made = next ?? _render(chunk);
        next = null;
        nextChunk = null;
        final path = await made;
        if (gen != _generation) return;
        if (_queue.isNotEmpty) {
          nextChunk = _queue.removeFirst();
          next = _render(nextChunk);
        }
        mood = chunk.mood;
        current = chunk.text;
        notifyListeners();
        if (path == null) {
          await _speakSystem(chunk.text);
        } else {
          await _play(path);
        }
      }
    } catch (e, st) {
      appLog.error('voice', 'speaking failed', null, e, st);
    } finally {
      if (gen == _generation) _done();
    }
  }

  /// Renders a sentence with the neural voice to a WAV file; null means use
  /// the phone's own voice.
  Future<String?> _render(SpeechChunk c) async {
    final v = voices.selected;
    final engineDir = voices.engineDir;
    final engine = neural;
    if (v == null || engine == null || engineDir == null || filesDir == null) return null;
    try {
      if (!engine.ready) await engine.load(engineDir);
      final clip = voices.clipFor(v, c.mood);
      if (clip == null) return null;
      final started = DateTime.now();
      final pcm = await engine.speak(c.text, clipPath: clip, speed: settings.voiceSpeed);
      final ms = DateTime.now().difference(started).inMilliseconds;
      appLog.info('voice', 'sentence made', {
        'mood': c.mood.name,
        'chars': c.text.length,
        'audioMs': (pcm.seconds * 1000).round(),
        'ms': ms,
      });
      final path = await writeBytesFile(filesDir, 'speech-${_tmp++ % 6}.wav', encodeWav(pcm.samples, pcm.sampleRate));
      return path;
    } catch (e, st) {
      appLog.error('voice', 'neural voice failed; using the phone voice', null, e, st);
      return null;
    }
  }

  Future<void> _play(String path) async {
    final p = _player ??= AudioPlayer();
    final done = Completer<void>();
    late final StreamSubscription<void> sub;
    sub = p.onPlayerComplete.listen((_) {
      if (!done.isCompleted) done.complete();
    });
    try {
      await p.play(DeviceFileSource(path));
      await done.future.timeout(const Duration(minutes: 2));
    } finally {
      await sub.cancel();
      unawaited(deleteFileAt(path));
    }
  }

  Future<void> _speakSystem(String text) async {
    final t = _system ??= FlutterTts();
    await t.awaitSpeakCompletion(true);
    await t.setSpeechRate((0.5 * settings.voiceSpeed).clamp(0.3, 0.8));
    await t.speak(text);
  }

  /// Plays a voice sample (a clip online, or a file on the phone).
  Future<void> preview(String urlOrPath) async {
    await stop();
    final p = _player ??= AudioPlayer();
    await p.play(urlOrPath.startsWith('http') ? UrlSource(urlOrPath) : DeviceFileSource(urlOrPath));
  }

  @override
  void dispose() {
    unawaited(stop());
    unawaited(_player?.dispose());
    super.dispose();
  }
}
