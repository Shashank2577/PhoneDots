import 'dart:async';
import 'dart:math';

import 'engine_types.dart';
import 'engines.dart';

/// Stand-in engines used where no native runtime exists (web preview,
/// desktop, tests). They keep the whole app explorable and are always shown
/// as "Demo" in the UI; they never pretend to be a model.
class DemoLlmEngine implements LlmEngine {
  final Set<String> _loaded = {};
  bool _cancelled = false;

  @override
  bool get supportsNativeTools => true;

  @override
  bool get isDemo => true;

  @override
  Future<void> load({
    required String modelId,
    required String path,
    ComputeBackend backend = ComputeBackend.gpu,
    int maxTokens = 4096,
    bool vision = false,
    bool audio = false,
  }) async {
    await Future<void>.delayed(const Duration(milliseconds: 300));
    _loaded.add(modelId);
  }

  @override
  Future<void> unload(String modelId) async => _loaded.remove(modelId);

  @override
  bool isLoaded(String modelId) => _loaded.contains(modelId);

  @override
  Future<void> cancel() async => _cancelled = true;

  @override
  Future<void> resetSession(String sessionId) async {}

  @override
  Future<DeviceProfile> deviceProfile() async =>
      const DeviceProfile(platform: 'demo', totalRamMb: 8192, model: 'Demo device', isNative: false);

  @override
  Stream<GenEvent> generate(GenerationRequest request) async* {
    _cancelled = false;
    final started = DateTime.now();
    final last = request.history.last;

    if (last.role == TurnRole.user && request.tools.isNotEmpty) {
      final call = DemoIntents.match(
        last.text,
        request.tools.map((t) => t.name).toSet(),
        hasImage: last.imagePaths.isNotEmpty,
        hasAudio: last.audioPaths.isNotEmpty,
      );
      if (call != null) {
        await Future<void>.delayed(const Duration(milliseconds: 250));
        yield ToolCallsEvent([call]);
        yield DoneEvent(GenerationStats(totalMs: DateTime.now().difference(started).inMilliseconds));
        return;
      }
    }

    if (request.thinking) {
      yield const ThinkingEvent('Demo engine: no reasoning model is loaded, so this is a scripted reply.');
    }

    final reply = last.role == TurnRole.tool ? _summariseTools(last.toolResponses) : _reply(request, last);
    var tokens = 0;
    for (final word in reply.split(RegExp(r'(?<= )'))) {
      if (_cancelled) break;
      await Future<void>.delayed(const Duration(milliseconds: 12));
      tokens++;
      yield TokenEvent(word);
    }
    final total = DateTime.now().difference(started).inMilliseconds;
    yield DoneEvent(GenerationStats(timeToFirstTokenMs: 12, totalMs: total, outputTokens: tokens));
  }

  String _summariseTools(List<ToolResponse> responses) {
    final parts = <String>[];
    for (final r in responses) {
      final summary = r.response['summary'] ?? r.response['message'] ?? r.response['error'];
      parts.add(
        summary != null
            ? '$summary'
            : r.response['shown'] == true
            ? 'Here you go.'
            : 'Done.',
      );
    }
    return parts.join('\n\n');
  }

  String _reply(GenerationRequest request, EngineTurn last) {
    final text = last.text.trim();
    final system = request.systemPrompt.toLowerCase();
    // Sub-calls from text skills (summarize, rewrite...) carry the task in the
    // system prompt. Answer them extractively so pipelines still produce output.
    if (system.contains('summar') || system.contains('minutes')) return _extractive(text, 3);
    if (system.contains('json')) return '{"note": "Demo engine cannot extract fields. Load Gemma on a phone."}';
    if (system.contains('rewrite') || system.contains('proofread') || system.contains('translate')) {
      return text;
    }
    if (last.imagePaths.isNotEmpty) {
      return 'I received your image. On a phone with Gemma 4 loaded I would describe it here. '
          'This preview runs the demo engine, which cannot see images.';
    }
    return 'This is the demo engine, so I cannot reason about "${_clip(text, 60)}" yet.\n\n'
        'Install the app on a phone and download **Gemma 4 E2B** from Models to chat for real. '
        'Skills still run here: try "set a timer for 5 minutes", "redact my email bob@acme.com", '
        'or "what is 18% of 2450".';
  }

  static String _clip(String s, int n) => s.length <= n ? s : '${s.substring(0, n)}…';

  static String _extractive(String text, int sentences) {
    final parts = text.split(RegExp(r'(?<=[.!?])\s+')).where((s) => s.trim().isNotEmpty).toList();
    if (parts.isEmpty) return text;
    return parts.take(sentences).map((s) => '- ${s.trim()}').join('\n');
  }
}

