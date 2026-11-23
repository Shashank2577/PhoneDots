import 'dart:async';
import 'dart:typed_data';

import 'package:record/record.dart';

import '../core/app_log.dart';
import 'vad.dart';
import 'wav.dart';

/// The microphone, always open during a conversation, with echo
/// cancellation so the assistant's own voice is not mistaken for yours.
/// Emits each thing you say as one clip once you pause.
class VoiceListener {
  VoiceListener({this.onSpeechStart, required this.onUtterance, this.onLevel});

  static const sampleRate = 16000;

  void Function()? onSpeechStart;
  final void Function(Float32List samples) onUtterance;
  final void Function(double db)? onLevel;

  final vad = EnergyVad(sampleRate: sampleRate);
  final _rec = AudioRecorder();
  StreamSubscription<Uint8List>? _sub;
  final _utterance = <double>[];

  /// Audio kept from just before speech was detected, so first syllables
  /// aren't cut off.
  final _preroll = <double>[];
  static const _prerollSamples = sampleRate * 3 ~/ 10;

  bool get listening => _sub != null;

  /// Asks for the microphone if needed; false when it was refused.
  Future<bool> start() async {
    if (_sub != null) return true;
    if (!await _rec.hasPermission()) return false;
    final stream = await _rec.startStream(
      const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: sampleRate,
        numChannels: 1,
        echoCancel: true,
        noiseSuppress: true,
        autoGain: true,
        androidConfig: AndroidRecordConfig(audioSource: AndroidAudioSource.voiceCommunication),
      ),
    );
    vad.reset();
    _sub = stream.listen(_onAudio, onError: (Object e) => appLog.error('voice', 'microphone error', {'error': '$e'}));
    appLog.info('voice', 'listening');
    return true;
  }

  void _onAudio(Uint8List bytes) {
    final samples = pcm16ToFloat(bytes);
    final wasInSpeech = vad.inSpeech;
    final events = vad.push(samples);
    onLevel?.call(vad.levelDb);
    if (wasInSpeech || vad.inSpeech) _utterance.addAll(samples);
    for (final e in events) {
      switch (e) {
        case VadEvent.speechStart:
          _utterance.insertAll(0, _preroll);
          onSpeechStart?.call();
        case VadEvent.speechEnd:
          final clip = Float32List.fromList(_utterance);
          _utterance.clear();
          // Ignore clicks and coughs shorter than about a third of a second.
          if (clip.length > sampleRate * 0.35) onUtterance(clip);
      }
    }
    if (!vad.inSpeech) {
      _preroll.addAll(samples);
      if (_preroll.length > _prerollSamples) _preroll.removeRange(0, _preroll.length - _prerollSamples);
    }
  }

  Future<void> stop() async {
    await _sub?.cancel();
    _sub = null;
    _utterance.clear();
    _preroll.clear();
    try {
      await _rec.stop();
    } catch (_) {}
    appLog.info('voice', 'stopped listening');
  }

  Future<void> dispose() async {
    await stop();
    await _rec.dispose();
  }
}
