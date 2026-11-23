import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:phonedots/agent/prompts.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/app_state.dart';
import 'package:phonedots/core/ledger.dart';
import 'package:phonedots/core/settings.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/features/voice/voices_screen.dart';
import 'package:phonedots/main.dart';
import 'package:phonedots/voice/speech_text.dart';
import 'package:phonedots/voice/vad.dart';
import 'package:phonedots/voice/voice_catalog.dart';
import 'package:phonedots/voice/voice_manager.dart';
import 'package:phonedots/voice/wav.dart';

Float32List _tone(double seconds, double amp, {int sr = 16000, double hz = 220}) =>
    Float32List.fromList([for (var i = 0; i < (seconds * sr).round(); i++) amp * sin(2 * pi * hz * i / sr)]);

Float32List _noise(double seconds, double amp, {int sr = 16000, int seed = 1}) {
  final r = Random(seed);
  return Float32List.fromList([for (var i = 0; i < (seconds * sr).round(); i++) amp * (r.nextDouble() * 2 - 1)]);
}

/// A trimmed copy of the Hugging Face listing for kyutai/tts-voices.
final _listing = {
  'siblings': [
    for (final f in [
      'README.md',
      'voice-donations/0a67.wav',
      'voice-donations/0a67_enhanced.wav',
      'voice-donations/0a67.wav.1e68beda@240.safetensors',
      'voice-donations/1410.wav',
      'vctk/p225_023.wav',
      'vctk/p225_023_enhanced.wav',
      'expresso/ex04-ex01_default_001_channel1_168s.wav',
      'expresso/ex04-ex01_happy_001_channel1_30s.wav',
      'expresso/ex04-ex01_whisper_001_channel1_579s.wav',
      'expresso/ex03-ex04_laughing_001_channel2_12s.wav',
      'expresso/ex04-ex02_sad-sympathetic_001_channel1_454s.wav',
      'expresso/ex04-ex01_happy_001_channel1_30s_enhanced.wav',
      'expresso/ex01-ex04_default_002_channel1_9s.wav',
      'expresso/ex01-ex04_animal-animaldir_002_channel1_89s.wav',
    ])
      {'rfilename': f},
  ],
};

