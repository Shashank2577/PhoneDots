// QA: Dart <-> native contract. Intercepts the six platform channels and
// asserts the exact method names / argument keys Dart sends, then cross-checks
// them against what the Kotlin and Swift bridges read (parsed from source).
// Tests marked `// BUG:` pin down a real mismatch as it exists today, so they
// pass now and must be updated (or flipped) when the bug is fixed.
import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/core/runtime/engine_types.dart';
import 'package:phonedots/core/runtime/platform_engines.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/skills/skill.dart';

const _kt = 'android/app/src/main/kotlin/ai/phonedots/phonedots';

String _src(String path) => File(path).readAsStringSync();

Set<String> _matches(String source, RegExp re, [int group = 1]) => re.allMatches(source).map((m) => m.group(group)!).toSet();

/// Records every call on a channel and answers from [answers].
class _Recorder {
  final calls = <String, List<MethodCall>>{};
  final answers = <String, Object? Function(MethodCall)>{};

  List<MethodCall> on(String channel) => calls[channel] ??= [];

  void install(String channel) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(MethodChannel(channel), (
      call,
    ) async {
      on(channel).add(call);
      return answers[channel]?.call(call);
    });
  }
}

/// A skill context wired to the real services, like agent.dart's _RunContext.
class _Ctx implements SkillContext {
  _Ctx(this.s, [this.atts = const []]);
  final AppServices s;
  final List<Attachment> atts;

  @override
  String get platform => 'android';
  @override
  bool get isDemo => false;
  @override
  List<Attachment> get attachments => atts;
  @override
  Attachment? attachment(Object? ref) => atts.isEmpty ? null : atts.last;
  @override
  Future<Map<String, dynamic>> specialist(String m, String t, Map<String, dynamic> i) => s.specialists.run(m, t, i);
  @override
  Future<Map<String, dynamic>> device(String a, Map<String, dynamic> g) => s.device.invoke(a, g);
  @override
  void progress(String message) {}
  @override
  Future<String?> saveTextFile(String name, String content) async => '/tmp/$name';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// MemoryJsonStore has no model folder, which the native path (ModelManager.pathFor) requires.
class _Store extends MemoryJsonStore {
  @override
  String? get modelsDir => '/nonexistent/models';
  @override
  String? get filesDir => '/nonexistent/files';
}

const _channels = [
  'phonedots/llm',
  'phonedots/specialist',
  'phonedots/device',
  'phonedots/intake',
];

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late _Recorder rec;
  late AppServices services;

  Attachment audio() => const Attachment(id: 'a1', kind: 'audio', path: '/data/shared/memo.m4a', name: 'memo.m4a');
  Attachment image() => const Attachment(id: 'a1', kind: 'image', path: '/data/shared/pic.jpg', name: 'pic.jpg');

  setUp(() async {
    rec = _Recorder();
    rec.answers['phonedots/llm'] = (c) => c.method == 'deviceProfile'
        ? {'platform': 'android', 'totalRamMb': 8000, 'model': 'Pixel', 'soc': 'Tensor', 'gpu': true, 'npu': false}
        : null;
    rec.answers['phonedots/specialist'] = (c) => switch (c.method) {
      'isDownloaded' => false,
      'run' => <String, Object?>{},
      _ => null,
    };
    rec.answers['phonedots/device'] = (c) => <String, Object?>{'ok': true};
    for (final c in _channels) {
      rec.install(c);
    }
    messenger.setMockMethodCallHandler(SystemChannels.platform, (call) async => null);
    services = await AppServices.create(store: _Store(), platform: 'android');
  });

  tearDown(() {
    for (final c in _channels) {
      messenger.setMockMethodCallHandler(MethodChannel(c), null);
    }
  });

  group('startup handshake', () {
    test('Dart registers the intake handler and sends ready once', () {
      final ready = rec.on('phonedots/intake').where((c) => c.method == 'ready').toList();
      expect(ready, hasLength(1));
      expect(rec.on('phonedots/llm').map((c) => c.method), contains('deviceProfile'));
    });

    test('model manager asks the specialist channel isDownloaded with modelId', () {
      final asks = rec.on('phonedots/specialist').where((c) => c.method == 'isDownloaded').toList();
      expect(asks, isNotEmpty);
      for (final c in asks) {
        expect((c.arguments as Map).keys, ['modelId']);
        expect((c.arguments as Map)['modelId'], startsWith('desertant.'));
      }
    });
  });

