// QA suite for skills, recipes, community skills and the util libraries.
// Tests marked `// BUG:` assert the behaviour a user/model would reasonably
// expect; they are expected to fail until the app is fixed.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:phonedots/agent/agent.dart';
import 'package:phonedots/agent/conversation.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/app_state.dart';
import 'package:phonedots/core/models/model_catalog.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/core/util/calculator.dart';
import 'package:phonedots/core/util/format.dart';
import 'package:phonedots/core/util/units.dart';
import 'package:phonedots/features/chat/cards.dart';
import 'package:phonedots/features/skills/skills_screen.dart';
import 'package:phonedots/skills/community/community_skill.dart';
import 'package:phonedots/skills/recipes/recipe.dart';
import 'package:phonedots/skills/skill.dart';
import 'package:phonedots/skills/skill_registry.dart';
import 'package:phonedots/theme/theme.dart';
import 'package:phonedots/widgets/hand.dart';

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

class _DirStore extends MemoryJsonStore {
  _DirStore(this.dir);
  final String dir;
  @override
  String? get filesDir => dir;
}

late Directory _tmp;

Future<AppServices> _services({MemoryJsonStore? store, String platform = 'demo'}) => AppServices.create(
  store: store ?? _DirStore(_tmp.path),
  platform: platform,
  linkClient: MockClient(
    (r) async => http.Response(
      '<html><head><title>Example page</title><meta property="og:description" content="Desc"/></head></html>',
      200,
      headers: {'content-type': 'text/html'},
    ),
  ),
);

const _audio = Attachment(id: 'a1', kind: 'audio', path: '/nonexistent/qa.wav', name: 'qa.wav');
const _image = Attachment(id: 'a2', kind: 'image', path: '/nonexistent/qa.png', name: 'qa.png');
const _image2 = Attachment(id: 'a3', kind: 'image', path: '/nonexistent/qb.png', name: 'qb.png');
const _doc = Attachment(id: 'a4', kind: 'document', path: '/nonexistent/qa.txt', name: 'qa.txt');

typedef _DeviceFn = Future<Map<String, dynamic>> Function(String action, Map<String, dynamic> args);

/// A SkillContext backed by the demo services, mirroring the agent's context
/// so skills can be run directly (the agent swallows thrown errors).
class _Ctx implements SkillContext {
  _Ctx(this.s, {this.atts = const [], this.deviceFn});
  final AppServices s;
  final List<Attachment> atts;
  final _DeviceFn? deviceFn;
  final List<String> log = [];
  final List<(String, Map<String, dynamic>)> deviceCalls = [];
  int depth = 0;
  int maxDepth = 0;

  @override
  String get platform => s.platform;
  @override
  bool get isDemo => deviceFn == null ? s.isDemo : false;
  @override
  List<Attachment> get attachments => atts;

  @override
  Attachment? attachment(Object? ref) {
    if (atts.isEmpty) return null;
    final r = '${ref ?? ''}'.trim();
    for (final a in atts.reversed) {
      if (a.id == r || a.name == r || a.path == r) return a;
    }
    return r.isEmpty || atts.length == 1 ? atts.last : null;
  }

  @override
  Future<String> ask({
    required String system,
    required String prompt,
    List<String> imagePaths = const [],
    List<String> audioPaths = const [],
  }) => s.ask(system: system, prompt: prompt, imagePaths: imagePaths, audioPaths: audioPaths);

  @override
  Future<Map<String, dynamic>> specialist(String modelId, String task, Map<String, dynamic> input) =>
      s.specialists.run(modelId, task, input);

  @override
  Future<Map<String, dynamic>> device(String action, Map<String, dynamic> args) {
    deviceCalls.add((action, args));
    return deviceFn != null ? deviceFn!(action, args) : s.device.invoke(action, args);
  }

  @override
  Future<List<Map<String, dynamic>>> searchKnowledge(String query, {int limit = 5}) =>
      s.knowledge.search(query, limit: limit);
  @override
  Future<int> addKnowledge(String title, String text, {String source = 'chat'}) =>
      s.knowledge.add(title, text, source: source);
  @override
  Future<void> remember(String fact) => s.memory.add(fact);
  @override
  Future<List<String>> recall(String query) async => s.memory.recall(query);
  @override
  Future<bool> forget(String fact) => s.memory.forget(fact);

  @override
  Future<SkillResult> callSkill(String id, Map<String, dynamic> args) async {
    final k = s.skills.byId(id);
    if (k == null) return SkillResult.error('No skill $id');
    depth++;
    if (depth > maxDepth) maxDepth = depth;
    try {
      if (depth > 30) return SkillResult.error('QA depth guard tripped');
      return await k.run(args, this);
    } finally {
      depth--;
    }
  }

  @override
  Future<String?> saveTextFile(String name, String content) async {
    final dir = s.store.filesDir;
    if (dir == null) return null;
    final f = File('$dir/${name.replaceAll(RegExp(r'[/\\:]'), '_')}');
    await f.writeAsString(content);
    return f.path;
  }

  @override
  Future<Map<String, dynamic>> previewLink(String url) async {
    final p = await s.links.preview(url);
    return {...p.toJson(), 'rich': p.rich};
  }

  @override
  void progress(String message) => log.add(message);
}

Future<SkillResult> _run(
  AppServices s,
  Skill k,
  Map<String, dynamic> args, {
  List<Attachment> atts = const [],
  _DeviceFn? deviceFn,
}) => k.run(args, _Ctx(s, atts: atts, deviceFn: deviceFn)).timeout(const Duration(seconds: 30));

/// Sensible arguments for every built-in skill.
final Map<String, Map<String, dynamic>> _sensible = {
  'transcribe_audio': {'audio': 'a1'},
  'transcribe_with_speakers': {'audio': 'a1'},
  'meeting_minutes': {'audio': 'a1'},
  'detect_spoken_language': {'audio': 'a1'},
  'enhance_speech': {'audio': 'a1'},
  'find_filler_words': {'audio': 'a1'},
  'export_subtitles': {'audio': 'a1'},
  'describe_image': {'image': 'a2', 'question': 'What is in this photo?'},
  'read_text_in_image': {'image': 'a2'},
  'analyze_photo': {'image': 'a2'},
  'pick_best_photo': {},
  'check_image_safety': {'image': 'a2'},
  'receipt_to_expense': {'image': 'a2'},
  'summarize': {'text': 'The launch moved to Thursday. Priya updates the deck. Sam books the venue. Done.'},
  'rewrite': {'text': 'hey send me the file', 'tone': 'formal'},
  'translate': {'text': 'Good morning', 'language': 'Spanish'},
  'proofread': {'text': 'Ths is a tset.'},
  'draft_reply': {'text': 'Can we meet Friday?', 'instructions': 'Say yes.'},
  'check_tone': {'text': 'Do it now or else.'},
  'extract_fields': {
    'text': 'Invoice from ACME dated 2026-01-02 for 40 USD',
    'fields': ['vendor', 'date', 'amount'],
  },
  'redact_pii': {'text': 'Mail bob@acme.com or call +1 555 123 4567'},
  'detect_language': {'text': 'Bonjour tout le monde'},
  'suggest_emoji': {'text': 'We shipped it!'},
  'classify_topics': {'text': 'New phone chips are faster'},
  'suggest_title': {'text': 'A long passage about gardening in small spaces.'},
  'set_timer': {'seconds': 300, 'label': 'tea'},
  'set_alarm': {'hour': 6, 'minute': 30},
  'create_event': {'title': 'Dentist', 'start': '2026-11-02T15:00'},
  'list_events': {'days': 2},
  'find_contact': {'name': 'Sam'},
  'call_number': {'number': '+1 555 0100'},
  'draft_text_message': {'to': '+1 555 0100', 'body': 'On my way'},
  'draft_email': {'to': 'a@b.com', 'subject': 'Hi', 'body': 'Hello'},
  'open_app': {'name': 'Camera'},
  'open_url': {'url': 'https://example.com'},
  'navigate_to': {'destination': 'Central Park', 'mode': 'walking'},
  'toggle_flashlight': {'on': true},
  'open_settings': {'page': 'wifi'},
  'set_volume': {'percent': 50, 'stream': 'media'},
  'battery_status': {},
  'storage_status': {},
  'share_text': {'text': 'hello'},
  'copy_to_clipboard': {'text': 'hello'},
  'read_clipboard': {},
  'get_datetime': {},
  'search_my_files': {'query': 'deposit'},
  'add_to_knowledge': {'title': 'Note', 'text': 'The deposit is 1200 dollars.'},
  'remember_fact': {'fact': 'Is vegetarian'},
  'recall_memory': {'query': 'food'},
  'forget_memory': {'fact': 'Is vegetarian'},
  'calculate': {'expression': '(1200*0.18)+45'},
  'convert_units': {'value': 5, 'from': 'miles', 'to': 'km'},
  'date_calc': {'start': '2026-10-31', 'add_days': 7},
  'read_link': {'url': 'https://example.com/page'},
  'show_table': {
    'title': 'T',
    'columns': ['A', 'B'],
    'rows': ['1 | 2', '3 | 4'],
  },
  'show_checklist': {
    'title': 'C',
    'items': ['one', 'two'],
  },
  'show_chart': {
    'title': 'Ch',
    'labels': ['x', 'y'],
    'values': ['1', '2'],
  },
  'show_timeline': {
    'title': 'Tl',
    'items': ['9:00 — Standup', '10:00 - Review'],
  },
  'save_note': {'title': 'My note', 'content': '# Hello\nbody'},
};

/// Demo engines have no sample for these, so an error result is expected.
const _demoLimited = {'find_filler_words'};

final List<List<Attachment>> _attSets = [
  const [],
  const [_image],
  const [_audio],
  const [_audio, _image, _image2, _doc],
  const [_doc],
];

Map<String, dynamic> _fillAll(Skill k, Object? v) => {for (final p in k.params) p.name: v};

List<Map<String, dynamic>> _garbageArgs(Skill k) => [
  {},
  _fillAll(k, ''),
  _fillAll(k, 12345),
  _fillAll(k, -1),
  _fillAll(k, null),
  _fillAll(k, true),
  _fillAll(k, ['a', 'b']),
  _fillAll(k, {'x': 1}),
  _fillAll(k, 'x' * 50000),
  _fillAll(k, '\u0000😀\n\t"\'<>{{prev.x}}'),
  _fillAll(k, 1 << 62),
  _fillAll(k, 1e300),
  _fillAll(k, 'zzz'),
  {'unexpected': 'key'},
];

bool _looksLikeRawException(String s) =>
    RegExp(r"(Exception|Error:|type '|is not a subtype|NoSuchMethod|Null check|RangeError|StateError)").hasMatch(s);

Future<List<(String, UiCard)>> _collectCards(AppServices s) async {
  final out = <(String, UiCard)>[];
  for (final k in s.skills.builtIns) {
    final sets = [
      const <Attachment>[],
      const [_audio, _image, _image2, _doc],
    ];
    final variants = [_sensible[k.id] ?? {}, ..._garbageArgs(k)];
    for (final atts in sets) {
      for (final (i, a) in variants.indexed) {
        try {
          final r = await _run(s, k, a, atts: atts);
          for (final c in r.cards) {
            out.add(('${k.id}#$i', c));
          }
        } catch (_) {
          // Throws are reported by the robustness tests, not here.
        }
      }
    }
  }
  return out;
}