void main() {
  group('wav', () {
    test('16-bit mono round trip', () {
      final s = _tone(0.1, 0.5, sr: 24000);
      final back = decodeWav(encodeWav(s, 24000))!;
      expect(back.sampleRate, 24000);
      expect(back.samples.length, s.length);
      for (var i = 0; i < s.length; i += 97) {
        expect(back.samples[i], closeTo(s[i], 1 / 16000));
      }
    });

    test('stereo, float and 24-bit files are read as mono', () {
      Uint8List wav(int format, int bits, int channels, List<double> frames) {
        final bytesPer = bits ~/ 8;
        final data = ByteData(frames.length * channels * bytesPer);
        for (var f = 0; f < frames.length; f++) {
          for (var c = 0; c < channels; c++) {
            final o = (f * channels + c) * bytesPer;
            final v = frames[f] * (c == 0 ? 1 : 0.5);
            switch (bits) {
              case 32 when format == 3:
                data.setFloat32(o, v, Endian.little);
              case 16:
                data.setInt16(o, (v * 32767).round(), Endian.little);
              case 24:
                final x = (v * 8388607).round();
                data
                  ..setUint8(o, x & 0xFF)
                  ..setUint8(o + 1, (x >> 8) & 0xFF)
                  ..setInt8(o + 2, x >> 16);
            }
          }
        }
        final h = ByteData(44);
        void s(int o, String t) => [for (var i = 0; i < 4; i++) h.setUint8(o + i, t.codeUnitAt(i))];
        s(0, 'RIFF');
        h.setUint32(4, 36 + data.lengthInBytes, Endian.little);
        s(8, 'WAVE');
        s(12, 'fmt ');
        h
          ..setUint32(16, 16, Endian.little)
          ..setUint16(20, format, Endian.little)
          ..setUint16(22, channels, Endian.little)
          ..setUint32(24, 48000, Endian.little)
          ..setUint16(34, bits, Endian.little);
        s(36, 'data');
        h.setUint32(40, data.lengthInBytes, Endian.little);
        return Uint8List.fromList([...h.buffer.asUint8List(), ...data.buffer.asUint8List()]);
      }

      for (final (format, bits) in [(1, 16), (3, 32), (1, 24)]) {
        final pcm = decodeWav(wav(format, bits, 2, [0.4, -0.4]))!;
        expect(pcm.sampleRate, 48000);
        expect(pcm.samples[0], closeTo(0.3, 0.001), reason: '$bits-bit'); // (0.4 + 0.2) / 2
        expect(pcm.samples[1], closeTo(-0.3, 0.001));
      }
      expect(decodeWav(Uint8List.fromList(utf8.encode('not a wav file at all'))), isNull);
    });
  });

  group('speech text', () {
    test('moods: names and everyday synonyms', () {
      expect(Mood.parse('happy'), Mood.happy);
      expect(Mood.parse(' Cheerful '), Mood.happy);
      expect(Mood.parse('laugh'), Mood.laughing);
      expect(Mood.parse('whisper'), Mood.whisper);
      expect(Mood.parse('banana'), isNull);
    });

    test('mood tags are hidden from the text, other brackets are kept', () {
      expect(stripMoodTags('[happy] Great news! [calm] Take a breath.'), 'Great news! Take a breath.');
      expect(stripMoodTags('See [1] and [whisper] this'), 'See [1] and this');
    });

    test('speakable text drops markdown, links, code and emoji', () {
      expect(speakable('**Done!** See [the docs](https://x.y) or https://a.b/c 🎉'), 'Done! See the docs or a link');
      expect(speakable('- one\n- two'), 'one two');
    });

    test('a reply arriving word by word becomes sentences with moods, as soon as each is complete', () {
      final s = SentenceStreamer();
      final out = <SpeechChunk>[];
      const reply = '[happy] Oh, I found three recipes you will love! [calm] The quickest one takes ten minutes. Enjoy';
      for (var i = 1; i <= reply.length; i += 7) {
        out.addAll(s.update(reply.substring(0, i)));
      }
      out.addAll(s.update(reply));
      expect(out.map((c) => '$c'), [
        '[happy] Oh, I found three recipes you will love!',
        '[calm] The quickest one takes ten minutes.',
      ]);
      expect(s.finish().map((c) => '$c'), ['[calm] Enjoy']);
    });

    test('very short sentences are joined so the voice does not stutter', () {
      final s = SentenceStreamer();
      expect(s.update('Sure. '), isEmpty);
      expect(s.update('Sure. Setting a timer for ten minutes now. '), hasLength(1));
    });

    test('a mood change inside a sentence splits it', () {
      final s = SentenceStreamer(minChars: 0);
      final out = [...s.update('That is great [laughing] haha, really! '), ...s.finish()];
      expect(out.map((c) => '$c'), ['[neutral] That is great', '[laughing] haha, really!']);
    });

    test('a replaced reply starts over', () {
      final s = SentenceStreamer(minChars: 0);
      s.update('First try. ');
      expect(s.update('Second answer. ').single.text, 'Second answer.');
    });
  });

  group('voice catalogue', () {
    test('donated (cleaned clip preferred), VCTK, and expressive speakers with their moods', () {
      final list = VoiceCatalog.parse(_listing);
      final donated = list.where((v) => v.source == VoiceSource.donated).toList();
      expect(donated.map((v) => v.id), ['donated-0a67', 'donated-1410']);
      expect(donated.first.sampleUrl, endsWith('voice-donations/0a67_enhanced.wav'));
      expect(donated[1].sampleUrl, endsWith('voice-donations/1410.wav'));
      expect(list.where((v) => v.source == VoiceSource.vctk).single.sampleUrl, endsWith('p225_023_enhanced.wav'));
      final ex4 = list.singleWhere((v) => v.id == 'expressive-ex04');
      // Channel 1 of "ex04-…" and channel 2 of "…-ex04" are both speaker ex04.
      expect(ex4.clips.keys, containsAll([Mood.neutral, Mood.happy, Mood.whisper, Mood.laughing, Mood.sad]));
      expect(ex4.clips[Mood.happy], isNot(contains('_enhanced')));
      expect(ex4.personalUseOnly, isTrue);
      expect(ex4.expressive, isTrue);
      // ex01 has a neutral clip but no supported moods besides it.
      expect(list.singleWhere((v) => v.id == 'expressive-ex01').clips.keys, [Mood.neutral]);
      expect(list.any((v) => v.source == VoiceSource.expressive && v.id == 'expressive-ex03'), isFalse);
    });

    test('specs survive a save and reload', () {
      final v = VoiceCatalog.parse(_listing).singleWhere((v) => v.id == 'expressive-ex04');
      final back = VoiceSpec.fromJson(jsonDecode(jsonEncode(v.toJson())) as Map<String, dynamic>)!;
      expect(back.clips, v.clips);
      expect(back.source, VoiceSource.expressive);
      expect(VoiceSpec.fromJson({'id': 'x', 'name': 'x', 'source': 'donated', 'clips': {}}), isNull);
    });
  });

  group('voice detection', () {
    test('quiet room, then speech, then a pause: one start and one end', () {
      final vad = EnergyVad();
      final events = <VadEvent>[
        ...vad.push(_noise(1.5, 0.001)),
        ...vad.push(_tone(1.0, 0.2)),
        ...vad.push(_noise(1.0, 0.001, seed: 2)),
      ];
      expect(events, [VadEvent.speechStart, VadEvent.speechEnd]);
    });

    test('a noisy street raises the bar instead of triggering', () {
      final vad = EnergyVad();
      expect(vad.push(_noise(3, 0.02)), isEmpty);
      expect(vad.noiseFloorDb, greaterThan(-45));
      expect(vad.push(_tone(1.0, 0.3)), contains(VadEvent.speechStart));
    });

    test('while the assistant speaks, only clear, longer speech interrupts', () {
      final vad = EnergyVad()..bargeIn = true;
      vad.push(_noise(1, 0.001));
      // A short, moderate sound (its own voice leaking through) does nothing…
      expect(vad.push(_tone(0.2, 0.02)), isEmpty);
      vad.push(_noise(0.5, 0.001));
      // …a clear sentence does.
      expect(vad.push(_tone(0.6, 0.3)), [VadEvent.speechStart]);
    });

    test('very long speech is cut into turns', () {
      final vad = EnergyVad(maxUtteranceMs: 2000);
      vad.push(_noise(1, 0.001));
      expect(vad.push(_tone(3, 0.2)), [VadEvent.speechStart, VadEvent.speechEnd, VadEvent.speechStart]);
    });
  });

  test('the spoken-conversation prompt asks for short plain replies, and for moods only when the voice has them', () {
    String sys({required bool spoken, required bool moods}) => Prompts.system(
      now: DateTime(2026, 11, 23),
      attachments: const [],
      memory: '',
      tools: const [],
      nativeTools: true,
      spoken: spoken,
      moods: moods,
    );
    expect(sys(spoken: false, moods: false), isNot(contains('voice conversation')));
    expect(sys(spoken: true, moods: false), contains('voice conversation'));
    expect(sys(spoken: true, moods: false), isNot(contains('[happy]')));
    expect(sys(spoken: true, moods: true), contains('[happy]'));
  });

  group('voice manager', () {
    Future<(VoiceManager, AppSettings, List<String>)> make() async {
      final store = MemoryJsonStore();
      final settings = AppSettings(store);
      final calls = <String>[];
      final v = VoiceManager(
        store: store,
        settings: settings,
        ledger: Ledger(store),
        modelsDir: null,
        supported: false,
        client: MockClient((r) async {
          calls.add(r.url.toString());
          return http.Response(jsonEncode(_listing), 200);
        }),
      );
      await v.load();
      return (v, settings, calls);
    }

    test('the voice list is fetched once, cached, and personal-use voices are hidden unless allowed', () async {
      final (v, settings, calls) = await make();
      expect(v.catalog, isNotEmpty, reason: 'starter voices before any download');
      await v.refreshCatalog();
      await v.refreshCatalog();
      expect(calls, hasLength(1));
      expect(v.offered.any((x) => x.personalUseOnly), isFalse);
      await settings.update((s) => s.personalUseVoices = true);
      expect(v.offered.any((x) => x.personalUseOnly), isTrue);
    });

    test('nothing is selected until the engine and the voice are both there', () async {
      final (v, settings, _) = await make();
      await settings.update((s) => s.voiceId = 'donated-0a67');
      expect(v.selected, isNull);
      expect(await v.installVoice(VoiceCatalog.parse(_listing).singleWhere((x) => x.id == 'expressive-ex04')), isFalse);
      await v.installEngine();
      expect(v.engine, EngineStatus.failed);
      expect(v.engineError, contains('Android or iOS'));
    });
  });

  test('voice settings round-trip', () async {
    final store = MemoryJsonStore();
    final a = AppSettings(store);
    await a.update((s) {
      s
        ..voiceId = 'donated-0a67'
        ..expressiveSpeech = false
        ..voiceSpeed = 1.2
        ..personalUseVoices = true;
    });
    final b = AppSettings(store);
    await b.load();
    expect((b.voiceId, b.expressiveSpeech, b.voiceSpeed, b.personalUseVoices), ('donated-0a67', false, 1.2, true));
  });

  testWidgets('the voices page lists voices to listen to, with licences, at phone size', (t) async {
    t.view.physicalSize = const Size(360, 3200);
    t.view.devicePixelRatio = 1;
    addTearDown(t.view.reset);
    final s = (await t.runAsync(
      () => AppServices.create(
        store: MemoryJsonStore(),
        platform: 'demo',
        linkClient: MockClient((r) async => http.Response(jsonEncode(_listing), 200)),
      ),
    ))!;
    await s.settings.update((x) => x.onboarded = true);
    final state = AppState(s);
    await t.pumpWidget(PhoneDotsApp(state: state));
    Navigator.of(t.element(find.byType(Scaffold).first))
        .push(MaterialPageRoute<void>(builder: (_) => const VoicesScreen()));
    for (var i = 0; i < 10; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    expect(find.text('the voice engine'), findsOneWidget);
    expect(find.text('download the engine'), findsOneWidget);
    await t.scrollUntilVisible(find.text('voice 0a67'), 300, scrollable: find.byType(Scrollable).last);
    expect(find.text('voice 0a67'), findsOneWidget);
    expect(find.byTooltip('Listen to voice 0a67'), findsOneWidget);
    expect(find.text('with feelings'), findsNothing);
    await t.scrollUntilVisible(find.text('personal-use voices'), -300, scrollable: find.byType(Scrollable).last);
    await t.tap(find.text('personal-use voices'));
    for (var i = 0; i < 5; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    await t.scrollUntilVisible(find.text('with feelings'), 300, scrollable: find.byType(Scrollable).last);
    expect(find.text('with feelings'), findsOneWidget);
    expect(t.takeException(), isNull);
  });
}