  group('device actions: Dart skills vs DeviceBridge.kt', () {
    final phoneArgs = <String, Map<String, dynamic>>{
      'set_timer': {'seconds': 90, 'label': 'tea'},
      'set_alarm': {'hour': 6, 'minute': 30},
      'create_event': {'title': 'Sam', 'start': '2026-11-02T15:00', 'end': '2026-11-02T16:00', 'location': 'x', 'notes': 'y'},
      'list_events': {'days': 2},
      'find_contact': {'name': 'Sam'},
      'call_number': {'number': '+15551234'},
      'draft_text_message': {'to': '+15551234', 'body': 'a & b = c'},
      'draft_email': {'to': 'a@b.co', 'subject': 's', 'body': 'b'},
      'open_app': {'name': 'Camera'},
      'open_url': {'url': 'https://example.com'},
      'navigate_to': {'destination': 'Home', 'mode': 'cycling'},
      'toggle_flashlight': {'on': true},
      'open_settings': {'page': 'dnd'},
      'set_volume': {'percent': 40, 'stream': 'ring'},
      'battery_status': <String, dynamic>{},
      'storage_status': <String, dynamic>{},
      'share_text': {'text': 'hi'},
    };

    // The Kotlin `when (action)` branches in DeviceBridge.invoke().
    final kotlinActions = {
      ..._matches(_src('$_kt/DeviceBridge.kt'), RegExp(r'^\s*"([a-z]+(?:\.[a-zA-Z]+)?)"\s*->', multiLine: true)),
      // video.frames is dispatched before the `when` because it runs on a worker thread.
      ..._matches(_src('$_kt/DeviceBridge.kt'), RegExp(r'action == "([a-z.]+)"')),
    };
    final swiftActions = _matches(
      _src('ios/Runner/DeviceBridge.swift'),
      RegExp(r'case ((?:"[a-zA-Z.]+"(?:,\s*)?)+):'),
    ).expand((s) => RegExp(r'"([a-zA-Z.]+)"').allMatches(s).map((m) => m.group(1)!)).toSet();

    test('Kotlin parser found the expected branches (sanity)', () {
      expect(kotlinActions, containsAll(['timer.set', 'torch', 'battery', 'url.open']));
      expect(swiftActions, containsAll(['timer.set', 'torch', 'battery', 'url.open']));
    });

    for (final entry in phoneArgs.entries) {
      test('skill ${entry.key} sends invoke{action,args} and Android handles that action', () async {
        final skill = services.skills.byId(entry.key)!;
        final r = await skill.run(entry.value, _Ctx(services));
        expect(r.isError, isFalse, reason: '${r.data}');
        final dartHandled = {'clipboard.set', 'clipboard.get', 'datetime', 'file.readText'};
        final sent = rec.on('phonedots/device');
        expect(sent, hasLength(1));
        expect(sent.single.method, 'invoke');
        final args = sent.single.arguments as Map;
        expect(args.keys.toSet(), {'action', 'args'});
        final action = args['action'] as String;
        expect(dartHandled.contains(action), isFalse);
        expect(args['args'], entry.value, reason: 'args pass through unchanged');
        expect(kotlinActions, contains(action), reason: 'DeviceBridge.kt has no branch for $action');
      });
    }

    test('argument keys Dart sends are the ones Kotlin reads for each action', () {
      final kt = _src('$_kt/DeviceBridge.kt');
      final read = {
        'timer.set': ['seconds', 'label'],
        'alarm.set': ['hour', 'minute', 'label'],
        'calendar.create': ['title', 'start', 'end', 'location', 'notes'],
        'calendar.list': ['days'],
        'contacts.search': ['name'],
        'phone.dial': ['number'],
        'sms.compose': ['to', 'body'],
        'email.compose': ['to', 'subject', 'body'],
        'app.open': ['name'],
        'url.open': ['url'],
        'maps.navigate': ['destination', 'mode'],
        'torch': ['on'],
        'settings.open': ['page'],
        'volume.set': ['percent', 'stream'],
        'share.text': ['text'],
        'video.frames': ['path', 'frames'],
      };
      for (final keys in read.values) {
        for (final k in keys) {
          expect(RegExp('(str|int)\\("$k"|a\\["$k"\\]').hasMatch(kt), isTrue, reason: 'Kotlin never reads "$k"');
        }
      }
    });

    test('every Dart-handled action never reaches native', () async {
      for (final a in ['clipboard.set', 'clipboard.get', 'datetime']) {
        await services.device.invoke(a, {'text': 'x'});
      }
      expect(rec.on('phonedots/device'), isEmpty);
    });

    test('native error map surfaces as a skill error', () async {
      rec.answers['phonedots/device'] = (_) => {'error': 'No app on this phone can handle that.'};
      final r = await services.skills.byId('open_url')!.run({'url': 'x'}, _Ctx(services));
      expect(r.isError, isTrue);
    });

    test('list_events card reads title/start from the Kotlin events shape', () async {
      rec.answers['phonedots/device'] = (_) => {
        'events': [
          {'title': 'Standup', 'start': '2026-11-02T09:00', 'location': null},
        ],
        'summary': '1 events.',
      };
      final r = await services.skills.byId('list_events')!.run({'days': 1}, _Ctx(services));
      final items = r.cards.single.data['items'] as List;
      expect(items.single, {'time': '2026-11-02 09:00', 'text': 'Standup'});
    });

    // BUG: iOS DeviceBridge.swift has no "video.frames" branch, while Dart
    // (app_services.dart _videoSheet) sends it for every shared audio/video file.
    // On iOS it comes back as {error: Unknown action}, so video shares never get a contact sheet
    // (harmless today only because the iOS bridge never receives shares at all).
    test('BUG: video.frames exists on Android but not on iOS', () {
      expect(kotlinActions, contains('video.frames'));
      expect(swiftActions, isNot(contains('video.frames')));
    });

    // Fixed: find_contact promises "phone numbers and emails"; both platforms now return emails.
    test('contacts.search returns emails on Android and iOS', () {
      expect(_src('ios/Runner/DeviceBridge.swift'), contains('"emails"'));
      expect(_src('$_kt/DeviceBridge.kt'), contains('"emails"'));
      expect(services.skills.byId('find_contact')!.description, contains('emails'));
    });
  });

