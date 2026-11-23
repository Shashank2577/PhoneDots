import 'dart:math';
import 'dart:typed_data';

enum VadEvent { speechStart, speechEnd }

/// Decides when someone starts and stops talking from the microphone's
/// loudness, measured against a background level it learns as it goes (so
/// it works in a quiet room and on a noisy street).
///
/// Interruptions ([bargeIn]) need clearly louder, longer speech, because the
/// phone may be hearing its own voice through the speaker.
class EnergyVad {
  EnergyVad({
    this.sampleRate = 16000,
    this.frameMs = 20,
    this.startMarginDb = 12,
    this.bargeInMarginDb = 20,
    this.endMarginDb = 7,
    this.startMs = 120,
    this.bargeInMs = 280,
    this.endSilenceMs = 750,
    this.maxUtteranceMs = 30000,
    this.minLevelDb = -50,
    this.warmupMs = 300,
  });

  final int sampleRate;
  final int frameMs;
  final double startMarginDb;
  final double bargeInMarginDb;
  final double endMarginDb;
  final int startMs;
  final int bargeInMs;
  final int endSilenceMs;
  final int maxUtteranceMs;
  final double minLevelDb;

  /// The first moments only learn the room, so a noisy place doesn't count
  /// as speech before the background level is known.
  final int warmupMs;
  int _heardMs = 0;
  double _warmSum = 0;

  /// While the assistant is speaking.
  bool bargeIn = false;

  double noiseFloorDb = -60;
  double levelDb = -100;
  bool inSpeech = false;
  int _loudMs = 0;
  int _quietMs = 0;
  int _speechMs = 0;
  final _pending = <double>[];

  int get frameSamples => sampleRate * frameMs ~/ 1000;

  /// Feeds any amount of audio; returns the events it caused, in order.
  List<VadEvent> push(Float32List samples) {
    final events = <VadEvent>[];
    _pending.addAll(samples);
    final n = frameSamples;
    var i = 0;
    for (; i + n <= _pending.length; i += n) {
      final e = _frame(_pending, i, n);
      if (e != null) events.add(e);
    }
    _pending.removeRange(0, i);
    return events;
  }

  VadEvent? _frame(List<double> s, int from, int n) {
    var sum = 0.0;
    for (var k = from; k < from + n; k++) {
      sum += s[k] * s[k];
    }
    final rms = sqrt(sum / n);
    levelDb = rms <= 1e-9 ? -100 : 20 * log(rms) / ln10;
    if (_heardMs < warmupMs) {
      _heardMs += frameMs;
      _warmSum += levelDb;
      noiseFloorDb = (_warmSum / (_heardMs / frameMs)).clamp(-80, -20);
      return null;
    }

    if (!inSpeech) {
      final margin = bargeIn ? bargeInMarginDb : startMarginDb;
      final loud = levelDb > noiseFloorDb + margin && levelDb > minLevelDb;
      _loudMs = loud ? _loudMs + frameMs : 0;
      if (!loud) {
        // Learn the room: follow quiet frames quickly down, slowly up.
        final rate = levelDb < noiseFloorDb ? 0.2 : 0.02;
        noiseFloorDb += (levelDb - noiseFloorDb) * rate;
        noiseFloorDb = noiseFloorDb.clamp(-80, -20);
      }
      if (_loudMs >= (bargeIn ? bargeInMs : startMs)) {
        inSpeech = true;
        _quietMs = 0;
        _speechMs = _loudMs;
        _loudMs = 0;
        return VadEvent.speechStart;
      }
      return null;
    }
    _speechMs += frameMs;
    final quiet = levelDb < noiseFloorDb + endMarginDb;
    _quietMs = quiet ? _quietMs + frameMs : 0;
    if (_quietMs >= endSilenceMs || _speechMs >= maxUtteranceMs) {
      inSpeech = false;
      _quietMs = 0;
      _speechMs = 0;
      return VadEvent.speechEnd;
    }
    return null;
  }

  void reset() {
    _heardMs = 0;
    _warmSum = 0;
    inSpeech = false;
    _loudMs = 0;
    _quietMs = 0;
    _speechMs = 0;
    _pending.clear();
  }
}
