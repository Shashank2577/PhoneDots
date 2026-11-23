import 'dart:typed_data';

/// Mono PCM audio in memory.
class Pcm {
  const Pcm(this.samples, this.sampleRate);
  final Float32List samples;
  final int sampleRate;

  double get seconds => sampleRate == 0 ? 0 : samples.length / sampleRate;
}

/// 16-bit mono WAV, the format every player understands.
Uint8List encodeWav(Float32List samples, int sampleRate) {
  final data = samples.length * 2;
  final b = ByteData(44 + data);
  void str(int o, String s) {
    for (var i = 0; i < s.length; i++) {
      b.setUint8(o + i, s.codeUnitAt(i));
    }
  }

  str(0, 'RIFF');
  b.setUint32(4, 36 + data, Endian.little);
  str(8, 'WAVE');
  str(12, 'fmt ');
  b.setUint32(16, 16, Endian.little);
  b.setUint16(20, 1, Endian.little); // PCM
  b.setUint16(22, 1, Endian.little); // mono
  b.setUint32(24, sampleRate, Endian.little);
  b.setUint32(28, sampleRate * 2, Endian.little);
  b.setUint16(32, 2, Endian.little);
  b.setUint16(34, 16, Endian.little);
  str(36, 'data');
  b.setUint32(40, data, Endian.little);
  for (var i = 0; i < samples.length; i++) {
    final v = (samples[i].clamp(-1.0, 1.0) * 32767).round();
    b.setInt16(44 + i * 2, v, Endian.little);
  }
  return b.buffer.asUint8List();
}

/// Reads a PCM WAV (8/16/24/32-bit integer or 32-bit float, any channel
/// count) into mono float samples. Returns null when it isn't a WAV it knows.
Pcm? decodeWav(Uint8List bytes) {
  if (bytes.length < 12) return null;
  final b = ByteData.sublistView(bytes);
  String tag(int o) => String.fromCharCodes(bytes.sublist(o, o + 4));
  if (tag(0) != 'RIFF' || tag(8) != 'WAVE') return null;
  int? format, channels, rate, bits;
  var o = 12;
  while (o + 8 <= bytes.length) {
    final id = tag(o);
    final size = b.getUint32(o + 4, Endian.little);
    final body = o + 8;
    if (id == 'fmt ' && body + 16 <= bytes.length) {
      format = b.getUint16(body, Endian.little);
      channels = b.getUint16(body + 2, Endian.little);
      rate = b.getUint32(body + 4, Endian.little);
      bits = b.getUint16(body + 14, Endian.little);
      if (format == 0xFFFE && size >= 26) format = b.getUint16(body + 24, Endian.little); // extensible
    } else if (id == 'data' && format != null && channels != null && rate != null && bits != null) {
      final end = (body + size).clamp(body, bytes.length);
      final bytesPer = bits ~/ 8;
      if (bytesPer == 0 || channels == 0) return null;
      final frames = (end - body) ~/ (bytesPer * channels);
      final out = Float32List(frames);
      for (var f = 0; f < frames; f++) {
        var sum = 0.0;
        for (var c = 0; c < channels; c++) {
          final p = body + (f * channels + c) * bytesPer;
          sum += switch ((format, bits)) {
            (3, 32) => b.getFloat32(p, Endian.little),
            (_, 16) => b.getInt16(p, Endian.little) / 32768,
            (_, 8) => (b.getUint8(p) - 128) / 128,
            (_, 24) => ((b.getUint8(p) | b.getUint8(p + 1) << 8 | b.getInt8(p + 2) << 16)) / 8388608,
            (_, 32) => b.getInt32(p, Endian.little) / 2147483648,
            _ => 0,
          };
        }
        out[f] = sum / channels;
      }
      return Pcm(out, rate);
    }
    o = body + size + (size.isOdd ? 1 : 0);
  }
  return null;
}

/// 16-bit little-endian PCM (what the microphone stream gives) to floats.
Float32List pcm16ToFloat(Uint8List bytes) {
  final b = ByteData.sublistView(bytes);
  final out = Float32List(bytes.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = b.getInt16(i * 2, Endian.little) / 32768;
  }
  return out;
}