  group('specialists: Dart skills vs SpecialistBridge.kt', () {
    final kt = _src('$_kt/SpecialistBridge.kt');
    // `"voz" -> Voz(context, dir(k))` lines inside model()
    final androidModels = _matches(kt, RegExp(r'^\s*"([a-z]+)" -> \w+(?:\(|\.bundled)', multiLine: true));
    final availabilityNative = _matches(
      RegExp(r'listOf\(("voz"[^)]*)\)').firstMatch(kt)!.group(1)!,
      RegExp(r'"([a-z]+)"'),
    );

    test('Kotlin parser sanity', () {
      expect(androidModels, containsAll(['voz', 'who', 'ear', 'tongue']));
    });

    // BUG: SpecialistBridge.kt:82 lists "shapes" as `native` in availability and the Dart catalog
    // (model_catalog.dart) marks it android-native, but model() has no "shapes" branch and build.gradle.kts
    // doesn't depend on it. The Models screen offers Shapes on Android; download/run throw
    // "Shapes is not available on Android yet".
    // Fixed: Shapes is iOS-only in the 4.2.1 SDK, so Android no longer advertises it.
    test('every specialist advertised native on Android is implemented', () {
      expect(availabilityNative, isNot(contains('shapes')));
      expect(androidModels, containsAll(availabilityNative));
    });

    final cases = <String, (String, String, Map<String, dynamic>, Attachment?)>{
      'transcribe_audio': ('desertant.voz', 'transcribe', {'audioPath': '/data/shared/memo.m4a'}, null),
      'detect_spoken_language': ('desertant.ear', 'identify', {'audioPath': '/data/shared/memo.m4a'}, null),
      'enhance_speech': ('desertant.clear', 'enhance', {'audioPath': '/data/shared/memo.m4a'}, null),
      'export_subtitles': ('desertant.voz', 'transcribe', {'audioPath': '/data/shared/memo.m4a'}, null),
      'redact_pii': ('desertant.redact', 'redact', {'text': 'hello'}, null),
      'detect_language': ('desertant.tongue', 'detect', {'text': 'hello'}, null),
      'suggest_emoji': ('desertant.emo', 'suggest', {'text': 'hello', 'limit': 5}, null),
      'classify_topics': ('desertant.gist', 'classify', {'text': 'hello'}, null),
      'analyze_photo': ('desertant.eye', 'analyze', {'imagePath': '/data/shared/pic.jpg'}, null),
      'check_image_safety': ('desertant.moderator', 'analyze', {'imagePath': '/data/shared/pic.jpg'}, null),
    };

    cases.forEach((skillId, expected) {
      test('skill $skillId -> run{modelId,task,input}', () async {
        final skill = services.skills.byId(skillId)!;
        final isImage = expected.$3.containsKey('imagePath');
        final args = skill.params.isEmpty ? <String, dynamic>{} : <String, dynamic>{for (final p in skill.params) p.name: p.type == ParamType.attachment ? 'a1' : 'hello'};
        final r = await skill.run(args, _Ctx(services, [isImage ? image() : audio()]));
        final runs = rec.on('phonedots/specialist').where((c) => c.method == 'run').toList();
        expect(runs, isNotEmpty, reason: 'skill returned ${r.data}');
        final a = runs.first.arguments as Map;
        expect(a.keys.toSet(), {'modelId', 'task', 'input'});
        expect(a['modelId'], expected.$1);
        expect(a['task'], expected.$2);
        expect((a['input'] as Map).keys, expected.$3.keys);
        // Kotlin must support the model and read exactly those input keys.
        expect(androidModels, contains((a['modelId'] as String).replaceFirst('desertant.', '')));
        for (final k in (a['input'] as Map).keys) {
          expect(kt, contains('input["$k"]'), reason: 'SpecialistBridge.kt never reads input["$k"]');
        }
      });
    });

    test('Kotlin ignores `task` entirely (model id alone picks the code path)', () {
      expect(RegExp(r'task\b').allMatches(kt.replaceAll(RegExp(r'"task"|task: String'), '')).length, lessThan(4));
    });

    test('every requiresModels id the skills declare is either Android-native or iOS-gated', () {
      final all = services.skills.builtIns;
      for (final s in all) {
        for (final m in s.requiresModels.where((m) => m.startsWith('desertant.'))) {
          final key = m.replaceFirst('desertant.', '');
          final onAndroid = androidModels.contains(key);
          if (!onAndroid) {
            expect(s.platforms, isNotEmpty, reason: '${s.id} needs $m which Android lacks but is not platform-gated');
            expect(s.platforms, isNot(contains('android')), reason: s.id);
          }
        }
      }
    });

    test('specialist result keys consumed by skills match the Kotlin result keys', () async {
      // Redact: Kotlin returns redactedText + items[label,placeholder]
      rec.answers['phonedots/specialist'] = (c) => c.method == 'run'
          ? {
              'redactedText': 'Hi [NAME]',
              'items': [
                {'label': 'NAME', 'original': 'Bob', 'placeholder': '[NAME]', 'confidence': 0.9},
              ],
            }
          : null;
      final r = await services.skills.byId('redact_pii')!.run({'text': 'Hi Bob'}, _Ctx(services));
      expect(r.data['redacted_text'], 'Hi [NAME]');
      expect(r.data['found'], 1);
      expect(kt, contains('"redactedText"'));
      expect(kt, contains('"items"'));
    });

    test('speaker transcript pipeline: Voz words + Who turns (int speakers) merge', () async {
      rec.answers['phonedots/specialist'] = (c) {
        if (c.method != 'run') return null;
        return switch ((c.arguments as Map)['modelId']) {
          'desertant.voz' => {
            'text': 'hello there',
            'duration': 2.0,
            'words': [
              {'text': 'hello', 'start': 0.0, 'end': 0.5},
              {'text': 'there', 'start': 1.0, 'end': 1.5},
              {'text': 'again', 'start': 1.6, 'end': 1.9},
            ],
          },
          'desertant.who' => {
            'speakerCount': 2,
            'duration': 2.0,
            'turns': [
              {'speaker': 0, 'start': 0.0, 'end': 0.8},
              {'speaker': 1, 'start': 0.8, 'end': 2.0},
            ],
          },
          _ => <String, Object?>{},
        };
      };
      final r = await services.skills.byId('transcribe_with_speakers')!.run({'audio': 'a1'}, _Ctx(services, [audio()]));
      expect(r.isError, isFalse, reason: '${r.data}');
      expect(r.data['speakers'], 2);
      final ran = rec.on('phonedots/specialist').where((c) => c.method == 'run').map((c) => (c.arguments as Map)['modelId']);
      expect(ran, ['desertant.voz', 'desertant.who']);
    });

    test('download() sends modelId and forwards {modelId, progress} events', () async {
      final events = <double>[];
      final sinkReady = Completer<MockStreamHandlerEventSink>();
      messenger.setMockStreamHandler(
        const EventChannel('phonedots/specialist/events'),
        MockStreamHandler.inline(onListen: (args, sink) => sinkReady.complete(sink)),
      );
      final done = Completer<void>();
      rec.answers['phonedots/specialist'] = (c) => c.method == 'download' ? Future<void>.delayed(const Duration(milliseconds: 100)) : null;
      final stream = PlatformSpecialistEngine().download('desertant.voz');
      final sub = stream.listen(events.add, onDone: done.complete);
      final sink = await sinkReady.future;
      sink.success({'modelId': 'desertant.who', 'progress': 0.9}); // other model: ignored
      sink.success({'modelId': 'desertant.voz', 'progress': 0.5});
      await done.future;
      await sub.cancel();
      final d = rec.on('phonedots/specialist').lastWhere((c) => c.method == 'download');
      expect(d.arguments, {'modelId': 'desertant.voz'});
      expect(events, [0.5, 1.0]);
    });
  });