Widget _host(AppState state, Widget child, {Brightness b = Brightness.light, double textScale = 1}) => AppScope(
  state: state,
  child: MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: buildTheme(b),
    builder: (c, w) => MediaQuery(
      data: MediaQuery.of(c).copyWith(textScaler: TextScaler.linear(textScale)),
      child: w!,
    ),
    home: Scaffold(
      body: SingleChildScrollView(
        child: Padding(padding: const EdgeInsets.all(16), child: child),
      ),
    ),
  ),
);

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 4; i++) {
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _pumpScreen(WidgetTester tester, AppState state) async {
  await tester.pumpWidget(
    AppScope(
      state: state,
      child: MaterialApp(theme: buildTheme(Brightness.light), home: const SkillsScreen()),
    ),
  );
  await _settle(tester);
}

/// Scrolls the top-most list until [f] is on screen.
Future<void> _reveal(WidgetTester tester, Finder f) async {
  if (f.evaluate().isNotEmpty) return;
  final scrollable = find.descendant(of: find.byType(ListView).last, matching: find.byType(Scrollable)).first;
  await tester.scrollUntilVisible(f, 120, scrollable: scrollable, maxScrolls: 300);
  await _settle(tester);
}

/// Works around the stale-list bug: leaves and re-enters a segment so it rebuilds.
Future<void> _refreshSegment(WidgetTester tester, String segment) async {
  await tester.tap(find.widgetWithText(ChoicePill, 'skills'));
  await _settle(tester);
  await tester.tap(find.widgetWithText(ChoicePill, segment));
  await _settle(tester);
}

Future<void> _enter(WidgetTester tester, String hint, String text) async {
  final f = find.widgetWithText(TextField, hint);
  await _reveal(tester, f);
  await tester.enterText(f, text);
}

/// Filters the skill list with the search box, then opens the skill's sheet.
Future<void> _openSkill(WidgetTester tester, String name) async {
  await tester.enterText(find.widgetWithText(TextField, 'search every skill…'), name);
  await _settle(tester);
  await tester.tap(find.widgetWithText(SkillTile, name));
  await _settle(tester);
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 690);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() => _tmp = Directory.systemTemp.createTempSync('qa_skills'));
  tearDownAll(() {
    try {
      _tmp.deleteSync(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') return {'text': 'clip text'};
        return null;
      },
    );
  });

  // -------------------------------------------------------------------------
  group('metadata', () {
    test('catalog size, unique ids, id format', () async {
      final s = await _services();
      final ids = s.skills.all.map((k) => k.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'duplicate ids');
      expect(s.skills.builtIns.length, 59);
      for (final k in s.skills.all) {
        expect(RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(k.id), isTrue, reason: k.id);
        expect(k.name.trim(), isNotEmpty, reason: k.id);
        expect(k.description.trim(), isNotEmpty, reason: k.id);
      }
    });

    test('every built-in has a sensible-args entry (guards new skills)', () async {
      final s = await _services();
      final missing = s.skills.builtIns.map((k) => k.id).where((id) => !_sensible.containsKey(id)).toList();
      expect(missing, isEmpty);
      final stale = _sensible.keys.where((id) => s.skills.byId(id) == null).toList();
      expect(stale, isEmpty);
    });

    test('params: described, unique, valid names, valid options', () async {
      final s = await _services();
      final bad = <String>[];
      for (final k in s.skills.all) {
        final names = <String>{};
        for (final p in k.params) {
          if (p.description.trim().isEmpty) bad.add('${k.id}.${p.name}: empty description');
          if (!RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(p.name)) bad.add('${k.id}.${p.name}: bad name');
          if (!names.add(p.name)) bad.add('${k.id}.${p.name}: duplicate');
          if (p.options != null && (p.options!.isEmpty || p.type != ParamType.string)) {
            bad.add('${k.id}.${p.name}: bad options');
          }
        }
      }
      expect(bad, isEmpty);
    });

    test('toolSpec is a valid JSON schema and required subset of properties', () async {
      final s = await _services();
      const types = {'string', 'integer', 'number', 'boolean', 'array', 'object'};
      for (final k in s.skills.all) {
        final spec = k.toToolSpec();
        expect(spec.name, k.id);
        expect(spec.description, k.description);
        final schema = spec.parameters;
        expect(schema['type'], 'object', reason: k.id);
        final props = Map<String, dynamic>.from(schema['properties'] as Map);
        final required = (schema['required'] as List).cast<String>();
        expect(props.keys.toSet().containsAll(required), isTrue, reason: '${k.id} required not in properties');
        expect(required.toSet().length, required.length);
        for (final e in props.entries) {
          final p = Map<String, dynamic>.from(e.value as Map);
          expect(types, contains(p['type']), reason: '${k.id}.${e.key}');
          if (p['type'] == 'array') expect((p['items'] as Map)['type'], isIn(types), reason: '${k.id}.${e.key}');
          expect((p['description'] as String).trim(), isNotEmpty);
          if (p['enum'] != null) {
            expect(p['type'], 'string');
            expect((p['enum'] as List), isNotEmpty);
          }
        }
        // The whole spec must survive JSON encoding (it is sent to the model).
        expect(() => jsonEncode(schema), returnsNormally, reason: k.id);
      }
    });

    test('requiresModels exist in the catalog; platforms are known', () async {
      final s = await _services();
      for (final k in s.skills.builtIns) {
        for (final m in k.requiresModels) {
          expect(modelById(m), isNotNull, reason: '${k.id} requires unknown model $m');
        }
        expect(const {'android', 'ios'}.containsAll(k.platforms), isTrue, reason: k.id);
      }
    });

    test('kind/category agree with the file the skill lives in', () async {
      final s = await _services();
      for (final k in s.skills.builtIns) {
        if (k.category == SkillCategory.phone) expect(k.kind, SkillKind.device, reason: k.id);
        if (k.category == SkillCategory.output && k.id != 'save_note') expect(k.kind, SkillKind.ui, reason: k.id);
        if (k.requiresModels.isNotEmpty) expect(k.kind, SkillKind.model, reason: k.id);
      }
    });

    test('confirmation level for anything that sends, calls or creates', () async {
      final s = await _services();
      ConfirmPolicy c(String id) => s.skills.byId(id)!.confirm;
      expect(c('call_number'), ConfirmPolicy.always);
      expect(c('draft_text_message'), ConfirmPolicy.always);
      expect(c('draft_email'), ConfirmPolicy.always);
      for (final id in ['create_event', 'list_events', 'find_contact', 'read_clipboard', 'open_url']) {
        expect(c(id), isNot(ConfirmPolicy.never), reason: id);
      }
    });

    test('every skill has at least one example', () async {
      // BUG: low. Examples feed the UI ("say") and selectFor ranking; many
      // built-ins have none, so they are only reachable by name.
      final s = await _services();
      final none = s.skills.builtIns.where((k) => k.examples.isEmpty).map((k) => k.id).toList();
      expect(none, isEmpty, reason: '${none.length} skills without examples: $none');
    });

    test('examples are not blank', () async {
      final s = await _services();
      for (final k in s.skills.all) {
        for (final e in k.examples) {
          expect(e.trim(), isNotEmpty, reason: k.id);
        }
      }
    });
  });

  // -------------------------------------------------------------------------
  group('registry', () {
    test('availableHere per platform', () async {
      final store = _DirStore(_tmp.path);
      final s = await _services(store: store);
      final android = SkillRegistry(store: store, settings: s.settings, platform: 'android');
      final ios = SkillRegistry(store: store, settings: s.settings, platform: 'ios');
      final demo = SkillRegistry(store: store, settings: s.settings, platform: 'demo');
      Skill k(SkillRegistry r, String id) => r.builtIns.firstWhere((x) => x.id == id);
      expect(android.availableHere(k(android, 'open_app')), isTrue);
      expect(ios.availableHere(k(ios, 'open_app')), isFalse);
      expect(android.availableHere(k(android, 'set_volume')), isTrue);
      expect(ios.availableHere(k(ios, 'set_volume')), isFalse);
      expect(android.availableHere(k(android, 'find_filler_words')), isFalse);
      expect(ios.availableHere(k(ios, 'find_filler_words')), isTrue);
      expect(demo.availableHere(k(demo, 'find_filler_words')), isTrue);
      expect(ios.availableHere(k(ios, 'calculate')), isTrue);
      await android.load();
      await ios.load();
      expect(android.enabled.any((x) => x.id == 'find_filler_words'), isFalse);
      expect(ios.enabled.any((x) => x.id == 'open_app'), isFalse);
    });

    test('enable/disable persists and filters', () async {
      final store = _DirStore(_tmp.path);
      final s = await _services(store: store);
      final k = s.skills.byId('calculate')!;
      expect(s.skills.isEnabled(k), isTrue);
      await s.skills.setEnabled(k, false);
      expect(s.skills.isEnabled(k), isFalse);
      expect(s.skills.enabled.map((x) => x.id), isNot(contains('calculate')));
      expect(s.skills.selectFor('what is 5 plus 5').map((x) => x.id), isNot(contains('calculate')));
      final again = await _services(store: store);
      expect(again.skills.isEnabled(again.skills.byId('calculate')!), isFalse);
      await again.skills.setEnabled(again.skills.byId('calculate')!, true);
      final third = await _services(store: store);
      expect(third.skills.isEnabled(third.skills.byId('calculate')!), isTrue);
      // idempotent
      await third.skills.setEnabled(third.skills.byId('calculate')!, true);
      expect(third.skills.isEnabled(third.skills.byId('calculate')!), isTrue);
    });

    test('disabled skill is refused by the agent', () async {
      final s = await _services();
      await s.skills.setEnabled(s.skills.byId('calculate')!, false);
      final chat = ChatController(s);
      await chat.runSkill(s.skills.byId('calculate')!, {'expression': '1+1'});
      expect(chat.messages.last.steps.single.status, StepStatus.failed);
    });

    test('byId unknown returns null', () async {
      final s = await _services();
      expect(s.skills.byId('nope'), isNull);
      expect(s.skills.byId(''), isNull);
    });

    test('selectFor picks relevant skills', () async {
      final s = await _services();
      List<String> sel(String t, {List<Attachment> a = const [], int max = 12}) =>
          s.skills.selectFor(t, attachments: a, max: max).map((k) => k.id).toList();
      expect(sel('set a timer for ten minutes').first, 'set_timer');
      expect(sel('transcribe this', a: [_audio]), contains('transcribe_audio'));
      expect(sel("what's in this photo", a: [_image]), contains('describe_image'));
      expect(sel('Read the text on this menu', a: [_image]), contains('read_text_in_image'));
      expect(sel('convert 5 miles to km'), contains('convert_units'));
      expect(sel('translate this to French'), contains('translate'));
      expect(sel('redact my personal info'), contains('redact_pii'));
      expect(sel('wake me up at 6:30'), contains('set_alarm'));
      expect(sel('send an email to Sam'), contains('draft_email'));
      expect(sel('call mom'), contains('call_number'));
      expect(sel('turn on the flashlight'), contains('toggle_flashlight'));
      expect(sel('how much battery is left'), contains('battery_status'));
      expect(sel('make meeting minutes', a: [_audio]), contains('meeting_minutes'));
      expect(sel('navigate to the airport'), contains('navigate_to'));
      expect(sel('what is 15% tip on 80'), contains('calculate'));
      expect(sel('add a dentist appointment to my calendar'), contains('create_event'));
    });

    test('selectFor: max, always-on, empty, unicode, huge input, no dupes', () async {
      final s = await _services();
      expect(s.skills.selectFor('set a timer', max: 3).length, lessThanOrEqualTo(3));
      expect(s.skills.selectFor('set a timer', max: 0), isEmpty);
      final empty = s.skills.selectFor('').map((k) => k.id);
      expect(empty, containsAll(['calculate', 'get_datetime']));
      expect(() => s.skills.selectFor('🙂🙂 ¿qué? 你好'), returnsNormally);
      expect(() => s.skills.selectFor('timer ' * 50000), returnsNormally);
      final r = s.skills.selectFor('timer alarm photo audio').map((k) => k.id).toList();
      expect(r.toSet().length, r.length);
    });

    test('selectFor: vision/audio skills hidden without attachments, shown with', () async {
      final s = await _services();
      final plain = s.skills.selectFor('describe and analyze and transcribe').map((k) => k.category);
      expect(plain, isNot(contains(SkillCategory.audio)));
      final withImg = s.skills.selectFor('analyze this', attachments: [_image]).map((k) => k.category);
      expect(withImg, contains(SkillCategory.vision));
    });

    test('selectFor surfaces an installed recipe and community skill', () async {
      final s = await _services();
      final sk = CommunitySkill.parse(sampleCommunitySkills[2]);
      await s.skills.install(sk);
      expect(s.skills.selectFor('make me a packing list for hiking').map((k) => k.id), contains('c_packing_list'));
      expect(s.skills.selectFor('private share this text').map((k) => k.id), contains('recipe_private_share'));
    });
  });

  // -------------------------------------------------------------------------
  group('every skill: sensible args', () {
    for (final id in _sensible.keys) {
      test(id, () async {
        final s = await _services();
        final k = s.skills.byId(id)!;
        final r = await _run(s, k, _sensible[id]!, atts: const [_audio, _image, _image2, _doc]);
        if (_demoLimited.contains(id)) {
          expect(r.isError, isTrue, reason: 'demo engine has no sample; expect a clear error');
          expect('${r.data['error']}', isNotEmpty);
        } else {
          expect(r.isError, isFalse, reason: '${r.data}');
        }
        // Must persist with the conversation.
        expect(() => jsonEncode(r.data), returnsNormally);
        for (final c in r.cards) {
          expect(() => jsonEncode(c.toJson()), returnsNormally);
          final back = UiCard.fromJson(jsonDecode(jsonEncode(c.toJson())) as Map<String, dynamic>);
          expect(back.type, c.type);
        }
      });
    }
  });

  group('every skill: bad / missing args never throw', () {
    for (final id in _sensible.keys) {
      test(id, () async {
        final s = await _services();
        final k = s.skills.byId(id)!;
        final failures = <String>[];
        final hasAttachment = k.params.any((p) => p.type == ParamType.attachment) || id == 'pick_best_photo';
        final sets = hasAttachment
            ? _attSets
            : [
                const <Attachment>[],
                const [_audio, _image, _image2, _doc],
              ];
        final variants = _garbageArgs(k);
        await Future.wait([
          for (final atts in sets)
            for (final (i, a) in variants.indexed)
              () async {
                try {
                  final r = await _run(s, k, a, atts: atts);
                  if (r.isError && _looksLikeRawException('${r.data['error']}')) {
                    failures.add(
                      'v$i atts=${atts.length}: raw exception text leaked: ${r.data['error']}'.split('\n').first,
                    );
                  }
                } catch (e) {
                  failures.add('v$i atts=${atts.length} args=${_short(a)}: THROWS ${'$e'.split('\n').first}');
                }
              }(),
        ]);
        expect(failures.toSet().toList(), isEmpty);
      });
    }
  });

  group('attachment skills: missing / wrong attachment gives a clear error', () {
    final audioSkills = [
      'transcribe_audio',
      'transcribe_with_speakers',
      'meeting_minutes',
      'detect_spoken_language',
      'enhance_speech',
      'find_filler_words',
      'export_subtitles',
    ];
    final imageSkills = [
      'describe_image',
      'read_text_in_image',
      'analyze_photo',
      'check_image_safety',
      'receipt_to_expense',
    ];
    for (final id in audioSkills) {
      test(id, () async {
        final s = await _services();
        final k = s.skills.byId(id)!;
        for (final atts in [
          const <Attachment>[],
          const [_image],
          const [_doc],
          const [_image, _doc],
        ]) {
          final r = await _run(s, k, {'audio': 'a1'}, atts: atts);
          expect(r.isError, isTrue, reason: 'atts=${atts.map((a) => a.kind)}');
          expect('${r.data['error']}', contains('audio'));
        }
        final r = await _run(s, k, {'audio': 'nonexistent'}, atts: const [_audio, _image]);
        expect(r.isError, isTrue);
      });
    }
    for (final id in imageSkills) {
      test(id, () async {
        final s = await _services();
        final k = s.skills.byId(id)!;
        for (final atts in [
          const <Attachment>[],
          const [_audio],
          const [_doc],
        ]) {
          final r = await _run(s, k, {'image': 'a2'}, atts: atts);
          expect(r.isError, isTrue, reason: 'atts=${atts.map((a) => a.kind)}');
          expect('${r.data['error']}', isNotEmpty);
        }
      });
    }
    test('pick_best_photo needs two photos', () async {
      final s = await _services();
      final k = s.skills.byId('pick_best_photo')!;
      for (final atts in [
        const <Attachment>[],
        const [_image],
        const [_audio, _doc],
      ]) {
        final r = await _run(s, k, {}, atts: atts);
        expect(r.isError, isTrue);
      }
      final ok = await _run(s, k, {}, atts: const [_image, _image2]);
      expect(ok.isError, isFalse);
      expect(ok.data['best'], isIn(['a2', 'a3']));
      expect((ok.data['ranking'] as List), hasLength(2));
    });
    test('single attachment is used when the model omits the id (documented behaviour)', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('analyze_photo')!, {}, atts: const [_image]);
      expect(r.isError, isFalse);
    });
  });

  group('skill behaviour', () {
    test('redact_pii removes email and phone', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('redact_pii')!, _sensible['redact_pii']!);
      expect('${r.data['redacted_text']}', isNot(contains('bob@acme.com')));
      expect(r.data['found'], greaterThanOrEqualTo(2));
      expect(r.cards.map((c) => c.type), containsAll(['text', 'table']));
    });

    test('redact_pii with empty text', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('redact_pii')!, {'text': ''});
      expect(r.isError, isFalse);
      expect(r.data['found'], 0);
    });

    test('redact_pii singular/plural summary', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('redact_pii')!, {'text': 'only bob@acme.com here'});
      expect('${r.data['summary']}', startsWith('Redacted 1 item:'));
    });

    test('export_subtitles writes an .srt', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('export_subtitles')!, {'audio': 'a1'}, atts: const [_audio]);
      expect(r.isError, isFalse);
      final path = r.data['path'] as String?;
      expect(path, isNotNull);
      expect(path, endsWith('.srt'));
      expect(File(path!).readAsStringSync(), contains('-->'));
    });

    test('save_note writes a file and indexes it', () async {
      final s = await _services();
      final before = (await s.knowledge.search('Hello body')).length;
      final r = await _run(s, s.skills.byId('save_note')!, _sensible['save_note']!);
      expect(File(r.data['path'] as String).readAsStringSync(), contains('Hello'));
      expect((await s.knowledge.search('Hello body')).length, greaterThanOrEqualTo(before));
    });

    test('save_note with a hostile title does not escape the files dir', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('save_note')!, {'title': '../../etc/passwd', 'content': 'x'});
      final p = r.data['path'] as String?;
      expect(p, isNotNull);
      expect(File(p!).parent.path, _tmp.path);
    });

    test('save_note with empty/symbol-only title gets a usable filename', () async {
      // BUG: low. A title of only symbols yields a file called ".md".
      final s = await _services();
      final r = await _run(s, s.skills.byId('save_note')!, {'title': '???', 'content': 'x'});
      final p = r.data['path'] as String;
      expect(p.split('/').last, isNot('.md'));
    });

    test('memory round trip: remember, recall, forget', () async {
      final s = await _services();
      await _run(s, s.skills.byId('remember_fact')!, {'fact': 'Prefers metric units'});
      final rec = await _run(s, s.skills.byId('recall_memory')!, {'query': 'metric'});
      expect((rec.data['facts'] as List).join(' '), contains('metric'));
      final f = await _run(s, s.skills.byId('forget_memory')!, {'fact': 'Prefers metric units'});
      expect('${f.data['summary']}', 'Forgotten.');
      final f2 = await _run(s, s.skills.byId('forget_memory')!, {'fact': 'Prefers metric units'});
      expect('${f2.data['summary']}', contains('could not find'));
    });

    test('remember_fact with empty fact should not store an empty memory', () async {
      // BUG: low. Empty fact is accepted and reported as remembered.
      final s = await _services();
      final r = await _run(s, s.skills.byId('remember_fact')!, {'fact': ''});
      expect(r.isError, isTrue);
    });

    test('knowledge add then search finds it', () async {
      final s = await _services();
      await _run(s, s.skills.byId('add_to_knowledge')!, {
        'title': 'Lease',
        'text': 'The security deposit is 1200 dollars.',
      });
      final r = await _run(s, s.skills.byId('search_my_files')!, {'query': 'security deposit'});
      expect(r.data['results'], isNotEmpty);
      expect(r.cards.single.type, 'table');
    });

    test('search_my_files with nothing matching is not an error', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('search_my_files')!, {'query': 'zzzqqq'});
      expect(r.isError, isFalse);
    });

    test('add_to_knowledge with nothing to save errors', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('add_to_knowledge')!, {'title': 'x', 'text': '   '});
      expect(r.isError, isTrue);
      final d = await _run(s, s.skills.byId('add_to_knowledge')!, {'title': 'x', 'document': 'a4'}, atts: const [_doc]);
      expect(d.isError, isTrue);
    });

    test('add_to_knowledge reads an attached text document', () async {
      final s = await _services();
      final f = File('${_tmp.path}/doc.txt')..writeAsStringSync('Alpha bravo charlie.');
      final att = Attachment(id: 'a9', kind: 'document', path: f.path, name: 'doc.txt');
      final r = await _run(s, s.skills.byId('add_to_knowledge')!, {'title': 'Doc', 'document': 'a9'}, atts: [att]);
      expect(r.isError, isFalse, reason: '${r.data}');
    });

    test('read_link: empty url is an error; mock page is read', () async {
      final s = await _services();
      expect((await _run(s, s.skills.byId('read_link')!, {'url': '  '})).isError, isTrue);
      final r = await _run(s, s.skills.byId('read_link')!, {'url': 'https://example.com/page'});
      expect(r.isError, isFalse);
      expect(r.cards.single.type, 'link');
    });

    test('read_link with garbage urls never throws', () async {
      final s = await _services();
      for (final u in ['not a url', 'javascript:alert(1)', 'http://', 'https://[::1', 'ftp://x', '😀', 'a' * 5000]) {
        final r = await _run(s, s.skills.byId('read_link')!, {'url': u});
        expect(r, isA<SkillResult>(), reason: u);
      }
    });

    test('meeting_minutes returns summary and transcript card', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('meeting_minutes')!, {'audio': 'a1'}, atts: const [_audio]);
      expect(r.cards.map((c) => c.type), contains('transcript'));
      expect(r.data['speakers'], 2);
    });

    test('pick_best_photo ranks high-to-low', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('pick_best_photo')!, {}, atts: const [_image, _image2]);
      expect(r.cards.map((c) => c.type), containsAll(['image', 'bars']));
    });

    test('show_table: ragged rows and missing columns render-ready data', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('show_table')!, {
        'title': 'T',
        'columns': ['A', 'B', 'C'],
        'rows': ['1 | 2', '1 | 2 | 3 | 4', ''],
      });
      expect(r.isError, isFalse);
    });

    test('show_table with no columns or rows is an error or a clear empty card', () async {
      // BUG: low. Empty table is reported as shown: true.
      final s = await _services();
      final r = await _run(s, s.skills.byId('show_table')!, {'title': 'T'});
      expect(r.isError, isTrue);
    });

    test('show_chart with mismatched labels/values is rejected or normalised', () async {
      // BUG: low. labels and values lengths can differ and are passed through.
      final s = await _services();
      final r = await _run(s, s.skills.byId('show_chart')!, {
        'title': 'x',
        'labels': ['a', 'b', 'c'],
        'values': ['1'],
      });
      final d = r.cards.isEmpty ? null : r.cards.first.data;
      expect(r.isError || (d != null && (d['labels'] as List).length == (d['values'] as List).length), isTrue);
    });

    test('show_chart parses currency and thousand separators', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('show_chart')!, {
        'title': 'x',
        'labels': ['a', 'b', 'c'],
        'values': [r'$1,200', '45%', '-3.5'],
      });
      final v = (r.cards.single.data['values'] as List).cast<double>();
      expect(v, [1200, 45, -3.5]);
    });

    test('show_timeline splits "time — text"', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('show_timeline')!, _sensible['show_timeline']!);
      final items = (r.cards.single.data['items'] as List).cast<Map>();
      expect(items.first['time'], '9:00');
      expect(items.first['text'], 'Standup');
      expect(items.last['text'], 'Review');
    });

    test('list parsing: string lists split on newline/semicolon but not comma', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('show_checklist')!, {'title': 't', 'items': 'a\nb; c'});
      expect((r.cards.single.data['items'] as List), ['a', 'b', 'c']);
    });
  });

  // -------------------------------------------------------------------------
  group('device skills (non-demo device responses)', () {
    const deviceSkills = [
      'set_timer',
      'set_alarm',
      'create_event',
      'list_events',
      'find_contact',
      'call_number',
      'draft_text_message',
      'draft_email',
      'open_app',
      'open_url',
      'navigate_to',
      'toggle_flashlight',
      'open_settings',
      'set_volume',
      'battery_status',
      'storage_status',
      'share_text',
      'copy_to_clipboard',
      'read_clipboard',
      'get_datetime',
    ];

    test('summaries are right and device errors propagate', () async {
      final s = await _services();
      for (final id in deviceSkills) {
        final k = s.skills.byId(id)!;
        final ok = await _run(
          s,
          k,
          _sensible[id]!,
          deviceFn: (a, b) async => {'ok': true, 'level': 55, 'charging': true},
        );
        expect(ok.isError, isFalse, reason: id);
        final bad = await _run(s, k, _sensible[id]!, deviceFn: (a, b) async => {'error': 'Permission denied'});
        expect(bad.isError, isTrue, reason: id);
        expect('${bad.data['error']}', 'Permission denied', reason: id);
        final empty = await _run(s, k, _sensible[id]!, deviceFn: (a, b) async => {});
        expect(empty, isA<SkillResult>());
      }
      final t = await _run(s, s.skills.byId('set_timer')!, {'seconds': 125}, deviceFn: (a, b) async => {'ok': true});
      expect(t.data['summary'], 'Timer set for 2 min 5 s.');
      final al = await _run(s, s.skills.byId('set_alarm')!, {
        'hour': 6,
        'minute': 5,
      }, deviceFn: (a, b) async => {'ok': true});
      expect(al.data['summary'], 'Alarm set for 06:05.');
      final b = await _run(
        s,
        s.skills.byId('battery_status')!,
        {},
        deviceFn: (a, b) async => {'level': 40, 'charging': true},
      );
      expect(b.data['summary'], 'Battery at 40%, charging.');
      final f = await _run(s, s.skills.byId('toggle_flashlight')!, {
        'on': 'false',
      }, deviceFn: (a, b) async => {'ok': true});
      expect(f.data['summary'], 'Flashlight off.');
    });

    test('device action names and forwarded args', () async {
      final s = await _services();
      final expected = {
        'set_timer': 'timer.set',
        'set_alarm': 'alarm.set',
        'create_event': 'calendar.create',
        'list_events': 'calendar.list',
        'find_contact': 'contacts.search',
        'call_number': 'phone.dial',
        'draft_text_message': 'sms.compose',
        'draft_email': 'email.compose',
        'open_app': 'app.open',
        'open_url': 'url.open',
        'navigate_to': 'maps.navigate',
        'toggle_flashlight': 'torch',
        'open_settings': 'settings.open',
        'set_volume': 'volume.set',
        'battery_status': 'battery',
        'storage_status': 'storage',
        'share_text': 'share.text',
        'copy_to_clipboard': 'clipboard.set',
        'read_clipboard': 'clipboard.get',
        'get_datetime': 'datetime',
      };
      for (final e in expected.entries) {
        final ctx = _Ctx(s, deviceFn: (a, b) async => {'ok': true});
        await s.skills.byId(e.key)!.run(_sensible[e.key]!, ctx);
        expect(ctx.deviceCalls.single.$1, e.value, reason: e.key);
        expect(ctx.deviceCalls.single.$2, _sensible[e.key]!, reason: e.key);
      }
    });

    test('list_events tolerates odd event shapes', () async {
      final s = await _services();
      final r = await _run(
        s,
        s.skills.byId('list_events')!,
        {'days': 1},
        deviceFn: (a, b) async => {
          'events': [
            {'title': null, 'start': null},
            {'title': 'x', 'start': '2026-01-01T10:00:00.000'},
            {},
          ],
        },
      );
      expect(r.cards.single.type, 'timeline');
    });

    test('required device params are validated', () async {
      // BUG: medium. Device skills forward whatever they get: a missing or
      // nonsensical required argument reaches the OS (e.g. set_timer with no
      // seconds, call_number with no number, open_url with no url).
      final s = await _services();
      final offenders = <String>[];
      for (final id in deviceSkills) {
        final k = s.skills.byId(id)!;
        if (!k.params.any((p) => p.required)) continue;
        final r = await _run(s, k, {}, deviceFn: (a, b) async => {'ok': true});
        if (!r.isError) offenders.add(id);
      }
      expect(offenders, isEmpty, reason: 'no error for missing required args: $offenders');
    });

    test('out-of-range values are rejected', () async {
      // BUG: medium. Alarm hour 99, negative timers and volume 500% are forwarded.
      final s = await _services();
      Future<bool> rejected(String id, Map<String, dynamic> a) async =>
          (await _run(s, s.skills.byId(id)!, a, deviceFn: (x, y) async => {'ok': true})).isError;
      final failed = <String>[
        if (!await rejected('set_alarm', {'hour': 99, 'minute': 0})) 'set_alarm hour 99',
        if (!await rejected('set_alarm', {'hour': 6, 'minute': 75})) 'set_alarm minute 75',
        if (!await rejected('set_timer', {'seconds': -5})) 'set_timer -5',
        if (!await rejected('set_timer', {'seconds': 0})) 'set_timer 0',
        if (!await rejected('set_volume', {'percent': 500})) 'set_volume 500',
        if (!await rejected('set_volume', {'percent': -1})) 'set_volume -1',
        if (!await rejected('create_event', {'title': 'x', 'start': 'next tuesday-ish'})) 'create_event bad start',
        if (!await rejected('open_settings', {'page': 'nuclear'})) 'open_settings bad page',
        if (!await rejected('navigate_to', {'destination': 'x', 'mode': 'teleport'})) 'navigate bad mode',
      ];
      expect(failed, isEmpty);
    });

    test('open_url only passes web-safe schemes', () async {
      // BUG: medium. "Open link … or deep link" accepts any scheme, including
      // javascript:, file: and intent: URIs, with only a first-time prompt.
      final s = await _services();
      for (final u in ['javascript:alert(1)', 'file:///data/data/x', 'intent://x#Intent;end']) {
        final ctx = _Ctx(s, deviceFn: (a, b) async => {'ok': true});
        final r = await s.skills.byId('open_url')!.run({'url': u}, ctx);
        expect(r.isError, isTrue, reason: u);
      }
    });
  });

  // -------------------------------------------------------------------------
  group('Calculator', () {
    double ev(String e) => Calculator.evaluate(e);

    test('precedence and associativity', () {
      expect(ev('2+3*4'), 14);
      expect(ev('(2+3)*4'), 20);
      expect(ev('2^3^2'), 512);
      expect(ev('10-4-3'), 3);
      expect(ev('100/10/5'), 2);
      expect(ev('2*3^2'), 18);
      expect(ev('-3^2'), isIn([9, -9]));
      expect(ev('2^-1'), 0.5);
      expect(ev('--5'), 5);
      expect(ev('+5'), 5);
      expect(ev('2*-3'), -6);
      expect(ev('1,000+2,500'), 3500);
      expect(ev('1200*0.18+45'), 261);
      expect(ev('.5+.5'), 1);
      expect(ev('  1 +   1 '), 2);
      expect(ev('6×7'), 42);
      expect(ev('8÷2'), 4);
      expect(ev('pi'), closeTo(3.14159265, 1e-8));
      expect(ev('2*pi*3'), closeTo(18.8495559, 1e-6));
      expect(ev('sqrt(16)+abs(-2)+round(2.5)'), 9);
      expect(ev('log(1000)'), closeTo(3, 1e-12));
      expect(ev('ln(e)'), closeTo(1, 1e-12));
    });

    test('percentages', () {
      expect(ev('50%'), 0.5);
      expect(ev('200*50%'), 100);
      expect(ev('10 % 3'), 1);
      expect(ev('10%3'), 1);
      expect(ev('(50)%'), 0.5);
      expect(ev('18/100*2450'), 441);
    });

    test('percent-of phrasing "18% of 2450"', () {
      // BUG: low/medium. The tool description advertises %, and models pass
      // "18% of 2450" verbatim; it throws "Unexpected \"of 2450\"".
      expect(ev('18% of 2450'), 441);
    });

    test('"200 + 10%" means 220 as on every pocket calculator', () {
      // BUG: low. Evaluates to 200.1 (10% is just 0.1).
      expect(ev('200+10%'), 220);
    });

    test('function names are case-insensitive', () {
      // BUG: low. "SQRT(16)" / "Pi" throw "Unexpected S"; models often capitalise.
      expect(ev('SQRT(16)'), 4);
      expect(ev('2*Pi'), closeTo(6.2831853, 1e-6));
    });

    test('whitespace other than spaces is accepted', () {
      // BUG: low. Tabs/newlines throw.
      expect(ev('2 +\n3'), 5);
      expect(ev('2\t*3'), 6);
    });

    test('unicode minus and x are accepted', () {
      // BUG: low. U+2212 minus (common in pasted text) is rejected.
      expect(ev('5−2'), 3);
    });

    test('malformed input throws FormatException only', () {
      for (final e in [
        '',
        '   ',
        '2 +',
        '(2+3',
        '2+3)',
        ')',
        '(',
        '()',
        '2..3',
        '2 3',
        'abc',
        '2**3',
        '1/',
        '^2',
        'sqrt',
        'sqrt(',
        'sqrt 4',
        '3 +* 4',
        '²',
        '٣',
        r'$5',
        '5 5',
        'drop table',
        '1;2',
        '2^',
        'foo(1)',
        '1e3',
        '0x10',
        '\u0000',
      ]) {
        expect(() => Calculator.evaluate(e), throwsFormatException, reason: '"$e"');
      }
    });

    test('division by zero and other non-finite results', () {
      expect(ev('1/0'), double.infinity);
      expect(ev('-1/0'), double.negativeInfinity);
      expect(ev('0/0').isNaN, isTrue);
      expect(ev('5 % 0').isNaN, isTrue);
      expect(ev('sqrt(-1)').isNaN, isTrue);
    });

    test('calculate skill reports non-finite results as errors', () async {
      // BUG: medium. "1/0" returns ok with result "Infinity"; sqrt(-1) returns
      // "NaN". The model is told it is a valid answer and may relay it.
      final s = await _services();
      final k = s.skills.byId('calculate')!;
      for (final e in ['1/0', '0/0', '5%0', 'sqrt(-1)', 'ln(0)', '2^5000']) {
        final r = await _run(s, k, {'expression': e});
        expect(r.isError, isTrue, reason: '$e -> ${r.data}');
      }
    });

    test('large numbers', () {
      expect(Calculator.format(ev('999999999999999')), '999999999999999');
      expect(ev('2^53'), 9007199254740992);
      expect(ev('2^1024'), double.infinity);
      expect(ev('9' * 400), double.infinity);
      expect(Calculator.format(ev('2^64')), isNot(anyOf(contains('NaN'), isEmpty)));
    });

    test('format precision for huge and tiny numbers', () {
      // BUG: low. Integers >= 1e15 are rounded to 12 digits and printed with a
      // trailing ".0": 2^53 prints "9007199254740000.0".
      expect(Calculator.format(1e15), '1000000000000000');
      expect(Calculator.format(9007199254740992), '9007199254740992');
    });

    test('format basics', () {
      expect(Calculator.format(441), '441');
      expect(Calculator.format(-0.0), '0');
      expect(Calculator.format(0.1 + 0.2), '0.3');
      expect(Calculator.format(1 / 3), '0.333333333333');
      expect(Calculator.format(double.nan), 'NaN');
      expect(Calculator.format(double.infinity), 'Infinity');
      expect(Calculator.format(-2.50), '-2.5');
    });

    test('decimal comma silently becomes thousands separator', () {
      // BUG: low. "2,5*2" is evaluated as 25*2 = 50 with no warning.
      expect(() => ev('2,5*2'), throwsFormatException);
    });

    test('calculate skill: sample prompts', () async {
      final s = await _services();
      final k = s.skills.byId('calculate')!;
      Future<String> calc(Object? e) async => '${(await _run(s, k, {'expression': e})).data['result']}';
      expect(await calc('(1200*0.18)+45'), '261');
      expect(await calc('18/100*2450'), '441');
      expect(await calc(42), '42');
      expect((await _run(s, k, {'expression': 'hello'})).isError, isTrue);
      expect((await _run(s, k, {})).isError, isTrue);
      expect('${(await _run(s, k, {'expression': 'hello'})).data['error']}', startsWith('Invalid expression'));
    });

    test('pathological nesting does not crash the skill', () async {
      // Deeply nested parentheses overflow the recursive-descent parser. The
      // skill only catches FormatException, so StackOverflowError escapes
      // (the agent happens to catch it, direct callers do not).
      final s = await _services();
      final r = await _run(s, s.skills.byId('calculate')!, {'expression': '(' * 200000});
      expect(r.isError, isTrue);
    });

    test('very long flat expression is fast', () async {
      final sw = Stopwatch()..start();
      expect(ev(List.filled(100000, '1').join('+')), 100000);
      expect(sw.elapsedMilliseconds, lessThan(3000));
    });
  });

  // -------------------------------------------------------------------------
  group('Units', () {
    test('known conversions', () {
      expect(Units.convert(5, 'miles', 'km'), closeTo(8.04672, 1e-6));
      expect(Units.convert(1, 'kg', 'lb'), closeTo(2.2046, 1e-3));
      expect(Units.convert(100, '°C', '°F'), closeTo(212, 1e-9));
      expect(Units.convert(-40, 'C', 'F'), closeTo(-40, 1e-9));
      expect(Units.convert(0, 'K', 'C'), closeTo(-273.15, 1e-9));
      expect(Units.convert(32, 'fahrenheit', 'kelvin'), closeTo(273.15, 1e-9));
      expect(Units.convert(1, 'gal', 'l'), closeTo(3.785411784, 1e-9)); // exact US gallon
      expect(Units.convert(100, 'km/h', 'mph'), closeTo(62.137, 1e-2));
      expect(Units.convert(1, 'gib', 'mb'), closeTo(1073.741824, 1e-6));
      expect(Units.convert(2, 'hours', 'min'), 120);
      expect(Units.convert(1, 'week', 'day'), 7);
      expect(Units.convert(3, 'ft', 'in'), closeTo(36, 1e-3));
      expect(Units.convert(0, 'km', 'mi'), 0);
      expect(Units.convert(-5, 'km', 'm'), -5000);
      expect(Units.convert(7, 'km', 'km'), 7);
      expect(Units.convert(1, ' KM ', 'M'), 1000);
    });

    test('round trips are accurate', () {
      for (final u in [
        'mm',
        'cm',
        'km',
        'in',
        'ft',
        'yd',
        'mi',
        'mg',
        'g',
        'oz',
        'lb',
        'st',
        'ml',
        'cup',
        'gal',
        'km/h',
        'mph',
        'kn',
      ]) {
        final group = u == 'km/h' || u == 'mph' || u == 'kn'
            ? 'm/s'
            : ['mg', 'g', 'oz', 'lb', 'st'].contains(u)
            ? 'kg'
            : ['ml', 'cup', 'gal'].contains(u)
            ? 'l'
            : 'm';
        expect(Units.convert(Units.convert(123.456, u, group), group, u), closeTo(123.456, 1e-9), reason: u);
      }
    });

    test('1 mile is 1.609344 km exactly; 1 lb is 453.592 g', () {
      expect(Units.convert(1, 'mi', 'km'), closeTo(1.609344, 1e-12));
      // BUG: low. lb factor 0.453592 vs 0.45359237 (8e-7 relative error).
      expect(Units.convert(1, 'lb', 'g'), closeTo(453.59237, 1e-4));
      // km/h factor 0.277778 vs 1/3.6 (1.6e-6 relative error).
      expect(Units.convert(36, 'km/h', 'm/s'), closeTo(10, 1e-6));
    });

    test('invalid conversions throw ArgumentError', () {
      expect(() => Units.convert(1, 'kg', 'km'), throwsArgumentError);
      expect(() => Units.convert(1, 'C', 'km'), throwsArgumentError);
      expect(() => Units.convert(1, '', ''), throwsArgumentError);
      expect(() => Units.convert(1, 'parsec', 'm'), throwsArgumentError);
      expect(() => Units.convert(1, 'm', 'parsec'), throwsArgumentError);
    });

    test('common spellings are recognised', () {
      // BUG: low. Singular "second"/"minute" and several plurals are missing.
      final missing = <String>[];
      for (final (v, f, t) in [
        (1, 'minute', 'seconds'),
        (1, 'second', 'ms'),
        (1, 'hour', 'minutes'),
        (1, 'day', 'hours'),
        (1, 'millimeters', 'cm'),
        (1, 'centimetres', 'mm'),
        (1, 'kilometre', 'm'),
        (1, 'metres', 'cm'),
        (1, 'milliliters', 'l'),
        (1, 'teaspoon', 'ml'),
        (1, 'tablespoon', 'ml'),
        (1, 'pint', 'ml'),
        (1, 'quart', 'l'),
        (1, 'knot', 'km/h'),
        (1, 'tonne', 'kg'),
        (1, 'kilobyte', 'bytes'),
        (1, 'megabytes', 'kb'),
        (1, 'gigabytes', 'mb'),
        (1, 'celsius', 'fahrenheit'),
        (1, 'degrees celsius', 'fahrenheit'),
        (1, 'fl oz', 'ml'),
        (1, 'mph', 'kmh'),
        (1, 'cups', 'tbsp'),
        (1, 'foot', 'inches'),
        (1, 'pounds', 'ounces'),
        (1, 'liters', 'gallons'),
      ]) {
        try {
          Units.convert(v.toDouble(), f, t);
        } on ArgumentError {
          missing.add('$f->$t');
        }
      }
      expect(missing, isEmpty);
    });

    test('convert_units skill', () async {
      final s = await _services();
      final k = s.skills.byId('convert_units')!;
      final r = await _run(s, k, {'value': 5, 'from': 'miles', 'to': 'km'});
      expect(r.data['result'], '8.04672');
      expect('${r.data['summary']}', contains('5 miles = **8.04672 km**'));
      final t = await _run(s, k, {'value': '100', 'from': 'C', 'to': 'F'});
      expect(t.data['result'], '212');
      final bad = await _run(s, k, {'value': 1, 'from': 'kg', 'to': 'km'});
      expect(bad.isError, isTrue);
      expect('${bad.data['error']}', contains('Cannot convert'));
    });

    test('convert_units rejects a non-numeric value', () async {
      // BUG: medium. value "abc" (or missing) silently becomes 0, so
      // "convert abc km to m" answers "0 m" as if it were valid.
      final s = await _services();
      final k = s.skills.byId('convert_units')!;
      expect((await _run(s, k, {'value': 'abc', 'from': 'km', 'to': 'm'})).isError, isTrue);
      expect((await _run(s, k, {'from': 'km', 'to': 'm'})).isError, isTrue);
    });

    test('convert_units small results are not printed in exponent form', () async {
      // BUG: low. 1 mg -> kg prints "1e-6".
      final s = await _services();
      final r = await _run(s, s.skills.byId('convert_units')!, {'value': 1, 'from': 'mg', 'to': 'kg'});
      expect('${r.data['result']}', isNot(contains('e')));
    });

    test('convert_units extreme values do not throw', () async {
      final s = await _services();
      final k = s.skills.byId('convert_units')!;
      for (final v in [1e308, -1e308, 1e-320, 0, double.maxFinite]) {
        final r = await _run(s, k, {'value': v, 'from': 'tb', 'to': 'b'});
        expect(r, isA<SkillResult>());
      }
    });
  });

  // -------------------------------------------------------------------------
  group('date_calc and datetime', () {
    Future<Map<String, dynamic>> dc(Map<String, dynamic> a) async {
      final s = await _services();
      return (await _run(s, s.skills.byId('date_calc')!, a)).data;
    }

    test('add days, weekdays, month and leap boundaries', () async {
      expect((await dc({'start': '2026-10-31', 'add_days': 1}))['date'], '2026-11-01');
      expect((await dc({'start': '2026-10-31', 'add_days': 1}))['weekday'], 'Sunday');
      expect((await dc({'start': '2028-02-28', 'add_days': 1}))['date'], '2028-02-29');
      expect((await dc({'start': '2027-02-28', 'add_days': 1}))['date'], '2027-03-01');
      expect((await dc({'start': '2026-01-01', 'add_days': -1}))['date'], '2025-12-31');
      expect((await dc({'start': '2026-12-31', 'add_days': 366}))['date'], '2028-01-01');
      expect((await dc({'start': '2026-10-31', 'add_days': 0}))['date'], '2026-10-31');
      expect((await dc({'start': '2026-10-31', 'add_days': '7'}))['date'], '2026-11-07');
    });

    test('days between', () async {
      expect((await dc({'start': '2026-10-31', 'end': '2026-12-25'}))['days'], 55);
      expect((await dc({'start': '2026-12-25', 'end': '2026-10-31'}))['days'], -55);
      expect((await dc({'start': '2026-10-31', 'end': '2026-10-31'}))['days'], 0);
      expect((await dc({'start': '2024-02-28', 'end': '2024-03-01'}))['days'], 2);
    });

    test('defaults to today', () async {
      final now = DateTime.now();
      final d = await dc({'add_days': 0});
      expect(d['date'], '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}');
    });

    test('an unparseable end date is an error, not today\'s date', () async {
      // BUG: medium. {"end": "Christmas"} is ignored and the skill answers with
      // today's date as if add_days=0 had been asked.
      final s = await _services();
      final k = s.skills.byId('date_calc')!;
      for (final a in [
        {'start': '2026-10-31', 'end': 'Christmas'},
        {'start': 'tomorrow', 'add_days': 1},
        {'start': '2026-13-45', 'add_days': 1},
        {'start': '2026-02-30', 'add_days': 0},
      ]) {
        final r = await _run(s, k, a);
        expect(r.isError, isTrue, reason: '$a -> ${r.data}');
      }
    });

    test('huge add_days does not throw', () async {
      // BUG: low. add_days beyond DateTime range throws instead of a clear error.
      final s = await _services();
      final r = await _run(s, s.skills.byId('date_calc')!, {'start': '2026-01-01', 'add_days': 999999999999});
      expect(r.isError, isTrue);
    });

    test('date maths is exact across a DST change (needs a DST time zone)', () async {
      // BUG: medium. Uses DateTime.add(Duration(days:)) and difference().inDays
      // on local times, so across a DST change the result is off by one day.
      // Only meaningful when run with e.g. TZ=America/New_York; otherwise it
      // passes trivially.
      final before = DateTime(2026, 3, 1);
      final after = DateTime(2026, 3, 15);
      final hasDst = before.timeZoneOffset != after.timeZoneOffset;
      final r1 = await dc({'start': '2026-03-01', 'add_days': 14});
      expect(r1['date'], '2026-03-15', reason: hasDst ? 'DST zone' : 'no DST in this zone');
      final r2 = await dc({'start': '2026-03-01', 'end': '2026-03-15'});
      expect(r2['days'], 14, reason: hasDst ? 'DST zone' : 'no DST in this zone');
      final r3 = await dc({'start': '2026-10-25', 'end': '2026-11-02'});
      expect(r3['days'], 8);
    });

    test('get_datetime returns iso, weekday and summary', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('get_datetime')!, {});
      expect(r.isError, isFalse);
      expect(DateTime.tryParse('${r.data['iso']}'), isNotNull);
      expect(r.data['weekday'], isNotEmpty);
      expect(r.data['summary'], contains('${DateTime.now().year}'));
    });
  });

  // -------------------------------------------------------------------------
  group('format helpers', () {
    test('formatBytes', () {
      expect(formatBytes(0), '0 B');
      expect(formatBytes(999), '999 B');
      expect(formatBytes(1000), '1 KB');
      expect(formatBytes(1500000), '2 MB');
      expect(formatBytes(2500000000), '2.5 GB');
    });

    test('formatBytes rounds up to the next unit', () {
      // BUG: low. 999,999 B prints "1000 KB" and 999,999,999 B "1000 MB".
      expect(formatBytes(999999), isNot('1000 KB'));
      expect(formatBytes(999999999), isNot('1000 MB'));
    });

    test('formatDuration', () {
      expect(formatDuration(0), '0:00');
      expect(formatDuration(59.6), '1:00');
      expect(formatDuration(75), '1:15');
      expect(formatDuration(14.2), '0:14');
    });

    test('formatDuration handles negative, NaN and Infinity', () {
      // BUG: low. NaN/Infinity throw UnsupportedError; -5 prints "0:-5".
      expect(formatDuration(-5), isNot(contains('-')));
      expect(() => formatDuration(double.nan), returnsNormally);
      expect(() => formatDuration(double.infinity), returnsNormally);
    });

    test('formatMs and timeAgo', () {
      expect(formatMs(5), '5 ms');
      expect(formatMs(999), '999 ms');
      expect(formatMs(1500), '1.5 s');
      expect(timeAgo(DateTime.now()), 'just now');
      expect(timeAgo(DateTime.now().add(const Duration(days: 3))), 'just now');
      expect(timeAgo(DateTime.now().subtract(const Duration(minutes: 5))), '5m ago');
      expect(timeAgo(DateTime.now().subtract(const Duration(hours: 5))), '5h ago');
      expect(timeAgo(DateTime.now().subtract(const Duration(days: 3))), '3d ago');
      expect(timeAgo(DateTime(2020, 1, 5)), '2020-01-05');
    });
  });

  // -------------------------------------------------------------------------
  group('recipes', () {
    test('fillTemplate', () {
      final results = [
        {
          'text': 'one',
          'list': ['a', 'b'],
          'n': {'x': 5},
          'zero': 0,
          'f': false,
        },
        {'result': 'two'},
      ];
      String f(String t, [String input = 'IN']) => fillTemplate(t, input, results);
      expect(f('{{input}}'), 'IN');
      expect(f('{{ input }}'), 'IN');
      expect(f('{{prev.result}}'), 'two');
      expect(f('{{steps.1.text}}'), 'one');
      expect(f('{{steps.1.list}}'), 'a\nb');
      expect(f('{{steps.1.n.x}}'), '5');
      expect(f('{{steps.1.zero}}'), '0');
      expect(f('{{steps.1.f}}'), 'false');
      expect(f('{{steps.1.n.y.z}}'), '');
      expect(f('{{steps.0.text}}'), '');
      expect(f('{{steps.3.text}}'), '');
      expect(f('{{steps.x.text}}'), '');
      expect(f('{{steps}}'), '');
      expect(f('{{nothing}}'), '');
      expect(f('{{prev.missing}}'), '');
      expect(f('a {{input}} b {{input}}'), 'a IN b IN');
      expect(f('no placeholders'), 'no placeholders');
      expect(fillTemplate('{{prev.x}}', 'i', []), '');
      // input containing a placeholder is not re-expanded
      expect(f('{{input}}', '{{prev.result}}'), '{{prev.result}}');
    });

    test('fillTemplate: keys with hyphens', () {
      // BUG: low. {{prev.my-key}} is left as literal text rather than resolved.
      expect(
        fillTemplate('{{prev.my-key}}', '', [
          {'my-key': 'v'},
        ]),
        'v',
      );
    });

    test('Recipe JSON round trip and tolerance', () {
      const r = Recipe(
        id: 'x',
        name: 'X',
        description: 'd',
        input: 'audio',
        steps: [
          RecipeStep('summarize', {'text': '{{input}}'}),
        ],
      );
      final back = Recipe.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(back.id, 'x');
      expect(back.input, 'audio');
      expect(back.steps.single.args['text'], '{{input}}');
      expect(back.builtIn, isFalse);
      final minimal = Recipe.fromJson({'id': 'm', 'name': 'M', 'steps': []});
      expect(minimal.description, '');
      expect(minimal.input, 'text');
    });

    test('built-in recipes are well-formed', () async {
      final s = await _services();
      expect(s.skills.recipes.where((r) => r.builtIn).length, builtInRecipes.length);
      for (final r in builtInRecipes) {
        expect(r.steps, isNotEmpty);
        for (final (i, st) in r.steps.indexed) {
          final k = s.skills.byId(st.skillId);
          expect(k, isNotNull, reason: '${r.id} step ${i + 1}: unknown skill ${st.skillId}');
          expect(k!.kind, isNot(SkillKind.recipe));
          final names = k.params.map((p) => p.name).toSet();
          for (final a in st.args.keys) {
            expect(names, contains(a), reason: '${r.id} step ${i + 1}: ${st.skillId} has no param $a');
          }
          for (final p in k.params.where((p) => p.required)) {
            expect(st.args.keys, contains(p.name), reason: '${r.id} step ${i + 1}: missing ${p.name}');
          }
          for (final v in st.args.values) {
            for (final m in RegExp(r'\{\{\s*steps\.(\d+)').allMatches(v)) {
              expect(int.parse(m.group(1)!), lessThan(i + 1), reason: '${r.id}: forward reference');
            }
            if (i == 0) expect(v, isNot(contains('{{prev')), reason: '${r.id}: prev in first step');
          }
        }
      }
    });

    test('RecipeSkill metadata and params per input kind', () async {
      final s = await _services();
      for (final r in s.skills.recipes) {
        final k = RecipeSkill(r);
        expect(k.id, 'recipe_${r.id}');
        expect(k.kind, SkillKind.recipe);
        expect(k.category, SkillCategory.recipes);
        expect(k.description, startsWith('Recipe: '));
        switch (r.input) {
          case 'audio':
            expect(k.params.single.type, ParamType.attachment);
            expect(k.params.single.description, contains('audio'));
          case 'image':
            expect(k.params.single.type, ParamType.attachment);
          case 'none':
            expect(k.params, isEmpty);
          default:
            expect(k.params.single.type, ParamType.string);
        }
      }
    });

    final inputs = {
      'private_share': ({'input': 'Mail bob@acme.com or call +1 555 123 4567'}, <Attachment>[]),
      'voice_memo_note': ({'input': 'a1'}, [_audio]),
      'post_kit': ({'input': 'We launched our new bakery today'}, <Attachment>[]),
      'translate_share': ({'input': 'Good morning'}, <Attachment>[]),
      'document_digest': ({'input': 'a2'}, [_image]),
    };

    for (final e in inputs.entries) {
      test('built-in "${e.key}" runs end to end via ChatController.runSkill', () async {
        final s = await _services();
        final chat = ChatController(s)..onConfirm = (_, _) async => true;
        final k = s.skills.byId('recipe_${e.key}')!;
        // document_digest ends in add_to_knowledge with '{{steps.1.text}}': demo ask returns text.
        await chat.runSkill(k, e.value.$1, attachments: e.value.$2);
        final step = chat.messages.last.steps.single;
        expect(step.status, StepStatus.done, reason: '${step.result}');
        expect('${step.result['summary']}', contains('steps'));
        expect(chat.messages.last.error, isNull);
      });
    }

    test('private_share copies the redacted text, not the original', () async {
      final s = await _services();
      final ctx = _Ctx(s);
      final r = await s.skills.byId('recipe_private_share')!.run({'input': 'Mail bob@acme.com please'}, ctx);
      expect(r.isError, isFalse);
      final copy = ctx.deviceCalls.firstWhere((c) => c.$1 == 'clipboard.set');
      expect(copy.$2['text'], isNot(contains('bob@acme.com')));
      expect(copy.$2['text'], contains('[EMAIL_1]'));
    });

    test('translate_share shares the translation (step output flows)', () async {
      final s = await _services();
      final ctx = _Ctx(s);
      await s.skills.byId('recipe_translate_share')!.run({'input': 'Hello there'}, ctx);
      final share = ctx.deviceCalls.firstWhere((c) => c.$1 == 'share.text');
      expect(share.$2['text'], 'Hello there'); // demo translate echoes the input
    });

    test('voice_memo_note: note content contains the summary and the transcript', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('recipe_voice_memo_note')!, {'input': 'a1'}, atts: const [_audio]);
      expect(r.isError, isFalse);
      final path = ((r.data['result'] as Map)['path']) as String;
      final body = File(path).readAsStringSync();
      expect(body, contains('---'));
      expect(body, contains('launch moves to Thursday'));
      expect(body.trim().startsWith('---'), isFalse, reason: 'summary should precede separator');
    });

    test('recipe with missing audio attachment fails with a step error', () async {
      final s = await _services();
      final r = await _run(s, s.skills.byId('recipe_voice_memo_note')!, {'input': 'a1'});
      expect(r.isError, isTrue);
      expect('${r.data['error']}', startsWith('Step 1 (transcribe_audio) failed'));
    });

    test('recipe with unknown step skill and zero steps', () async {
      final s = await _services();
      const bad = Recipe(id: 'bad', name: 'Bad', description: '', steps: [RecipeStep('does_not_exist', {})]);
      final r = await _run(s, RecipeSkill(bad), {'input': 'x'});
      expect(r.isError, isTrue);
      expect('${r.data['error']}', contains('does_not_exist'));
      const none = Recipe(id: 'none', name: 'None', description: '', steps: []);
      final z = await _run(s, RecipeSkill(none), {});
      expect(z.isError, isFalse);
    });

    test('recipe failing mid-way stops and reports which step', () async {
      final s = await _services();
      const r = Recipe(
        id: 'mid',
        name: 'Mid',
        description: '',
        steps: [
          RecipeStep('calculate', {'expression': '1+1'}),
          RecipeStep('calculate', {'expression': 'nonsense'}),
          RecipeStep('calculate', {'expression': '3+3'}),
        ],
      );
      final res = await _run(s, RecipeSkill(r), {'input': ''});
      expect(res.isError, isTrue);
      expect('${res.data['error']}', startsWith('Step 2 (calculate) failed'));
    });

    test('recipe step results with cards accumulate', () async {
      final s = await _services();
      const r = Recipe(
        id: 'cards',
        name: 'Cards',
        description: '',
        steps: [
          RecipeStep('suggest_emoji', {'text': '{{input}}'}),
          RecipeStep('classify_topics', {'text': '{{input}}'}),
        ],
      );
      final res = await _run(s, RecipeSkill(r), {'input': 'party'});
      expect(res.cards, hasLength(2));
    });

    test('user recipe: save, reload from store, run, edit, delete', () async {
      final store = _DirStore(_tmp.path);
      final s = await _services(store: store);
      const r = Recipe(
        id: 'calc_twice',
        name: 'Calc twice',
        description: 'Adds then doubles',
        input: 'text',
        steps: [
          RecipeStep('calculate', {'expression': '{{input}}'}),
          RecipeStep('calculate', {'expression': '{{prev.result}}*2'}),
        ],
      );
      var notified = 0;
      s.skills.addListener(() => notified++);
      await s.skills.saveRecipe(r);
      expect(notified, greaterThan(0));
      expect(s.skills.byId('recipe_calc_twice'), isNotNull);

      final reloaded = await _services(store: store);
      final loaded = reloaded.skills.recipes.firstWhere((x) => x.id == 'calc_twice');
      expect(loaded.builtIn, isFalse);
      expect(loaded.steps, hasLength(2));
      expect(reloaded.skills.recipes.where((x) => x.builtIn).length, builtInRecipes.length);

      final chat = ChatController(reloaded);
      await chat.runSkill(reloaded.skills.byId('recipe_calc_twice')!, {'input': '2+3'});
      final step = chat.messages.last.steps.single;
      expect(step.status, StepStatus.done);
      expect(((step.result['result'] as Map)['result']), '10');
      expect(step.via, 'recipe');

      // edit in place (same id)
      await reloaded.skills.saveRecipe(loaded.copyWith(name: 'Renamed'));
      expect(reloaded.skills.recipes.where((x) => x.id == 'calc_twice'), hasLength(1));
      final again = await _services(store: store);
      expect(again.skills.recipes.firstWhere((x) => x.id == 'calc_twice').name, 'Renamed');

      await again.skills.deleteRecipe(again.skills.recipes.firstWhere((x) => x.id == 'calc_twice'));
      expect(again.skills.byId('recipe_calc_twice'), isNull);
      final last = await _services(store: store);
      expect(last.skills.byId('recipe_calc_twice'), isNull);
      expect(last.skills.recipes.where((x) => x.builtIn).length, builtInRecipes.length);
    });

    test('built-ins are never persisted', () async {
      final store = _DirStore(_tmp.path);
      final s = await _services(store: store);
      await s.skills.saveRecipe(const Recipe(id: 'u1', name: 'U', description: '', steps: []));
      final saved = (jsonDecode(store.data['recipes'] as String) as List).cast<Map>();
      expect(saved.map((m) => m['id']), ['u1']);
    });

    test('saving a recipe with a built-in id does not clobber the built-in', () async {
      // BUG: medium. The editor derives the id from the name, so a user recipe
      // named "Private share" gets id "private_share", which replaces the
      // built-in in memory; after restart both exist with the same skill id
      // (recipe_private_share), and byId returns the built-in.
      final store = _DirStore(_tmp.path);
      final s = await _services(store: store);
      await s.skills.saveRecipe(
        const Recipe(
          id: 'private_share',
          name: 'Private share',
          description: 'mine',
          steps: [
            RecipeStep('summarize', {'text': '{{input}}'}),
          ],
        ),
      );
      final again = await _services(store: store);
      final ids = again.skills.all.map((k) => k.id).toList();
      expect(ids.toSet().length, ids.length, reason: 'duplicate skill ids after reload');
    });

    test('recipe that calls itself is stopped', () async {
      // BUG: medium. Nothing prevents recursion: a recipe (or community chain)
      // whose step calls its own skill id recurses forever.
      final s = await _services();
      await s.skills.saveRecipe(
        const Recipe(
          id: 'loop',
          name: 'Loop',
          description: '',
          steps: [
            RecipeStep('recipe_loop', {'input': 'x'}),
          ],
        ),
      );
      final ctx = _Ctx(s);
      await s.skills.byId('recipe_loop')!.run({'input': 'x'}, ctx);
      expect(ctx.maxDepth, lessThan(10), reason: 'recursed to depth ${ctx.maxDepth} (QA guard stops at 30)');
    });

    test('corrupted saved recipe does not stop the app from starting', () async {
      // BUG: medium. SkillRegistry.load() has no guard: one malformed entry in
      // the "recipes" store key throws a TypeError out of AppServices.create.
      final store = _DirStore(_tmp.path);
      store.data['recipes'] = jsonEncode([
        {'id': 'ok', 'name': 'Ok', 'steps': []},
        {'id': 'broken'},
      ]);
      await expectLater(_services(store: store), completes);
    });

    test('corrupted community skill in store does not stop the app from starting', () async {
      // BUG: medium. Same for the "community-skills" key (e.g. after a schema
      // bump the stored manifest fails CommunitySkill.parse).
      final store = _DirStore(_tmp.path);
      store.data['community-skills'] = jsonEncode([
        {'schema': 'phonedots.skill/v0', 'id': 'old'},
      ]);
      await expectLater(_services(store: store), completes);
    });

    test('recipe editor default field guess matches what the previous skill returns', () async {
      // BUG: low. RecipeEditor._guessField defaults to "summary" for every
      // skill that is not special-cased, but many skills return no "summary",
      // so the pre-filled {{prev.summary}} resolves to an empty string.
      String guess(Skill s) => switch (s.id) {
        'transcribe_audio' || 'read_text_in_image' => 'text',
        'redact_pii' => 'redacted_text',
        'summarize' || 'rewrite' || 'translate' || 'proofread' || 'draft_reply' => 'result',
        _ => 'summary',
      };
      final s = await _services();
      final blank = <String>[];
      for (final k in s.skills.builtIns.where((k) => k.kind != SkillKind.ui)) {
        final id = k.id;
        if (_demoLimited.contains(id)) continue;
        final r = await _run(
          s,
          k,
          _sensible[id]!,
          atts: const [_audio, _image, _image2, _doc],
          deviceFn: (a, b) async => {'ok': true},
        );
        if (r.isError) continue;
        if (!r.data.containsKey(guess(k)) && r.data.isNotEmpty) blank.add(id);
      }
      expect(blank, isEmpty, reason: '$blank');
    });
  });

  // -------------------------------------------------------------------------
  group('community skills: parse and validate', () {
    Map<String, dynamic> valid([Map<String, dynamic>? patch]) => {
      'schema': CommunitySkill.schema,
      'id': 'my_skill',
      'name': 'My skill',
      'description': 'Does a thing',
      'params': [
        {'name': 'topic', 'type': 'string', 'description': 'What'},
      ],
      'prompt': {'system': 'sys', 'user': 'About {{topic}}'},
      ...?patch,
    };

    void rejects(Map<String, dynamic> m, [String? containing]) {
      expect(
        () => CommunitySkill.parse(m),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            containing == null ? isNotEmpty : contains(containing),
          ),
        ),
      );
    }

    test('bundled samples parse and have valid specs', () async {
      for (final m in sampleCommunitySkills) {
        final c = CommunitySkill.parse(m);
        expect(c.id, startsWith('c_'));
        expect(c.toToolSpec().parameters['type'], 'object');
        for (final p in c.params) {
          expect(p.description, isNotEmpty);
        }
      }
    });

    test('valid manifest', () {
      final c = CommunitySkill.parse(
        valid({
          'author': 'Me',
          'version': '2.1',
          'examples': ['ex'],
        }),
        sourceUrl: 'https://x.y/s.json',
      );
      expect(c.id, 'c_my_skill');
      expect(c.name, 'My skill');
      expect(c.author, 'Me');
      expect(c.version, '2.1');
      expect(c.examples, ['ex']);
      expect(c.sourceUrl, 'https://x.y/s.json');
      expect(c.params.single.type, ParamType.string);
      expect(c.calls, isEmpty);
      expect(CommunitySkill.parse(valid()).author, 'Unknown');
      expect(CommunitySkill.parse(valid()).version, '1.0');
    });

    test('rejects missing / wrong fields with clear messages', () {
      rejects(valid({'schema': 'other/v1'}), 'schema');
      rejects({...valid()}..remove('schema'), 'schema');
      rejects(valid({'id': 'Bad Id'}), 'id');
      rejects(valid({'id': 'ab'}), 'id');
      rejects(valid({'id': 'a' * 42}), 'id');
      rejects(valid({'id': '1abc'}), 'id');
      rejects(valid({'id': 'UPPER'}), 'id');
      rejects(valid({'id': 'has-dash'}), 'id');
      rejects(valid({'id': 5}), 'id');
      rejects({...valid()}..remove('id'), 'id');
      rejects({...valid()}..remove('name'), 'name');
      rejects({...valid()}..remove('description'), 'description');
      rejects(valid({'name': 5}), 'name');
      rejects(valid({'description': null}), 'description');
      rejects({...valid()}..remove('prompt'), 'prompt');
      rejects(valid({'prompt': 'text'}), 'prompt');
      rejects(
        valid({
          'prompt': {'system': 's'},
        }),
        'prompt',
      );
      rejects(
        valid({
          'prompt': {'user': 5},
        }),
        'prompt',
      );
      rejects(valid({'steps': []}), 'exactly one');
      rejects(
        {...valid()}
          ..remove('prompt')
          ..['steps'] = 'nope',
        'prompt',
      );
      rejects(
        valid({
          'params': [5],
        }),
        'param',
      );
      rejects(
        valid({
          'params': [
            {'type': 'string'},
          ],
        }),
        'param',
      );
      rejects(
        valid({
          'params': [
            {'name': 5},
          ],
        }),
        'param',
      );
    });

    test('id boundaries: 3 and 41 chars accepted', () {
      expect(() => CommunitySkill.parse(valid({'id': 'abc'})), returnsNormally);
      expect(() => CommunitySkill.parse(valid({'id': 'a${'b' * 40}'})), returnsNormally);
      rejects(valid({'id': 'a${'b' * 41}'}));
    });

    test('params of the wrong container type', () {
      // BUG: low. "params": "x" or {} throws a TypeError (not FormatException) from parse.
      for (final p in [
        'x',
        {'a': 1},
        5,
      ]) {
        expect(() => CommunitySkill.parse(valid({'params': p})), throwsA(isA<FormatException>()), reason: 'params=$p');
      }
    });

    test('malformed optional fields are rejected at parse time, not later', () {
      // BUG: medium. parse() accepts manifests whose optional fields have the
      // wrong type; the getters then throw TypeError when the skill list,
      // install dialog or tool spec is built (author/version/examples/params).
      final cases = <String, Map<String, dynamic>>{
        'author number': valid({'author': 5}),
        'version number': valid({'version': 2}),
        'examples string': valid({'examples': 'foo'}),
        'param description number': valid({
          'params': [
            {'name': 'a', 'description': 5},
          ],
        }),
        'param required string': valid({
          'params': [
            {'name': 'a', 'required': 'yes'},
          ],
        }),
        'steps non-map': valid({
          'steps': ['summarize'],
        })..remove('prompt'),
        'steps missing skill': valid({
          'steps': [
            {'args': {}},
          ],
        })..remove('prompt'),
        'steps args list': valid({
          'steps': [
            {'skill': 'summarize', 'args': []},
          ],
        })..remove('prompt'),
        'steps empty': valid({'steps': []})..remove('prompt'),
      };
      final leaked = <String>[];
      cases.forEach((name, m) {
        try {
          final c = CommunitySkill.parse(m);
          try {
            c.author;
            c.version;
            c.examples;
            c.toToolSpec();
            c.calls;
          } catch (e) {
            leaked.add('$name: accepted by parse, getter throws ${e.runtimeType}');
          }
          if (name == 'steps empty' || name == 'steps missing skill') leaked.add('$name: accepted by parse');
        } on FormatException {
          // good
        }
      });
      expect(leaked, isEmpty);
    });

    test('param types map to schema types', () {
      final c = CommunitySkill.parse(
        valid({
          'params': [
            {'name': 'a', 'type': 'number', 'description': 'd'},
            {'name': 'b', 'type': 'integer', 'description': 'd'},
            {'name': 'c', 'type': 'boolean', 'description': 'd'},
            {'name': 'd', 'type': 'list', 'description': 'd'},
            {'name': 'e', 'type': 'image', 'description': 'd'},
            {'name': 'f', 'type': 'audio', 'description': 'd'},
            {'name': 'g', 'type': 'weird', 'description': 'd', 'required': false},
            {'name': 'h'},
          ],
        }),
      );
      final props = c.toToolSpec().parameters['properties'] as Map;
      expect((props['a'] as Map)['type'], 'number');
      expect((props['b'] as Map)['type'], 'integer');
      expect((props['c'] as Map)['type'], 'boolean');
      expect((props['d'] as Map)['type'], 'array');
      expect((props['e'] as Map)['type'], 'string');
      expect((props['g'] as Map)['type'], 'string');
      expect(c.toToolSpec().parameters['required'], isNot(contains('g')));
      expect(c.toToolSpec().parameters['required'], contains('h'));
    });

    test('duplicate param names are rejected', () {
      // BUG: low. Two params with the same name are accepted; the second silently wins.
      rejects(
        valid({
          'params': [
            {'name': 'a', 'description': 'x'},
            {'name': 'a', 'description': 'y'},
          ],
        }),
      );
    });

    test('a chain that calls itself is rejected', () {
      // BUG: medium. {"id":"loop","steps":[{"skill":"c_loop"}]} is accepted and
      // recurses forever when run. Same for chains calling unknown skills.
      final m = valid({
        'id': 'loop',
        'steps': [
          {'skill': 'c_loop', 'args': {}},
        ],
      })..remove('prompt');
      rejects(m);
    });

    test('chain calls are listed for the install dialog', () {
      final c = CommunitySkill.parse(
        valid({
          'steps': [
            {
              'skill': 'summarize',
              'args': {'text': '{{topic}}'},
            },
            {
              'skill': 'redact_pii',
              'args': {'text': '{{prev.result}}'},
            },
          ],
        })..remove('prompt'),
      );
      expect(c.calls, ['summarize', 'redact_pii']);
    });
  });

  group('community skills: run', () {
    test('prompt skill: text, json, checklist outputs', () async {
      final s = await _services();
      final text = CommunitySkill.parse(sampleCommunitySkills[1]);
      final r = await _run(s, text, {'topic': 'gravity'});
      expect(r.isError, isFalse);
      expect(r.cards.single.type, 'text');

      final cl = CommunitySkill.parse(sampleCommunitySkills[2]);
      final r2 = await _run(s, cl, {'trip': 'Norway'});
      expect(r2.cards.single.type, anyOf('checklist', 'text'));

      final js = CommunitySkill.parse({
        'schema': CommunitySkill.schema,
        'id': 'jsonny',
        'name': 'Jsonny',
        'description': 'd',
        'prompt': {'system': 'Reply JSON', 'user': '{{x}}'},
        'output': 'json',
        'params': [
          {'name': 'x', 'type': 'string', 'description': 'd'},
        ],
      });
      final r3 = await _run(s, js, {'x': 'hi'});
      expect(r3.cards.single.type, 'kv');
      expect(r3.isError, isFalse);
    });

    test('prompt skill with missing / bad args does not throw', () async {
      final s = await _services();
      final failures = <String>[];
      await Future.wait([
        for (final m in sampleCommunitySkills)
          for (final a in _garbageArgs(CommunitySkill.parse(m)))
            for (final atts in [
              const <Attachment>[],
              const [_image, _audio],
            ])
              () async {
                try {
                  await _run(s, CommunitySkill.parse(m), a, atts: atts);
                } catch (e) {
                  failures.add('${m['id']} ${_short(a)}: ${'$e'.split('\n').first}');
                }
              }(),
      ]);
      expect(failures, isEmpty);
    }, timeout: const Timeout(Duration(minutes: 3)));

    test('template placeholders are filled, including with spaces and missing args', () async {
      final s = await _services();
      final seen = <String>[];
      final c = CommunitySkill.parse({
        'schema': CommunitySkill.schema,
        'id': 'tmpl',
        'name': 'T',
        'description': 'd',
        'params': [
          {'name': 'a', 'type': 'string', 'description': 'd'},
          {'name': 'b', 'type': 'string', 'description': 'd', 'required': false},
        ],
        'prompt': {'system': 'S {{ a }}', 'user': 'U {{a}} {{b}} {{c}}'},
      });
      final ctx = _Ctx(s);
      // wrap to capture
      final spy = _SpyCtx(ctx, seen);
      await c.run({'a': 'one'}, spy);
      expect(seen, ['S one|U one  ']);
    });

    test('image params are passed to vision only for image attachments', () async {
      final s = await _services();
      final c = CommunitySkill.parse(sampleCommunitySkills[0]);
      final seen = <String>[];
      final spy = _SpyCtx(_Ctx(s, atts: const [_image, _audio]), seen);
      await c.run({'photo': 'a2', 'ingredients': 'eggs'}, spy);
      expect(seen.single, contains('eggs'));
      expect(spy.lastImages, ['/nonexistent/qa.png']);
      spy.lastImages = [];
      await c.run({'photo': 'a1'}, spy);
      expect(spy.lastImages, isEmpty);
    });

    test('chain skill runs its steps and passes data', () async {
      final s = await _services();
      final c = CommunitySkill.parse({
        'schema': CommunitySkill.schema,
        'id': 'safe_calc',
        'name': 'Safe calc',
        'description': 'd',
        'params': [
          {'name': 'expr', 'type': 'string', 'description': 'd'},
        ],
        'steps': [
          {
            'skill': 'calculate',
            'args': {'expression': '{{expr}}'},
          },
          {
            'skill': 'calculate',
            'args': {'expression': '{{prev.result}}+1'},
          },
        ],
      });
      final r = await _run(s, c, {'expr': '2*3'});
      expect(r.isError, isFalse);
      expect(((r.data['result'] as Map)['result']), '7');
      final bad = await _run(s, c, {'expr': 'oops'});
      expect(bad.isError, isTrue);
    });

    test('chain with multiple params and numeric arg values', () async {
      final s = await _services();
      final c = CommunitySkill.parse({
        'schema': CommunitySkill.schema,
        'id': 'two_args',
        'name': 'Two',
        'description': 'd',
        'params': [
          {'name': 'a', 'type': 'string', 'description': 'd'},
          {'name': 'b', 'type': 'string', 'description': 'd'},
        ],
        'steps': [
          {
            'skill': 'calculate',
            'args': {'expression': '{{a}}+{{b}}'},
          },
        ],
      });
      final r = await _run(s, c, {'a': '2', 'b': '3'});
      expect(r.isError, isFalse);
      expect(((r.data['result'] as Map)['result']), '5');
    });

    test('chain keeps the permission gate of the skills it calls', () async {
      final s = await _services();
      final c = CommunitySkill.parse({
        'schema': CommunitySkill.schema,
        'id': 'dialer',
        'name': 'Dialer',
        'description': 'd',
        'params': [
          {'name': 'n', 'type': 'string', 'description': 'd'},
        ],
        'steps': [
          {
            'skill': 'call_number',
            'args': {'number': '{{n}}'},
          },
        ],
      });
      await s.skills.install(c);
      final chat = ChatController(s)..onConfirm = (_, _) async => false;
      await chat.runSkill(c, {'n': '123'});
      final step = chat.messages.last.steps.single;
      expect(step.status, StepStatus.failed);
      expect('${step.result['error']}', contains('Declined'));
      final chat2 = ChatController(s);
      var asked = 0;
      chat2.onConfirm = (k, a) async {
        asked++;
        return true;
      };
      await chat2.runSkill(c, {'n': '123'});
      expect(asked, 1);
      expect(chat2.messages.last.steps.single.status, StepStatus.done);
    });

    test('chain through the agent: an unknown skill inside a chain fails cleanly', () async {
      final s = await _services();
      final c = CommunitySkill.parse({
        'schema': CommunitySkill.schema,
        'id': 'ghost',
        'name': 'Ghost',
        'description': 'd',
        'steps': [
          {'skill': 'not_a_skill', 'args': {}},
        ],
      });
      final r = await _run(s, c, {});
      expect(r.isError, isTrue);
    });

    test('chain with a list-typed param stringifies sensibly', () async {
      // BUG: low. A "list" param value becomes "[a, b]" (Dart toString) in the
      // chain input instead of newline-joined items.
      final s = await _services();
      final c = CommunitySkill.parse({
        'schema': CommunitySkill.schema,
        'id': 'lister',
        'name': 'L',
        'description': 'd',
        'params': [
          {'name': 'items', 'type': 'list', 'description': 'd'},
        ],
        'steps': [
          {
            'skill': 'calculate',
            'args': {'expression': '{{items}}'},
          },
        ],
      });
      final ctx = _Ctx(s);
      await c.run({
        'items': ['1', '2'],
      }, ctx);
      // the filled value must not contain Dart list brackets
      final r = await _run(s, c, {
        'items': ['1'],
      });
      expect('${r.data}', isNot(contains('[1]')));
    });
  });

  group('community skills: install / fetch', () {
    test('install, persist, reload, uninstall', () async {
      final store = _DirStore(_tmp.path);
      final s = await _services(store: store);
      final c = CommunitySkill.parse(sampleCommunitySkills[1]);
      await s.skills.install(c);
      await s.skills.install(c); // reinstall replaces
      expect(s.skills.community, hasLength(1));
      final again = await _services(store: store);
      expect(again.skills.community.single.id, 'c_explain_like_five');
      expect(again.skills.byId('c_explain_like_five'), isNotNull);
      expect(again.skills.isEnabled(again.skills.byId('c_explain_like_five')!), isTrue);
      await again.skills.uninstall(again.skills.community.single);
      final last = await _services(store: store);
      expect(last.skills.community, isEmpty);
    });

    test('installed community skill is offered as a tool and runs through the agent', () async {
      final s = await _services();
      await s.skills.install(CommunitySkill.parse(sampleCommunitySkills[1]));
      final chat = ChatController(s);
      await chat.runSkill(s.skills.byId('c_explain_like_five')!, {'topic': 'tides'});
      expect(chat.messages.last.steps.single.status, StepStatus.done);
      expect(chat.messages.last.steps.single.via, 'direct');
    });

    test('disabling an installed community skill removes it from enabled', () async {
      final s = await _services();
      await s.skills.install(CommunitySkill.parse(sampleCommunitySkills[1]));
      final k = s.skills.byId('c_explain_like_five')!;
      await s.skills.setEnabled(k, false);
      expect(s.skills.enabled, isNot(contains(k)));
    });

    Future<Object?> fetch(String url, http.Response Function(http.Request) handler) async {
      final s = await _services();
      try {
        return await http.runWithClient(() => s.skills.fetchCommunity(url), () => MockClient((r) async => handler(r)));
      } catch (e) {
        return e;
      }
    }

    final good = jsonEncode(sampleCommunitySkills[1]);

    test('fetch ok', () async {
      final r = await fetch('https://example.com/s.json', (_) => http.Response(good, 200));
      expect(r, isA<CommunitySkill>());
      expect((r as CommunitySkill).sourceUrl, 'https://example.com/s.json');
    });

    test('fetch trims the url', () async {
      final r = await fetch('  https://example.com/s.json \n', (_) => http.Response(good, 200));
      expect(r, isA<CommunitySkill>());
    });

    test('fetch rejects non-https schemes before any request', () async {
      var calls = 0;
      for (final u in [
        'http://example.com/s.json',
        'ftp://example.com/s',
        'file:///etc/passwd',
        'javascript:1',
        '//example.com/s.json',
        'example.com/s.json',
        '',
        '   ',
      ]) {
        final r = await fetch(u, (_) {
          calls++;
          return http.Response(good, 200);
        });
        expect(r, isA<FormatException>(), reason: '"$u" -> $r');
      }
      expect(calls, 0);
      final r = await fetch('http://example.com/s.json', (_) => http.Response(good, 200));
      expect((r as FormatException).message, contains('https'));
    });

    test('fetch rejects uppercase scheme? (HTTPS is the same scheme)', () async {
      final r = await fetch('HTTPS://example.com/s.json', (_) => http.Response(good, 200));
      expect(r, isA<CommunitySkill>());
    });

    test('fetch HTTP errors', () async {
      for (final code in [301, 403, 404, 500]) {
        final r = await fetch('https://example.com/s.json', (_) => http.Response('x', code));
        expect(r, isA<FormatException>());
        expect((r as FormatException).message, 'HTTP $code');
      }
    });

    test('fetch size limit is 64 KB', () async {
      String padded(int bytes) {
        final m = Map<String, dynamic>.from(sampleCommunitySkills[1])..['x'] = '';
        final base = utf8.encode(jsonEncode(m)).length;
        m['x'] = 'a' * (bytes - base);
        return jsonEncode(m);
      }

      final exactly = padded(64 * 1024);
      expect(utf8.encode(exactly).length, 64 * 1024);
      expect(await fetch('https://example.com/s.json', (_) => http.Response(exactly, 200)), isA<CommunitySkill>());
      final over = padded(64 * 1024 + 1);
      final r = await fetch('https://example.com/s.json', (_) => http.Response(over, 200));
      expect(r, isA<FormatException>());
      expect((r as FormatException).message, contains('64 KB'));
      final huge = await fetch('https://example.com/s.json', (_) => http.Response('a' * (5 * 1024 * 1024), 200));
      expect((huge as FormatException).message, contains('64 KB'));
    });

    test('fetch rejects non-object, invalid JSON, wrong encoding, empty body', () async {
      for (final body in ['[]', '"str"', '42', 'null', 'true', '{', 'not json', '', '<html></html>']) {
        final r = await fetch('https://example.com/s.json', (_) => http.Response(body, 200));
        expect(r, isA<FormatException>(), reason: 'body "$body" -> $r');
      }
      final r = await fetch('https://example.com/s.json', (_) => http.Response.bytes([0xff, 0xfe, 0x7b, 0x7d], 200));
      expect(r, isA<FormatException>());
      final r2 = await fetch('https://example.com/s.json', (_) => http.Response('[]', 200));
      expect((r2 as FormatException).message, contains('JSON object'));
    });

    test('fetch rejects invalid manifests with the validator message', () async {
      final bad = Map<String, dynamic>.from(sampleCommunitySkills[1])..['id'] = 'X';
      final r = await fetch('https://example.com/s.json', (_) => http.Response(jsonEncode(bad), 200));
      expect(r, isA<FormatException>());
      expect((r as FormatException).message, contains('id'));
    });

    test('fetch: JSON with duplicate/odd keys and BOM', () async {
      // BUG: low. A UTF-8 BOM (common from Windows editors/GitHub raw files
      // saved by some tools) makes jsonDecode fail with a cryptic message.
      final r = await fetch(
        'https://example.com/s.json',
        (_) => http.Response.bytes([0xEF, 0xBB, 0xBF, ...utf8.encode(good)], 200),
      );
      expect(r, isA<CommunitySkill>());
    });

    test('fetch: non-network errors surface (timeouts/SocketException are not swallowed)', () async {
      final s = await _services();
      final r = await http
          .runWithClient(
            () => s.skills.fetchCommunity('https://example.com/s.json'),
            () => MockClient((_) async => throw http.ClientException('boom')),
          )
          .then<Object?>((v) => v, onError: (Object e) => e);
      expect(r, isA<http.ClientException>());
    });
  });

  // -------------------------------------------------------------------------
  group('agent integration', () {
    test('runSkill: every built-in finishes with a status and persists', () async {
      final s = await _services();
      final problems = <String>[];
      for (final k in s.skills.builtIns) {
        final chat = ChatController(s)..onConfirm = (_, _) async => true;
        await chat.runSkill(k, _sensible[k.id]!, attachments: const [_audio, _image, _image2, _doc]);
        final step = chat.messages.last.steps.single;
        if (step.status != StepStatus.done && step.status != StepStatus.failed) problems.add('${k.id}: ${step.status}');
        if (step.status == StepStatus.failed && _looksLikeRawException('${step.result['error']}')) {
          problems.add('${k.id}: raw error ${step.result['error']}');
        }
        if (step.status == StepStatus.failed && !_demoLimited.contains(k.id)) {
          problems.add('${k.id}: failed ${step.result['error']}');
        }
      }
      expect(problems, isEmpty);
    });

    test('"try it" shows the result: skills without cards must return a summary', () async {
      // BUG: medium. SkillsScreen -> runSkill shows only result['summary'] (or
      // "Done." when there are no cards). Skills such as describe_image,
      // detect_language, find_contact, storage_status and read_clipboard return
      // their answer in other keys with no card, so the user sees only "Done.".
      final s = await _services();
      final lost = <String>[];
      for (final k in s.skills.builtIns) {
        if (_demoLimited.contains(k.id)) continue;
        final chat = ChatController(s)..onConfirm = (_, _) async => true;
        await chat.runSkill(k, _sensible[k.id]!, attachments: const [_audio, _image, _image2, _doc]);
        final step = chat.messages.last.steps.single;
        if (step.status != StepStatus.done) continue;
        final demo = step.result['demo'] == true;
        if (step.cards.isEmpty && step.result['summary'] == null && !demo) lost.add(k.id);
      }
      expect(lost, isEmpty, reason: 'answer hidden behind "Done.": $lost');
    });

    test('first-time confirmation policy is remembered per skill', () async {
      final s = await _services();
      var asked = 0;
      final chat = ChatController(s)
        ..onConfirm = (_, _) async {
          asked++;
          return true;
        };
      final k = s.skills.byId('find_contact')!;
      await chat.runSkill(k, {'name': 'Sam'});
      await chat.runSkill(k, {'name': 'Sam'});
      expect(asked, 1);
      final c = s.skills.byId('call_number')!;
      await chat.runSkill(c, {'number': '1'});
      await chat.runSkill(c, {'number': '1'});
      expect(asked, 3);
    });

    test('declined skills report declined, never run', () async {
      final s = await _services();
      final chat = ChatController(s)..onConfirm = (_, _) async => false;
      for (final id in [
        'call_number',
        'draft_text_message',
        'draft_email',
        'create_event',
        'find_contact',
        'open_url',
        'read_clipboard',
      ]) {
        await chat.runSkill(s.skills.byId(id)!, _sensible[id]!);
        expect(chat.messages.last.steps.single.status, StepStatus.declined, reason: id);
      }
    });
  });

  // -------------------------------------------------------------------------
  group('UI: cards render at 360x690', () {
    Future<void> expectRenders(
      WidgetTester tester,
      AppState state,
      UiCard card,
      String label, {
      Brightness b = Brightness.light,
      double scale = 1,
    }) async {
      await tester.pumpWidget(_host(state, ResultCard(card), b: b, textScale: scale));
      await tester.pump(const Duration(milliseconds: 50));
      final ex = tester.takeException();
      expect(ex, isNull, reason: '$label (${card.type}) -> $ex');
    }

    testWidgets('all cards produced by every skill (sensible + hostile args)', (tester) async {
      _phone(tester);
      final s = (await tester.runAsync(_services))!;
      final cards = (await tester.runAsync(() => _collectCards(s)))!;
      expect(cards, isNotEmpty);
      final state = AppState(s);
      final seen = <String>{};
      final failures = <String>[];
      for (final (label, card) in cards) {
        final key = jsonEncode(card.toJson());
        if (!seen.add(key)) continue;
        await tester.pumpWidget(_host(state, ResultCard(card)));
        await tester.pump(const Duration(milliseconds: 20));
        final ex = tester.takeException();
        if (ex != null) failures.add('$label ${card.type} "${card.title}": ${'$ex'.split('\n').first}');
      }
      expect(failures, isEmpty);
    });

    testWidgets('hostile hand-made cards (long, empty, ragged, huge)', (tester) async {
      _phone(tester);
      final s = (await tester.runAsync(_services))!;
      final state = AppState(s);
      final long = 'Supercalifragilisticexpialidocious' * 8;
      final cards = <UiCard>[
        UiCard('text', title: long, data: {'text': long, 'copy': true}),
        const UiCard('text', data: {}),
        UiCard('text', data: {'text': '${'😀' * 500}${'\n' * 50}مرحبا بالعالم'}),
        UiCard('kv', title: 'kv', data: {long: long, 'k': '', '': 'v'}),
        const UiCard('kv', data: {}),
        UiCard(
          'table',
          title: 't',
          data: {
            'columns': ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H'],
            'rows': [
              [long, long, long, long, long, long, long, long],
              ['1'],
              <String>[],
              ['1', '2', '3', '4', '5', '6', '7', '8', '9', '10'],
            ],
          },
        ),
        const UiCard('table', data: {'columns': <String>[], 'rows': <List<String>>[]}),
        UiCard(
          'table',
          data: {
            'columns': ['A'],
            'rows': List.generate(200, (i) => ['row $i']),
          },
        ),
        UiCard('checklist', title: 'c', data: {'items': List.generate(300, (i) => 'item $i $long')}),
        const UiCard('checklist', data: {'items': <String>[]}),
        UiCard(
          'transcript',
          data: {
            'segments': [
              {'speaker': 0, 'start': 0.0, 'end': 5, 'text': long * 3},
              {'speaker': 7, 'start': 5.0, 'end': 4000.5, 'text': ''},
            ],
            'duration': 4000.5,
          },
        ),
        const UiCard('transcript', data: {'segments': <Map>[], 'duration': null}),
        UiCard('tags', data: {'tags': List.generate(60, (i) => 'tag$i$long'), 'large': true}),
        const UiCard('tags', data: {'tags': <String>[]}),
        UiCard(
          'bars',
          title: 'b',
          data: {
            'labels': List.generate(40, (i) => 'label $i $long'),
            'values': List<double>.generate(40, (i) => i * 1e9),
          },
        ),
        const UiCard(
          'bars',
          data: {
            'labels': ['a', 'b', 'c'],
            'values': [1.0],
          },
        ),
        const UiCard('bars', data: {'labels': <String>[], 'values': <double>[]}),
        const UiCard(
          'bars',
          data: {
            'labels': ['a', 'b'],
            'values': [0.0, 0.0],
          },
        ),
        const UiCard(
          'bars',
          data: {
            'labels': ['a', 'b'],
            'values': [-5.0, 3.0],
          },
        ),
        UiCard(
          'timeline',
          data: {
            'items': [
              {'time': long, 'text': long},
              {'time': '', 'text': ''},
              {'time': '9:00', 'text': 'x'},
            ],
          },
        ),
        const UiCard('timeline', data: {'items': <Map>[]}),
        UiCard('file', title: 'f', data: {'path': '/nonexistent/$long.srt', 'kind': 'document', 'preview': long * 20}),
        const UiCard('file', title: 'f', data: {'path': null, 'kind': 'audio'}),
        const UiCard('file', title: 'f', data: {'path': '/nonexistent/a.wav', 'kind': 'audio'}),
        const UiCard('image', title: 'i', data: {'path': '/nonexistent/x.png'}),
        const UiCard('image', title: 'i', data: {'path': 'null'}),
        UiCard(
          'link',
          data: {
            'platform': 'youtube',
            'kind': 'video',
            'title': long,
            'author': long,
            'description': long * 5,
            'url': 'https://youtu.be/x',
            'rich': true,
          },
        ),
        const UiCard(
          'link',
          data: {'platform': 'web', 'kind': 'page', 'title': 't', 'url': 'https://x.y', 'rich': false},
        ),
        const UiCard('mystery', data: {'text': 'unknown card type falls back'}),
      ];
      final failures = <String>[];
      for (final b in Brightness.values) {
        for (final (i, c) in cards.indexed) {
          await tester.pumpWidget(_host(state, ResultCard(c), b: b));
          await tester.pump(const Duration(milliseconds: 30));
          final ex = tester.takeException();
          if (ex != null) failures.add('#$i ${c.type} ${b.name}: ${'$ex'.split('\n').first}');
        }
      }
      expect(failures, isEmpty);
    });

    testWidgets('cards survive 1.5x text scale', (tester) async {
      // BUG candidate: accessibility font scaling may overflow in rows.
      _phone(tester);
      final s = (await tester.runAsync(_services))!;
      final state = AppState(s);
      final cards = [
        const UiCard(
          'kv',
          title: 'Photo',
          data: {'Kind': 'photo', 'Aesthetics': 'better than 74% of photos', 'Faces': '2'},
        ),
        const UiCard(
          'table',
          title: 'Found',
          data: {
            'columns': ['Type', 'Placeholder'],
            'rows': [
              ['EMAIL', '[EMAIL_1]'],
            ],
          },
        ),
        const UiCard(
          'tags',
          title: 'Emoji',
          data: {
            'tags': ['a', 'b'],
            'large': true,
          },
        ),
        const UiCard(
          'bars',
          title: 'Scores',
          data: {
            'labels': ['qa.png', 'qb.png'],
            'values': [74.0, 12.0],
          },
        ),
        const UiCard(
          'timeline',
          title: 'Upcoming',
          data: {
            'items': [
              {'time': '2026-11-02 15:00', 'text': 'Design review with the whole team'},
            ],
          },
        ),
        const UiCard(
          'file',
          title: 'Subtitles (.srt)',
          data: {'path': '/x/a.srt', 'kind': 'document', 'preview': '1\n00:00'},
        ),
        const UiCard(
          'link',
          data: {'platform': 'youtube', 'kind': 'video', 'title': 'T', 'url': 'https://x.y', 'rich': true},
        ),
        const UiCard(
          'transcript',
          title: 'Transcript',
          data: {
            'segments': [
              {'speaker': 0, 'start': 0.0, 'end': 5, 'text': 'hello'},
            ],
            'duration': 5,
          },
        ),
        const UiCard(
          'checklist',
          title: 'Action items',
          data: {
            'items': ['Priya · update the deck · Monday'],
          },
        ),
      ];
      final failures = <String>[];
      for (final c in cards) {
        await tester.pumpWidget(_host(state, ResultCard(c), textScale: 1.6));
        await tester.pump(const Duration(milliseconds: 30));
        final ex = tester.takeException();
        if (ex != null) failures.add('${c.type}: ${'$ex'.split('\n').first}');
      }
      expect(failures, isEmpty);
    });

    testWidgets('a real skill result renders in the chat host', (tester) async {
      _phone(tester);
      final s = (await tester.runAsync(_services))!;
      final state = AppState(s);
      final r = (await tester.runAsync(() => _run(s, s.skills.byId('redact_pii')!, _sensible['redact_pii']!)))!;
      await tester.pumpWidget(_host(state, Column(children: [for (final c in r.cards) ResultCard(c)])));
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.textContaining('[EMAIL_1]'), findsWidgets);
      expect(tester.takeException(), isNull);
    });

    testWidgets('expectRenders helper sanity (empty text card)', (tester) async {
      _phone(tester);
      final s = (await tester.runAsync(_services))!;
      await expectRenders(tester, AppState(s), const UiCard('text', data: {'text': 'hi'}), 'basic');
    });
  });

  // -------------------------------------------------------------------------
  group('UI: skills screen and recipe editor', () {
    Future<(AppState, AppServices)> boot(WidgetTester tester, {bool tall = false}) async {
      _phone(tester);
      if (tall) tester.view.physicalSize = const Size(360, 3000);
      final s = (await tester.runAsync(_services))!;
      final state = AppState(s);
      await _pumpScreen(tester, state);
      return (state, s);
    }

    testWidgets('lists skills by category, toggles, searches', (tester) async {
      final (_, s) = await boot(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('transcribe audio'), findsOneWidget);
      expect(find.byType(HandSwitch), findsWidgets);

      final before = s.skills.enabled.length;
      await tester.tap(find.byType(HandSwitch).first);
      await _settle(tester);
      expect(s.skills.enabled.length, before - 1);
      expect(s.settings.disabledSkills, hasLength(1));
      await tester.tap(find.byType(HandSwitch).first);
      await _settle(tester);
      expect(s.skills.enabled.length, before);

      await tester.enterText(find.byType(TextField).first, 'timer');
      await _settle(tester);
      expect(find.text('set a timer'), findsOneWidget);
      expect(find.text('transcribe audio'), findsNothing);
      await tester.enterText(find.byType(TextField).first, 'zzzzqqq');
      await _settle(tester);
      expect(find.text('set a timer'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('try it: sheet shows params and runs the skill in chat', (tester) async {
      final (state, _) = await boot(tester);
      await _openSkill(tester, 'convert units');
      await _reveal(tester, find.text('try it', findRichText: true));
      expect(tester.takeException(), isNull);
      await _enter(tester, 'value', '5');
      await _enter(tester, 'from', 'miles');
      await _enter(tester, 'to', 'km');
      await _reveal(tester, find.text('run it in chat'));
      await tester.tap(find.text('run it in chat'));
      await _settle(tester);
      await _settle(tester);
      final msgs = state.chat.messages;
      expect(msgs, isNotEmpty);
      expect(msgs.last.steps.single.skillId, 'convert_units');
      expect(msgs.last.steps.single.status, StepStatus.done);
      expect(msgs.last.steps.single.result['result'], '8.04672');
      expect(tester.takeException(), isNull);
    });

    testWidgets('try it with bad input does not crash', (tester) async {
      final (state, _) = await boot(tester);
      await _openSkill(tester, 'set an alarm');
      await _enter(tester, 'hour', 'abc');
      await _enter(tester, 'minute', '-7');
      await _reveal(tester, find.text('run it in chat'));
      await tester.tap(find.text('run it in chat'));
      await _settle(tester);
      await _settle(tester);
      expect(state.chat.messages, isNotEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('recipes tab lists built-ins and opens the editor; save and delete a recipe', (tester) async {
      final (_, s) = await boot(tester, tall: true);
      await tester.tap(find.text('recipes'));
      await _settle(tester);
      for (final r in builtInRecipes) {
        expect(find.text(r.name.toLowerCase()), findsOneWidget, reason: r.name);
      }
      expect(find.byTooltip('Delete'), findsNothing, reason: 'built-ins cannot be deleted from the UI');
      expect(tester.takeException(), isNull);

      await tester.tap(find.text('new recipe'));
      await _settle(tester);
      await _reveal(tester, find.text('save the recipe'));
      // empty save is refused
      await tester.tap(find.text('save the recipe'));
      await _settle(tester);
      expect(s.skills.recipes.where((r) => !r.builtIn), isEmpty);

      await tester.enterText(find.widgetWithText(TextField, 'name it'), 'QA chain');
      await _reveal(tester, find.text('add a step'));
      await tester.tap(find.text('add a step'));
      await _settle(tester);
      await _reveal(tester, find.text('transcribe audio'));
      await tester.tap(find.text('transcribe audio').last);
      await _settle(tester);
      await _reveal(tester, find.text('save the recipe'));
      await tester.tap(find.text('save the recipe'));
      await _settle(tester);
      await _settle(tester);
      final saved = s.skills.recipes.where((r) => !r.builtIn).toList();
      expect(saved, hasLength(1));
      expect(saved.single.id, 'qa_chain');
      expect(saved.single.steps.single.skillId, 'transcribe_audio');
      expect(saved.single.steps.single.args['audio'], '{{input}}');
      await _refreshSegment(tester, 'recipes');
      await _reveal(tester, find.byTooltip('Delete'));
      await tester.tap(find.byTooltip('Delete'));
      await _settle(tester);
      expect(s.skills.recipes.where((r) => !r.builtIn), isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('recipes list refreshes immediately after a recipe is saved or deleted', (tester) async {
      // BUG: medium. `_Recipes` is a const widget that reads the registry via
      // getInheritedWidgetOfExactType (no dependency), so SkillsScreen's
      // ListenableBuilder never rebuilds it: a recipe saved from the editor does
      // not appear (and a deleted one does not disappear) until the user
      // switches tabs and back. Same for `_Community` install/remove.
      final (_, s) = await boot(tester, tall: true);
      await tester.tap(find.text('recipes'));
      await _settle(tester);
      const r = Recipe(
        id: 'fresh',
        name: 'Fresh one',
        description: 'd',
        steps: [
          RecipeStep('summarize', {'text': '{{input}}'}),
        ],
      );
      await tester.runAsync(() => s.skills.saveRecipe(r));
      await _settle(tester);
      expect(find.text('fresh one'), findsOneWidget, reason: 'saved recipe is missing from the list');
      await _refreshSegment(tester, 'recipes');
      expect(find.text('fresh one'), findsOneWidget);
      await tester.runAsync(() => s.skills.deleteRecipe(r));
      await _settle(tester);
      expect(find.text('fresh one'), findsNothing, reason: 'deleted recipe still listed');
    });

    testWidgets('community list refreshes immediately after install / remove', (tester) async {
      // BUG: medium. Same const-widget problem in `_Community`.
      final (_, s) = await boot(tester, tall: true);
      await tester.tap(find.text('community'));
      await _settle(tester);
      final skill = CommunitySkill.parse(sampleCommunitySkills[0]);
      await tester.runAsync(() => s.skills.install(skill));
      await _settle(tester);
      expect(
        find.text('installed', findRichText: true),
        findsOneWidget,
        reason: 'installed section missing after install',
      );
      await tester.runAsync(() => s.skills.uninstall(skill));
      await _settle(tester);
      expect(find.text('installed', findRichText: true), findsNothing, reason: 'removed skill still listed');
    });

    testWidgets('editing a recipe whose step skill no longer exists drops the step silently', (tester) async {
      // BUG: low. RecipeEditor.didChangeDependencies skips unknown step skills,
      // so saving the edit deletes steps (data loss) without warning.
      _phone(tester);
      tester.view.physicalSize = const Size(360, 3000);
      final s = (await tester.runAsync(_services))!;
      const r = Recipe(
        id: 'gone',
        name: 'Gone',
        description: 'd',
        steps: [
          RecipeStep('summarize', {'text': '{{input}}'}),
          RecipeStep('removed_skill', {'x': '1'}),
        ],
      );
      await tester.runAsync(() => s.skills.saveRecipe(r));
      await _pumpScreen(tester, AppState(s));
      await tester.tap(find.text('recipes'));
      await _settle(tester);
      await _reveal(tester, find.byTooltip('Edit'));
      await tester.tap(find.byTooltip('Edit'));
      await _settle(tester);
      await _reveal(tester, find.text('save the recipe'));
      await tester.tap(find.text('save the recipe'));
      await _settle(tester);
      await _settle(tester);
      final after = s.skills.recipes.firstWhere((x) => x.id == 'gone');
      expect(after.steps, hasLength(2));
    });

    testWidgets('community tab: featured list, installed list, remove, invalid url toast', (tester) async {
      final (_, s) = await boot(tester, tall: true);
      await tester.tap(find.text('community'));
      await _settle(tester);
      expect(find.text('fridge chef'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.runAsync(() => s.skills.install(CommunitySkill.parse(sampleCommunitySkills[0])));
      await _refreshSegment(tester, 'community');
      expect(find.text('fridge chef'), findsOneWidget);
      await _reveal(tester, find.byTooltip('Remove'));
      await tester.tap(find.byTooltip('Remove'));
      await _settle(tester);
      expect(s.skills.community, isEmpty);

      await tester.enterText(find.widgetWithText(TextField, 'https://…/skill.json'), 'http://insecure.example/s.json');
      await tester.tap(find.text('add'));
      await _settle(tester);
      expect(find.textContaining('Only https'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('install review sheet fits a 360x690 screen and its button is reachable', (tester) async {
      // BUG: medium. confirmDialog() is a non-scrollable modal bottom sheet
      // (max height 9/16 of the screen); the community install review (long
      // description + author + "Calls: ..." + source URL) overflows and the
      // Install button is pushed off screen.
      final (_, s) = await boot(tester);
      await tester.tap(find.text('community'));
      await _settle(tester);
      await tester.tap(find.text('install').first);
      await _settle(tester);
      expect(find.textContaining('Install Fridge chef?'), findsOneWidget);
      final overflow = tester.takeException();
      expect(overflow, isNull, reason: 'bottom sheet overflowed: ${'$overflow'.split('\n').first}');
      final btn = find.byType(InkButton);
      expect(tester.getCenter(btn).dy, lessThan(690), reason: 'Install button is off screen');
      await tester.tap(btn);
      await _settle(tester);
      expect(s.skills.community, hasLength(1));
    });
  });
}

String _short(Map<String, dynamic> a) {
  final t = a.toString();
  return t.length > 60 ? '${t.substring(0, 60)}…' : t;
}

/// Captures what a skill asks the model.
class _SpyCtx implements SkillContext {
  _SpyCtx(this.inner, this.seen);
  final _Ctx inner;
  final List<String> seen;
  List<String> lastImages = [];

  @override
  Future<String> ask({
    required String system,
    required String prompt,
    List<String> imagePaths = const [],
    List<String> audioPaths = const [],
  }) {
    seen.add('$system|$prompt');
    lastImages = imagePaths;
    return inner.ask(system: system, prompt: prompt, imagePaths: imagePaths, audioPaths: audioPaths);
  }

  @override
  String get platform => inner.platform;
  @override
  bool get isDemo => inner.isDemo;
  @override
  List<Attachment> get attachments => inner.attachments;
  @override
  Attachment? attachment(Object? ref) => inner.attachment(ref);
  @override
  Future<Map<String, dynamic>> specialist(String modelId, String task, Map<String, dynamic> input) =>
      inner.specialist(modelId, task, input);
  @override
  Future<Map<String, dynamic>> device(String action, Map<String, dynamic> args) => inner.device(action, args);
  @override
  Future<List<Map<String, dynamic>>> searchKnowledge(String query, {int limit = 5}) =>
      inner.searchKnowledge(query, limit: limit);
  @override
  Future<int> addKnowledge(String title, String text, {String source = 'chat'}) =>
      inner.addKnowledge(title, text, source: source);
  @override
  Future<void> remember(String fact) => inner.remember(fact);
  @override
  Future<List<String>> recall(String query) => inner.recall(query);
  @override
  Future<bool> forget(String fact) => inner.forget(fact);
  @override
  Future<SkillResult> callSkill(String id, Map<String, dynamic> args) => inner.callSkill(id, args);
  @override
  Future<String?> saveTextFile(String name, String content) => inner.saveTextFile(name, content);
  @override
  Future<Map<String, dynamic>> previewLink(String url) => inner.previewLink(url);
  @override
  void progress(String message) => inner.progress(message);
}