/// Keyword routing used only by the demo engine to exercise the tool loop.
class DemoIntents {
  static ToolCallRequest? match(String text, Set<String> tools, {bool hasImage = false, bool hasAudio = false}) {
    final t = text.toLowerCase();
    ToolCallRequest call(String name, [Map<String, dynamic> args = const {}]) =>
        ToolCallRequest(id: 'demo-${Random().nextInt(1 << 20)}', name: name, arguments: args);
    bool has(String name) => tools.contains(name);

    if (hasAudio && has('meeting_minutes') && (t.contains('minute') || t.contains('meeting'))) {
      return call('meeting_minutes', {'audio': 'a1'});
    }
    if (hasAudio && has('transcribe_audio')) return call('transcribe_audio', {'audio': 'a1'});
    if (hasImage && has('analyze_photo') && (t.contains('tag') || t.contains('quality'))) {
      return call('analyze_photo', {'image': 'a1'});
    }
    final timer = RegExp(r'(\d+)\s*(second|sec|minute|min|hour|hr)').firstMatch(t);
    if (timer != null && has('set_timer') && t.contains('timer')) {
      final n = int.parse(timer.group(1)!);
      final unit = timer.group(2)!;
      final seconds = unit.startsWith('h')
          ? n * 3600
          : unit.startsWith('m')
          ? n * 60
          : n;
      return call('set_timer', {'seconds': seconds, 'label': 'Timer'});
    }
    if ((t.contains('flashlight') || t.contains('torch')) && has('toggle_flashlight')) {
      return call('toggle_flashlight', {'on': !t.contains('off')});
    }
    if (t.contains('redact') && has('redact_pii')) {
      return call('redact_pii', {'text': text.replaceFirst(RegExp(r'^redact( my)?:?\s*', caseSensitive: false), '')});
    }
    final math = RegExp(r'([\d.]+)\s*%\s*of\s*([\d.,]+)').firstMatch(t);
    if (math != null && has('calculate')) {
      return call('calculate', {'expression': '${math.group(1)}/100*${math.group(2)!.replaceAll(',', '')}'});
    }
    final expr = RegExp(r'^(what is|calculate|compute)\s+([\d\s+\-*/().^]+)\??$').firstMatch(t);
    if (expr != null && has('calculate')) return call('calculate', {'expression': expr.group(2)!.trim()});
    final conv = RegExp(r'([\d.]+)\s*([a-z°]+)\s+(?:to|in)\s+([a-z°]+)').firstMatch(t);
    if (conv != null && has('convert_units') && (t.startsWith('convert') || t.contains(' to '))) {
      return call('convert_units', {
        'value': double.parse(conv.group(1)!),
        'from': conv.group(2)!,
        'to': conv.group(3)!,
      });
    }
    if ((t.contains('what time') || t.contains("today's date") || t.contains('what day')) && has('get_datetime')) {
      return call('get_datetime');
    }
    if (t.startsWith('remember') && has('remember_fact')) {
      return call('remember_fact', {
        'fact': text.replaceFirst(RegExp(r'^remember( that)?\s*', caseSensitive: false), ''),
      });
    }
    if ((t.contains('what do you know about me') || t.contains('my memories')) && has('recall_memory')) {
      return call('recall_memory', {'query': text});
    }
    if ((t.contains('search my') || t.contains('in my files') || t.contains('my notes')) && has('search_my_files')) {
      return call('search_my_files', {'query': text});
    }
    if (t.contains('emoji') && has('suggest_emoji')) return call('suggest_emoji', {'text': text});
    if (t.contains('battery') && has('battery_status')) return call('battery_status');
    if (t.contains('checklist') && has('show_checklist')) {
      return call('show_checklist', {
        'title': 'Checklist',
        'items': ['First step', 'Second step', 'Third step'],
      });
    }
    return null;
  }
}

/// Hashed bag-of-words vectors. A genuine offline fallback for search when
/// EmbeddingGemma is not downloaded: lexical, not semantic.
class LexicalEmbedder implements Embedder {
  @override
  bool get isDemo => true;

  @override
  int get dimensions => 256;

  @override
  bool get isReady => true;

  @override
  Future<void> load({required String modelId, required String path}) async {}

  @override
  Future<List<double>> embed(String text) async {
    final v = List<double>.filled(dimensions, 0);
    final words = text.toLowerCase().split(RegExp(r'[^a-z0-9]+')).where((w) => w.length > 1);
    for (final w in words) {
      final stem = w.length > 4 ? w.substring(0, w.length - (w.endsWith('s') ? 1 : 0)) : w;
      var h = 2166136261;
      for (final c in stem.codeUnits) {
        h = ((h ^ c) * 16777619) & 0xffffffff;
      }
      v[h % dimensions] += 1;
    }
    final norm = sqrt(v.fold<double>(0, (a, b) => a + b * b));
    return norm == 0 ? v : v.map((x) => x / norm).toList();
  }
}