  group('LLM channel vs LlmBridge.kt', () {
    final kt = _src('$_kt/LlmBridge.kt');

    test('load sends the keys Kotlin reads', () async {
      await PlatformLlmEngine(nativeTools: true).load(
        modelId: 'gemma',
        path: '/m/g.litertlm',
        backend: ComputeBackend.gpu,
        maxTokens: 2048,
        vision: true,
        audio: true,
      );
      final c = rec.on('phonedots/llm').lastWhere((c) => c.method == 'load');
      expect(c.arguments, {
        'modelId': 'gemma',
        'path': '/m/g.litertlm',
        'backend': 'gpu',
        'maxTokens': 2048,
        'vision': true,
        'audio': true,
      });
      for (final k in (c.arguments as Map).keys) {
        expect(kt, contains('("$k")'), reason: 'LlmBridge.kt never reads "$k"');
      }
    });

    test('embedder load/embed keys', () async {
      final e = PlatformEmbedder();
      await e.load(modelId: 'emb', path: '/m/e.litertlm');
      rec.answers['phonedots/llm'] = (c) => c.method == 'embed' ? [0.1, 0.2] : null;
      expect(await e.embed('hi'), [0.1, 0.2]);
      final calls = rec.on('phonedots/llm');
      expect((calls.lastWhere((c) => c.method == 'loadEmbedder').arguments as Map).keys, ['modelId', 'path', 'dimensions']);
      expect((calls.lastWhere((c) => c.method == 'embed').arguments as Map).keys, ['modelId', 'text']);
      for (final k in ['path', 'dimensions', 'text']) {
        expect(kt, contains('("$k")'));
      }
    });

    test('generate: request keys + event stream decoding (token/thinking/toolCalls/done)', () async {
      final sinkReady = Completer<MockStreamHandlerEventSink>();
      messenger.setMockStreamHandler(
        const EventChannel('phonedots/llm/events'),
        MockStreamHandler.inline(onListen: (args, sink) => sinkReady.complete(sink)),
      );
      final engine = PlatformLlmEngine(nativeTools: true);
      final events = <GenEvent>[];
      final stream = engine.generate(
        GenerationRequest(
          modelId: 'gemma',
          sessionId: 's1',
          systemPrompt: 'sys',
          history: [
            const EngineTurn(role: TurnRole.user, text: 'hi', imagePaths: ['/i.jpg'], audioPaths: ['/a.wav']),
          ],
          tools: [const ToolSpec(name: 't', description: 'd', parameters: {'type': 'object'})],
          thinking: true,
        ),
      );
      final done = Completer<void>();
      stream.listen(events.add, onDone: done.complete);
      final sink = await sinkReady.future;
      await Future<void>.delayed(Duration.zero);

      final gen = rec.on('phonedots/llm').lastWhere((c) => c.method == 'generate').arguments as Map;
      expect(gen.keys.toSet(), {'requestId', 'modelId', 'sessionId', 'history', 'systemPrompt', 'tools', 'thinking', 'sampler'});
      for (final k in gen.keys) {
        expect(kt, contains('("$k")'), reason: 'LlmBridge.kt never reads "$k"');
      }
      expect((gen['history'] as List).single.keys.toSet(), {'role', 'text', 'images', 'audio', 'toolCalls', 'toolResponses'});
      expect((gen['sampler'] as Map).keys.toSet(), {'temperature', 'topK', 'topP', 'maxTokens'});
      for (final k in ['topK', 'topP', 'temperature', 'maxTokens']) {
        expect(kt, contains('sampler["$k"]'));
      }
      final id = gen['requestId'];

      sink.success({'requestId': id, 'type': 'thinking', 'text': 'hmm'});
      sink.success({'requestId': id, 'type': 'token', 'text': 'Hel'});
      sink.success({
        'requestId': id,
        'type': 'toolCalls',
        'calls': [
          {'id': '$id-0', 'name': 'set_timer', 'arguments': {'seconds': 5}},
        ],
      });
      sink.success({
        'requestId': id,
        'type': 'done',
        'stats': {'ttftMs': 10, 'totalMs': 50, 'outputTokens': 3, 'prefillTps': 1.5, 'decodeTps': 20},
      });
      await done.future;
      expect(events.map((e) => e.runtimeType.toString()), ['ThinkingEvent', 'TokenEvent', 'ToolCallsEvent', 'DoneEvent']);
      expect((events[2] as ToolCallsEvent).calls.single.arguments, {'seconds': 5});
    });

    test('cancel + resetSession keys', () async {
      final e = PlatformLlmEngine(nativeTools: true);
      await e.resetSession('s1');
      expect(rec.on('phonedots/llm').last.arguments, {'sessionId': 's1'});
      expect(kt, contains('call.argument<String>("sessionId")'));
      expect(kt, contains('call.argument<String>("requestId")'));
    });

    test('deviceProfile keys parse', () async {
      final p = await PlatformLlmEngine(nativeTools: true).deviceProfile();
      expect(p.platform, 'android');
      expect(p.totalRamMb, 8000);
      for (final k in ['platform', 'totalRamMb', 'model', 'soc', 'gpu', 'npu']) {
        expect(kt, contains('"$k"'));
      }
    });
  });

  group('share intake: native -> Dart', () {
    Future<void> nativeSends(Map<String, Object?> payload) async {
      final codec = const StandardMethodCodec();
      final completer = Completer<void>();
      messenger.handlePlatformMessage(
        'phonedots/intake',
        codec.encodeMethodCall(MethodCall('shared', payload)),
        (_) => completer.complete(),
      );
      await completer.future;
    }

    test('plain text share opens a chat (SharedIntake) and needs no native call', () async {
      await nativeSends({'text': 'remember the milk', 'subject': null, 'files': <Object?>[]});
      expect(services.intake.value?.text, 'remember the milk');
      expect(rec.on('phonedots/device'), isEmpty);
    });

    test('video share: Dart asks video.frames then voz transcribe on the copied file', () async {
      await nativeSends({
        'text': '',
        'subject': null,
        'files': [
          {'path': '/data/files/shared/1-clip.mp4', 'name': 'clip.mp4', 'mime': 'video/mp4'},
        ],
      });
      // summarisation is queued; give the (unawaited) queue a few turns
      for (var i = 0; i < 50 && rec.on('phonedots/specialist').where((c) => c.method == 'run').isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      final frames = rec.on('phonedots/device').where((c) => (c.arguments as Map)['action'] == 'video.frames').toList();
      expect(frames, isNotEmpty, reason: 'video kind is mapped to "audio" and should trigger the contact sheet');
      expect(frames.first.arguments, {
        'action': 'video.frames',
        'args': {'path': '/data/files/shared/1-clip.mp4', 'frames': 6},
      });
      final run = rec.on('phonedots/specialist').firstWhere((c) => c.method == 'run');
      expect(run.arguments, {
        'modelId': 'desertant.voz',
        'task': 'transcribe',
        'input': {'audioPath': '/data/files/shared/1-clip.mp4'},
      });
    });

    test('intake payload keys: Kotlin sends text/subject/files[path,name,mime] and Dart reads exactly these', () {
      final kt = _src('$_kt/MainActivity.kt');
      for (final k in ['"text" to', '"subject" to', '"files" to', '"path" to', '"name" to', '"mime" to']) {
        expect(kt, contains(k));
      }
    });

    // BUG: MainActivity.handleShare() stores a single `pendingShare` and overwrites it, so two
    // shares that arrive before Dart sends `ready` (cold start + quick second share, or
    // onNewIntent during startup) lose the first one. It also copies files on the main thread
    // (see report) - not demonstrable from Dart.
    // Fixed: shares wait in a queue until Dart is ready, files are copied off the UI thread,
    // and a share re-delivered from Recents is skipped.
    test('native queues shares, copies off the UI thread and skips replays', () {
      final kt = _src('$_kt/MainActivity.kt');
      expect(kt, contains('pendingShares'));
      expect(kt, isNot(contains('private var pendingShare:')));
      expect(kt, contains('Thread {'));
      expect(kt, contains('FLAG_ACTIVITY_LAUNCHED_FROM_HISTORY'));
    });

    // BUG: iOS has no share intake at all (AppDelegate answers `ready` and never calls `shared`),
    // and Info.plist declares no share extension, so "share to PhoneDots" does not exist on iOS.
    test('BUG: iOS intake is a stub', () {
      expect(_src('ios/Runner/AppDelegate.swift'), contains('result(nil)'));
      expect(_src('ios/Runner/AppDelegate.swift'), isNot(contains('"shared"')));
    });
  });

  group('channel names', () {
    test('Dart channel names equal Kotlin and Swift registrations', () {
      final names = {
        Channels.llm.name,
        Channels.llmEvents.name,
        Channels.specialist.name,
        Channels.specialistEvents.name,
        Channels.device.name,
        Channels.intake.name,
      };
      final native = [
        ...Directory(_kt).listSync().whereType<File>().map((f) => f.readAsStringSync()),
        ...Directory('ios/Runner').listSync().whereType<File>().where((f) => f.path.endsWith('.swift')).map((f) => f.readAsStringSync()),
      ].join('\n');
      for (final n in names) {
        expect(native, contains('"$n"'), reason: 'no native side registers $n');
      }
    });
  });

  group('manifest vs behaviour', () {
    final manifest = _src('android/app/src/main/AndroidManifest.xml');

    test('permissions required by DeviceBridge actions are declared', () {
      for (final p in ['READ_CALENDAR', 'READ_CONTACTS', 'SET_ALARM', 'RECORD_AUDIO']) {
        expect(manifest, contains(p));
      }
    });

    test('share filters cover text, image, audio, video for SEND and SEND_MULTIPLE', () {
      for (final t in ['text/plain', 'image/*', 'audio/*', 'video/*']) {
        expect(manifest, contains('android:mimeType="$t"'));
      }
      expect(manifest, contains('android.intent.action.SEND_MULTIPLE'));
    });

    // BUG (low): no application/pdf (or other document) filter although Dart has a 'document'
    // attachment kind and a file.readText action, so PDFs/text files cannot be shared in.
    test('BUG: documents (pdf, text/*) cannot be shared in', () {
      expect(manifest, isNot(contains('application/pdf')));
    });

    // BUG (likely): launchMode=singleTop + taskAffinity="" means a share from another app
    // starts a NEW MainActivity (second FlutterEngine, second LlmBridge, second Gemma load)
    // in the sender's task instead of delivering onNewIntent to the running one.
    // Fixed: singleTask, so a share reuses the running activity (one engine, one Gemma load).
    test('share target is singleTask', () {
      expect(manifest, contains('android:launchMode="singleTask"'));
    });
  });
}