class DemoSpecialistEngine implements SpecialistEngine {
  final Set<String> _downloaded = {};

  @override
  bool get isDemo => true;

  @override
  Future<Map<String, String>> availability() async => {};

  @override
  Future<bool> isDownloaded(String modelId) async => _downloaded.contains(modelId);

  @override
  Stream<double> download(String modelId) async* {
    for (var i = 1; i <= 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      yield i / 10;
    }
    _downloaded.add(modelId);
  }

  @override
  Future<Map<String, dynamic>> run(String modelId, String task, Map<String, dynamic> input) async {
    await Future<void>.delayed(const Duration(milliseconds: 400));
    final result = _sample(modelId, input);
    return {...result, 'demo': true};
  }

  Map<String, dynamic> _sample(String modelId, Map<String, dynamic> input) {
    switch (modelId) {
      case 'desertant.voz':
        return {
          'text':
              'Okay, let us start. The launch moves to Thursday. Priya will update the deck '
              'and Sam books the venue by Monday. Any questions? No, great.',
          'duration': 14.2,
          'words': [
            {'text': 'Okay,', 'start': 0.0, 'end': 0.4},
            {'text': 'let', 'start': 0.5, 'end': 0.6},
          ],
        };
      case 'desertant.who':
        return {
          'speakerCount': 2,
          'turns': [
            {'speaker': 0, 'start': 0.0, 'end': 7.8},
            {'speaker': 1, 'start': 7.9, 'end': 12.1},
            {'speaker': 0, 'start': 12.2, 'end': 14.2},
          ],
        };
      case 'desertant.ear':
        return {'language': 'en', 'confidence': 0.97, 'isReliable': true};
      case 'desertant.tongue':
        return {'language': 'en', 'confidence': 0.9, 'isTooCloseToCall': false};
      case 'desertant.emo':
        return {
          'suggestions': [
            {'emoji': '✨', 'confidence': 0.6},
            {'emoji': '🎉', 'confidence': 0.3},
          ],
        };
      case 'desertant.gist':
        return {
          'topics': [
            {'slug': 'technology', 'name': 'Technology & Software', 'score': 0.82},
          ],
        };
      case 'desertant.eye':
        return {
          'kind': 'photo',
          'tags': ['photo', 'outdoor', 'people'],
          'aesthetic': 0.74,
          'faces': 2,
        };
      case 'desertant.moderator':
        return {'isNSFW': false, 'score': 0.02};
      case 'desertant.clear':
        return {'outputPath': input['audioPath'], 'measuredLufs': -16.0};
      case 'desertant.redact':
        return _regexRedact(input['text'] as String? ?? '');
      default:
        return {'error': 'Demo engine has no sample for $modelId'};
    }
  }

  static Map<String, dynamic> _regexRedact(String text) {
    final patterns = {
      'EMAIL': RegExp(r'[\w.+-]+@[\w-]+\.[\w.]+'),
      'PHONE': RegExp(r'\+?\d[\d\s().-]{7,}\d'),
      'CARD': RegExp(r'\b(?:\d[ -]?){13,16}\b'),
    };
    final items = <Map<String, dynamic>>[];
    var out = text;
    patterns.forEach((label, re) {
      var i = 0;
      out = out.replaceAllMapped(re, (m) {
        i++;
        final placeholder = '[${label}_$i]';
        items.add({'label': label, 'original': m.group(0), 'placeholder': placeholder, 'confidence': 1.0});
        return placeholder;
      });
    });
    return {'redactedText': out, 'items': items};
  }
}

class DemoDeviceActions implements DeviceActions {
  @override
  bool get isDemo => true;

  @override
  Future<Map<String, dynamic>> invoke(String action, Map<String, dynamic> args) async {
    await Future<void>.delayed(const Duration(milliseconds: 150));
    switch (action) {
      case 'battery':
        return {'level': 82, 'charging': false, 'demo': true};
      case 'contacts.search':
        return {
          'contacts': [
            {'name': 'Sam Rivera', 'phone': '+1 555 0100'},
          ],
          'demo': true,
        };
      case 'calendar.list':
        return {
          'events': [
            {'title': 'Design review', 'start': DateTime.now().add(const Duration(hours: 2)).toIso8601String()},
          ],
          'demo': true,
        };
      default:
        return {'ok': true, 'demo': true, 'message': 'Demo: would run "$action" on a phone.'};
    }
  }
}
