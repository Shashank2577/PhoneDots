// ignore_for_file: avoid_print
//
// QA visual/layout sweep. Every screen is pumped at four logical sizes, in
// light and dark, at text scale 1.0 and 1.6 and in every body Voice, with real
// fonts loaded (the default test font, Ahem, is far wider than any real face).
// Every FlutterError (RenderFlex overflow, unbounded constraints, exceptions)
// is collected and de-duplicated by kind + the source location of the widget
// that raised it. A screen's test fails when it produced any finding.
//
// Also checks accessibility basics (tap targets, text contrast, DoodleButton
// labels) and renders a handful of PNGs to the scratchpad for visual review.
//
// Expected to FAIL while the app has layout bugs; each failure message is the
// finding list. See the findings file written at the end of the run.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonedots/agent/conversation.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/app_state.dart';
import 'package:phonedots/core/models/model_catalog.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/features/chat/chat_screen.dart';
import 'package:phonedots/features/lab/lab_screen.dart';
import 'package:phonedots/features/memory/memory_screen.dart';
import 'package:phonedots/features/models/models_screen.dart';
import 'package:phonedots/features/privacy/privacy_screen.dart';
import 'package:phonedots/features/saved/saved_screen.dart';
import 'package:phonedots/features/settings/settings_screen.dart';
import 'package:phonedots/features/shell/shell.dart';
import 'package:phonedots/features/skills/recipe_editor.dart';
import 'package:phonedots/features/skills/skills_screen.dart';
import 'package:phonedots/features/voice/voice_screen.dart';
import 'package:phonedots/saved/saved_store.dart';
import 'package:phonedots/skills/community/community_skill.dart';
import 'package:phonedots/skills/recipes/recipe.dart';
import 'package:phonedots/skills/skill.dart';
import 'package:phonedots/theme/theme.dart';
import 'package:phonedots/widgets/hand.dart';

const _out = '/tmp/claude-0/-home-user-PhoneDots/7b83377f-5457-53f6-a319-4edf732ff42b/scratchpad/qa_ui';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const _lorem =
    'Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod tempor incididunt ut labore et dolore '
    'magna aliqua. Ut enim ad minim veniam, quis nostrud exercitation ullamco laboris nisi ut aliquip ex ea commodo.';
final _long = List.filled(8, _lorem).join(' ');
const _unbroken =
    'https://example.com/a/really/long/url/with/no/spaces/that/keeps/going/and/going/and/going/forever/and/ever/'
    'until/it/is/wider/than/any/phone/screen/ever/made?utm_source=share&utm_medium=android&utm_campaign=qa_sweep';
const _longWord = 'Pneumonoultramicroscopicsilicovolcanoconiosis_Supercalifragilisticexpialidocious_Antidisestablishmentarianism';

class Env {
  Env(this.services);
  final AppServices services;
}

Env? _seeded;
Env? _bare;

Future<Env> _seededEnv(WidgetTester t) async => _seeded ??= (await t.runAsync(() async {
  final s = await AppServices.create(store: MemoryJsonStore(), platform: 'demo');
  await _seed(s);
  return Env(s);
}))!;

Future<Env> _bareEnv(WidgetTester t) async => _bare ??= (await t.runAsync(() async {
  return Env(await AppServices.create(store: MemoryJsonStore(), platform: 'demo'));
}))!;

Future<void> _seed(AppServices s) async {
  for (final f in [
    'Likes tea',
    'My dentist is Dr. $_longWord and the appointment is every second Tuesday of the month at 9:15',
    _long,
    _unbroken,
    'short',
  ]) {
    await s.memory.add(f);
  }
  await s.knowledge.add('Expenses 2025', 'rent 1200 food 300 transport 80 ' * 40, source: 'expenses');
  await s.knowledge.add('A really long document title that goes on and on $_longWord', _long, source: 'notes');
  await s.knowledge.add(_longWord, _long, source: 'a_very_long_file_name_$_longWord.txt');
  await s.knowledge.add('Short', 'tiny', source: 'file.txt');
  await s.ledger.record('model download', 'gemma-4-e2b from huggingface.co/litert-community/gemma-4-E2B-it-litert-lm', network: true);
  await s.ledger.record('link preview', _unbroken, network: true);
  await s.ledger.record('skill', 'send_sms to $_longWord');
  for (var i = 0; i < 6; i++) {
    await s.ledger.record('skill', 'event $i');
  }

  final now = DateTime.now();
  final items = <SavedItem>[
    SavedItem(
      id: 's_done_long',
      created: now.subtract(const Duration(days: 40)),
      sharedText: 'Check this out $_unbroken',
      subject: _long,
      url: _unbroken,
      platform: 'youtube',
      kind: 'video',
      title: 'An extremely long title: $_long $_longWord',
      author: 'A channel with a very long name $_longWord',
      description: _long,
      body: List.filled(30, _long).join('\n\n'),
      summary: _long,
      points: [for (var i = 0; i < 9; i++) 'Point $i: $_lorem $_longWord'],
      tags: [for (var i = 0; i < 30; i++) 'tag-number-$i-${'x' * (i % 12)}', _longWord],
      collection: 'a collection with a long name $_longWord',
      status: SavedStatus.done,
      sources: ['caption', 'Jina Reader', 'YouTube Data API', 'description', 'transcript', _longWord],
    ),
    SavedItem(
      id: 's_done_short',
      created: now.subtract(const Duration(minutes: 3)),
      url: 'https://github.com/a/b',
      platform: 'github',
      title: 'Short',
      summary: 'Brief.',
      points: ['one'],
      tags: ['a'],
      collection: 'tech',
      status: SavedStatus.done,
    ),
    SavedItem(
      id: 's_reading',
      created: now,
      url: _unbroken,
      platform: 'x',
      title: _long,
      status: SavedStatus.reading,
    ),
    SavedItem(
      id: 's_summarising',
      created: now.subtract(const Duration(hours: 5)),
      url: 'https://medium.com/x',
      platform: 'medium',
      title: 'Summarising $_longWord',
      author: _long,
      description: _long,
      status: SavedStatus.summarising,
    ),
    SavedItem(
      id: 's_needs_model',
      created: now.subtract(const Duration(days: 2)),
      sharedText: _long,
      url: 'https://instagram.com/p/abc',
      platform: 'instagram',
      title: null,
      body: _long,
      tags: [for (var i = 0; i < 12; i++) 'tag$i'],
      status: SavedStatus.needsModel,
    ),
    SavedItem(
      id: 's_failed',
      created: now.subtract(const Duration(days: 9)),
      url: _unbroken,
      platform: 'linkedin',
      title: _longWord,
      error: 'Something went wrong while summarising: $_long',
      status: SavedStatus.failed,
    ),
    SavedItem(
      id: 's_minimal',
      created: now.subtract(const Duration(days: 400)),
      status: SavedStatus.done,
    ),
    SavedItem(
      id: 's_file',
      created: now.subtract(const Duration(days: 1)),
      platform: 'file',
      kind: 'document',
      files: [
        {'path': '/nonexistent/$_longWord.pdf', 'name': '$_longWord.pdf', 'kind': 'document'},
      ],
      imagePath: '/nonexistent/shot.png',
      title: 'Screenshot of $_long',
      status: SavedStatus.done,
      summary: _long,
    ),
  ];
  for (final i in items) {
    await s.saved.add(i);
  }

  for (final (id, title, msgs) in [
    ('c1', 'A chat about $_long', 2),
    ('c2', 'Short', 4),
    ('c3', _longWord, 2),
    ('c4', 'Plans', 2),
    ('c5', 'Recipes', 2),
  ]) {
    await s.conversations.save(
      Conversation(
        id: id,
        title: title,
        messages: [
          ChatMessage(id: '${id}u', isUser: true, text: '$_long $_unbroken'),
          ChatMessage(id: '${id}a', isUser: false, text: 'ok ' * msgs),
        ],
      ),
    );
  }

  final builtIn = s.skills.builtIns;
  await s.skills.saveRecipe(
    Recipe(
      id: 'r_long',
      name: 'A recipe with a very long name $_longWord',
      description: _long,
      steps: [
        RecipeStep(builtIn.first.id, const {}),
        RecipeStep(builtIn[1].id, {for (final p in builtIn[1].params) p.name: '{{prev.text}}'}),
        RecipeStep(builtIn[2].id, const {}),
      ],
    ),
  );
  await s.skills.saveRecipe(
    Recipe(id: 'r_short', name: 'x', description: '', steps: [RecipeStep(builtIn.first.id, const {})], input: 'audio'),
  );
  for (final j in [
    {
      'schema': CommunitySkill.schema,
      'id': 'long_community_skill',
      'name': 'A community skill with a very long name $_longWord',
      'description': _long,
      'author': 'someone with a very long name $_longWord',
      'version': '12.3.4-beta.999',
      'params': [
        {'name': 'a_parameter_with_a_long_name', 'type': 'string', 'description': _long},
        {'name': 'count', 'type': 'number', 'description': 'how many', 'required': false},
        {'name': 'flag', 'type': 'boolean', 'description': ''},
        {'name': 'items', 'type': 'list', 'description': _lorem},
        {'name': 'pic', 'type': 'image', 'description': _lorem},
      ],
      'examples': [_long, 'short example'],
      'prompt': {'system': 'x', 'user': '{{a_parameter_with_a_long_name}}'},
    },
    {
      'schema': CommunitySkill.schema,
      'id': 'tiny_one',
      'name': 'Tiny',
      'description': 'd',
      'prompt': {'user': 'x'},
    },
  ]) {
    await s.skills.install(CommunitySkill.parse(Map<String, dynamic>.from(j)));
  }
}

// ---------------------------------------------------------------------------
// Chat content
// ---------------------------------------------------------------------------

final _markdown =
    '# A heading that is quite long and should wrap onto a second line on narrow phones\n\n'
    '$_long\n\n'
    '## Sub heading $_longWord\n\n'
    '- bullet one with `inline code that is also rather long and unbreakable_$_longWord` inside\n'
    '- bullet two **bold text that is long** and *italic text that is long* and [a link]($_unbroken)\n'
    '  - nested bullet $_lorem\n'
    '1. numbered one $_lorem\n'
    '2. numbered two $_unbroken\n\n'
    '> a quote $_lorem\n\n'
    '```dart\nfinal aVeryLongLine = someFunction(argumentNumberOne, argumentNumberTwo, argumentNumberThree, four);\n```\n\n'
    '$_unbroken\n\n$_longWord';

List<ChatMessage> _longChat() => [
  ChatMessage(id: 'u1', isUser: true, text: _long),
  ChatMessage(id: 'a1', isUser: false, text: _markdown, modelId: 'gemma-4-e2b'),
  ChatMessage(id: 'u2', isUser: true, text: _unbroken),
  ChatMessage(id: 'u3', isUser: true, text: _longWord),
  ChatMessage(
    id: 'u4',
    isUser: true,
    text: 'with attachments',
    attachments: const [
      Attachment(id: 'a1', kind: 'image', path: '/nonexistent/a.jpg', name: 'a.jpg'),
      Attachment(id: 'a2', kind: 'audio', path: '/nonexistent/b.m4a', name: 'b_$_longWord.m4a'),
      Attachment(id: 'a3', kind: 'document', path: '/nonexistent/c.txt', name: 'c_$_longWord.txt'),
      Attachment(id: 'a4', kind: 'image', path: '/nonexistent/d.jpg', name: 'd.jpg'),
      Attachment(id: 'a5', kind: 'image', path: '/nonexistent/e.jpg', name: 'e.jpg'),
      Attachment(id: 'a6', kind: 'image', path: '/nonexistent/f.jpg', name: 'f.jpg'),
    ],
  ),
  ChatMessage(id: 'a2', isUser: false, text: 'short answer', thinking: _long),
  ChatMessage(id: 'a3', isUser: false, text: _long, thinking: '', stats: null),
];

List<ChatMessage> _stepsChat() => [
  ChatMessage(id: 'u1', isUser: true, text: 'do many things'),
  ChatMessage(
    id: 'a1',
    isUser: false,
    text: 'done',
    thinking: _lorem,
    steps: [
      AgentStep(skillId: 'x1', skillName: 'Transcribe audio $_longWord', args: const {'a': 1}, status: StepStatus.done, ms: 12345),
      AgentStep(skillId: 'x2', skillName: 'Read page', args: const {}, via: 'router', status: StepStatus.done, ms: 12),
      AgentStep(
        skillId: 'x3',
        skillName: 'Send email to somebody with a long name',
        args: const {},
        via: 'router',
        status: StepStatus.failed,
        result: {'error': _long},
      ),
      AgentStep(skillId: 'x4', skillName: 'Call', args: const {}, status: StepStatus.declined),
      AgentStep(skillId: 'x5', skillName: 'Working skill', args: const {}, progress: _long),
      AgentStep(
        skillId: 'x6',
        skillName: 'Long args',
        args: {'text': _long, 'url': _unbroken},
        status: StepStatus.done,
        result: {'text': _long, 'url': _unbroken},
      ),
    ],
  ),
  ChatMessage(
    id: 'a2',
    isUser: false,
    error: 'Models are missing. $_long',
  ),
  ChatMessage(id: 'a3', isUser: false, error: _unbroken),
  ChatMessage(id: 'u2', isUser: true, text: 'waiting'),
  ChatMessage(id: 'a4', isUser: false, streaming: true),
];

AgentStep _cardStep(UiCard c) =>
    AgentStep(skillId: 'k', skillName: c.type, args: const {}, status: StepStatus.done, cards: [c]);

List<ChatMessage> _cardsA() => [
  ChatMessage(id: 'u1', isUser: true, text: 'cards please'),
  ChatMessage(
    id: 'a1',
    isUser: false,
    text: 'here',
    steps: [
      _cardStep(
        UiCard(
          'kv',
          title: 'Key values $_longWord',
          data: {
            'demo': true,
            'short': 'x',
            'a_key_that_is_long_$_longWord': _long,
            'url': _unbroken,
            'word': _longWord,
          },
        ),
      ),
      _cardStep(
        UiCard(
          'table',
          title: 'A table',
          data: {
            'demo': true,
            'columns': ['Name', 'Amount', 'A column with a long heading $_longWord', 'Notes'],
            'rows': [
              ['rent', '1200', _lorem, _unbroken],
              ['food', '300', '', ''],
              ['a row with fewer cells'],
              for (var i = 0; i < 6; i++) ['row $i', '$i', 'x', 'y'],
            ],
          },
        ),
      ),
      _cardStep(
        UiCard(
          'checklist',
          title: 'Checklist',
          data: {
            'items': ['buy milk', _long, _unbroken, _longWord, for (var i = 0; i < 6; i++) 'item $i'],
          },
        ),
      ),
      _cardStep(
        UiCard(
          'checklist',
          title: 'Read-only list',
          data: {
            'readonly': true,
            'items': ['one', _lorem],
          },
        ),
      ),
      _cardStep(
        UiCard(
          'transcript',
          title: 'Transcript',
          data: {
            'segments': [
              {'speaker': 0, 'start': 0.0, 'text': _long},
              {'speaker': 1, 'start': 61.5, 'text': 'hi'},
              {'speaker': 2, 'start': 3725.0, 'text': _unbroken},
              {'speaker': 11, 'start': 9999.0, 'text': _longWord},
            ],
          },
        ),
      ),
    ],
  ),
];

List<ChatMessage> _cardsB() => [
  ChatMessage(id: 'u1', isUser: true, text: 'more cards'),
  ChatMessage(
    id: 'a1',
    isUser: false,
    text: 'here',
    steps: [
      _cardStep(
        UiCard(
          'tags',
          title: 'Tags',
          data: {
            'tags': [for (var i = 0; i < 25; i++) 'tag number $i', _longWord, _unbroken],
          },
        ),
      ),
      _cardStep(
        UiCard(
          'tags',
          title: 'Large tags',
          data: {
            'large': true,
            'tags': ['one', 'two words', _longWord, _lorem],
          },
        ),
      ),
      _cardStep(
        UiCard(
          'bars',
          title: 'Bars',
          data: {
            'labels': ['short', 'A label that is far too long to fit $_longWord', 'c', 'd'],
            'values': [10, 123456789.5, -3, 0],
          },
        ),
      ),
      _cardStep(
        UiCard(
          'timeline',
          title: 'Timeline',
          data: {
            'items': [
              {'time': '09:00', 'text': _long},
              {'time': 'A time label that is very long $_longWord', 'text': ''},
              {'time': '11:00', 'text': _unbroken},
            ],
          },
        ),
      ),
      _cardStep(UiCard('text', title: 'Text $_longWord', data: {'text': _markdown, 'copy': true, 'demo': true})),
      _cardStep(UiCard('text', title: '', data: {'text': _unbroken})),
      _cardStep(
        UiCard(
          'file',
          title: 'File',
          data: {
            'path': '/some/dir/$_longWord.txt',
            'kind': 'document',
            'preview': '$_long\n$_unbroken\n${List.filled(30, 'line').join('\n')}',
          },
        ),
      ),
      _cardStep(UiCard('file', title: 'No path', data: {'kind': 'audio'})),
      _cardStep(
        UiCard(
          'link',
          title: 'Link',
          data: {
            'rich': true,
            'platform': 'youtube',
            'kind': 'video',
            'author': 'An author with a long name $_longWord',
            'title': _long,
            'description': _long,
            'url': _unbroken,
          },
        ),
      ),
      _cardStep(
        UiCard(
          'link',
          title: 'Link without details',
          data: {'rich': false, 'platform': 'web', 'kind': 'link', 'title': _unbroken, 'url': _unbroken},
        ),
      ),
      _cardStep(const UiCard('image', title: 'Image', data: {'path': '/nonexistent/x.png'})),
    ],
  ),
];

// ---------------------------------------------------------------------------
// Screens
// ---------------------------------------------------------------------------

class Screen {
  Screen(this.name, this.home, {this.after, this.prep, this.bare = false, this.nav = false, this.onboarding = false, this.keyboard = 0});
  final double keyboard;
  final String name;
  final Widget Function() home;

  /// Runs after the first pump (open a sheet, push a route, tap a tab).
  final Future<void> Function(WidgetTester t, Env e)? after;
  final void Function(AppState s, Env e)? prep;

  /// Use services with no data at all.
  final bool bare;

  /// Wrap in a Scaffold with the HandNav bar, like the shell does.
  final bool nav;
  final bool onboarding;
}

BuildContext _ctx(WidgetTester t) => t.element(find.byType(Scaffold).first);

Future<void> _settle(WidgetTester t) async {
  await t.pump();
  await t.pump(const Duration(milliseconds: 600));
  await t.pump(const Duration(milliseconds: 600));
}

Future<void> _push(WidgetTester t, Widget w) async {
  Navigator.of(_ctx(t)).push(MaterialPageRoute<void>(builder: (_) => w));
  await _settle(t);
}

Future<void> _tap(WidgetTester t, Finder f, {bool optional = false}) async {
  if (f.evaluate().isEmpty) {
    if (optional) return;
    FlutterError.reportError(FlutterErrorDetails(exception: 'QA: finder $f matched nothing (test harness problem)'));
    return;
  }
  await t.tap(f.first, warnIfMissed: false);
  await _settle(t);
}

final _gatedModel = gemmaModels.firstWhere((m) => m.gated);

List<Screen> _screens() => [
  Screen('onboarding-welcome', () => const Shell(), onboarding: true),
  Screen(
    'onboarding-setup',
    () => const Shell(),
    onboarding: true,
    after: (t, e) => _tap(t, find.text("let's start")),
  ),
  Screen('shell-chat', () => const Shell()),
  Screen('shell-you', () => const Shell(), prep: (s, e) => s.tab = 4),
  Screen('chat-welcome-empty', () => const ChatScreen(), nav: true, bare: true),
  Screen('chat-welcome-recent', () => const ChatScreen(), nav: true),
  Screen('chat-long-messages', () => const ChatScreen(), nav: true, prep: (s, e) => s.chat.messages.addAll(_longChat())),
  Screen('chat-steps-errors', () => const ChatScreen(), nav: true, prep: (s, e) => s.chat.messages.addAll(_stepsChat())),
  Screen('chat-cards-a', () => const ChatScreen(), nav: true, prep: (s, e) => s.chat.messages.addAll(_cardsA())),
  Screen('chat-cards-b', () => const ChatScreen(), nav: true, prep: (s, e) => s.chat.messages.addAll(_cardsB())),
  Screen(
    'chat-pending-attachments',
    () => const ChatScreen(),
    nav: true,
    prep: (s, e) {
      e.services.intake.value = SharedIntake(
        text: _long,
        attachments: const [
          Attachment(id: 'a1', kind: 'image', path: '/nonexistent/a.jpg', name: 'a.jpg'),
          Attachment(id: 'a2', kind: 'audio', path: '/nonexistent/b.m4a', name: 'b_$_longWord.m4a'),
          Attachment(id: 'a3', kind: 'document', path: '/nonexistent/c.txt', name: 'c_$_longWord.txt'),
          Attachment(id: 'a4', kind: 'image', path: '/nonexistent/d.jpg', name: 'd.jpg'),
        ],
      );
    },
  ),
  Screen(
    'chat-keyboard-open-long-draft',
    () => const ChatScreen(),
    nav: true,
    keyboard: 280,
    prep: (s, e) => e.services.intake.value = SharedIntake(text: List.filled(6, 'line of a long draft message').join('\n')),
  ),
  Screen('chat-step-detail-sheet', () => const ChatScreen(), nav: true,
    prep: (s, e) => s.chat.messages.addAll(_stepsChat()),
    after: (t, e) => _tap(t, find.text('long args')),
  ),
  Screen('chat-model-picker-sheet', () => const ChatScreen(), nav: true, after: (t, e) => _tap(t, find.text('demo'))),
  Screen('chat-attach-sheet', () => const ChatScreen(), nav: true, after: (t, e) => _tap(t, find.byTooltip('Attach'))),
  Screen('past-chats-sheet', () => const ChatScreen(), nav: true, after: (t, e) async {
    showPastChats(_ctx(t));
    await _settle(t);
  }),
  Screen('past-chats-sheet-empty', () => const ChatScreen(), nav: true, bare: true, after: (t, e) async {
    showPastChats(_ctx(t));
    await _settle(t);
  }),
  Screen('voice', () => const ChatScreen(), nav: true, after: (t, e) => _push(t, const VoiceScreen())),
  Screen('saved-list', () => const SavedScreen(), nav: true),
  Screen('saved-empty', () => const SavedScreen(), nav: true, bare: true),
  Screen('saved-add-link-sheet', () => const SavedScreen(), nav: true, after: (t, e) => _tap(t, find.byTooltip('Save a link'))),
  for (final id in ['s_done_long', 's_done_short', 's_reading', 's_summarising', 's_needs_model', 's_failed', 's_minimal', 's_file'])
    Screen('saved-detail-$id', () => const SavedScreen(), nav: true, after: (t, e) => _push(t, SavedDetailScreen(id: id))),
  Screen('skills-list', () => const SkillsScreen(), nav: true),
  Screen('skills-recipes', () => const SkillsScreen(), nav: true, after: (t, e) => _tap(t, find.text('recipes'))),
  Screen('skills-community', () => const SkillsScreen(), nav: true, after: (t, e) => _tap(t, find.text('community'))),
  Screen('skill-sheet-most-params', () => const SkillsScreen(), nav: true, after: (t, e) async {
    final byParams = [...e.services.skills.builtIns]..sort((a, b) => b.params.length.compareTo(a.params.length));
    showSkillSheet(_ctx(t), byParams.first);
    await _settle(t);
  }),
  Screen('skill-sheet-longest-description', () => const SkillsScreen(), nav: true, after: (t, e) async {
    final byLen = [...e.services.skills.builtIns]..sort((a, b) => b.description.length.compareTo(a.description.length));
    showSkillSheet(_ctx(t), byLen.first);
    await _settle(t);
  }),
  Screen('skill-sheet-recipe', () => const SkillsScreen(), nav: true, after: (t, e) async {
    showSkillSheet(_ctx(t), RecipeSkill(e.services.skills.recipes.firstWhere((r) => r.id == 'r_long')));
    await _settle(t);
  }),
  Screen('skill-sheet-community', () => const SkillsScreen(), nav: true, after: (t, e) async {
    showSkillSheet(_ctx(t), e.services.skills.community.first);
    await _settle(t);
  }),
  Screen('recipe-editor-new', () => const SkillsScreen(), nav: true, after: (t, e) => _push(t, const RecipeEditor())),
  Screen('recipe-editor-edit', () => const SkillsScreen(), nav: true, after: (t, e) async {
    await _push(t, RecipeEditor(recipe: e.services.skills.recipes.firstWhere((r) => r.id == 'r_long')));
  }),
  Screen('models', () => const ModelsScreen(), nav: true),
  Screen('models-get-access-sheet', () => const ModelsScreen(), nav: true, after: (t, e) async {
    showGetAccess(_ctx(t), e.services, _gatedModel);
    await _settle(t);
  }),
  Screen('you', () => const YouScreen(), nav: true),
  Screen('you-empty', () => const YouScreen(), nav: true, bare: true),
  Screen('settings', () => const YouScreen(), nav: true, after: (t, e) => _push(t, const SettingsScreen())),
  Screen('about', () => const YouScreen(), nav: true, after: (t, e) => _push(t, const AboutScreen())),
  Screen('privacy', () => const YouScreen(), nav: true, after: (t, e) => _push(t, const PrivacyScreen())),
  Screen('privacy-empty', () => const YouScreen(), nav: true, bare: true, after: (t, e) => _push(t, const PrivacyScreen())),
  Screen('memory', () => const YouScreen(), nav: true, after: (t, e) => _push(t, const MemoryScreen())),
  Screen('memory-empty', () => const YouScreen(), nav: true, bare: true, after: (t, e) => _push(t, const MemoryScreen())),
  Screen('knowledge', () => const YouScreen(), nav: true, after: (t, e) => _push(t, const KnowledgeScreen())),
  Screen('knowledge-doc-sheet', () => const YouScreen(), nav: true, after: (t, e) async {
    await _push(t, const KnowledgeScreen());
    await _tap(t, find.byType(Door), optional: true);
  }),
  Screen('knowledge-empty', () => const YouScreen(), nav: true, bare: true, after: (t, e) => _push(t, const KnowledgeScreen())),
  Screen('lab', () => const YouScreen(), nav: true, after: (t, e) => _push(t, const LabScreen())),
];

// ---------------------------------------------------------------------------
// Configs
// ---------------------------------------------------------------------------

class Cfg {
  const Cfg(this.size, this.dark, this.scale, this.voice);
  final Size size;
  final bool dark;
  final double scale;
  final Voice voice;
  String get label =>
      '${size.width.toInt()}x${size.height.toInt()} ${dark ? 'dark' : 'light'} x$scale ${voice.name}';
}

const _sizes = [Size(320, 568), Size(360, 690), Size(412, 915), Size(800, 1280)];
const _scales = [1.0, 1.6];

List<Cfg> _configs() => [
  // Geometry: every size in light, at both scales.
  for (final s in _sizes)
    for (final k in _scales) Cfg(s, false, k, Voice.neat),
  // Dark: colours only, so two sizes are enough.
  const Cfg(Size(320, 568), true, 1.6, Voice.neat),
  const Cfg(Size(412, 915), true, 1.0, Voice.neat),
  // Every other body voice on the smallest and the largest screen.
  for (final v in Voice.values.where((v) => v != Voice.neat)) ...[
    Cfg(const Size(320, 568), false, 1.0, v),
    Cfg(const Size(320, 568), false, 1.6, v),
  ],
];

// ---------------------------------------------------------------------------
// Findings
// ---------------------------------------------------------------------------

class Finding {
  Finding(this.kind, this.location, this.detail);
  final String kind;
  final String location;
  final String detail;
  final Set<String> screens = {};
  final Set<String> configs = {};
  double maxPx = 0;
  String get key => '$kind @ $location';
  String get shortLocation => location.split(' < ').take(7).join(' < ');
}

final Map<String, Finding> _all = {};
const _trace = bool.fromEnvironment('QA_TRACE');

final _locRe = RegExp(r'((?:file://)?/[^\s:]*?/(?:lib|test)/[^\s:]+\.dart:\d+:\d+)');

String _shortLoc(String l) => l.replaceFirst('file://', '').replaceFirst('/home/user/PhoneDots/', '');

Finding _classify(FlutterErrorDetails d) {
  final text = d.exceptionAsString();
  final full = d.exception is FlutterError
      ? (d.exception as FlutterError).diagnostics.map((n) => n.toStringDeep()).join('\n')
      : text;
  final info = d.informationCollector?.call().map((n) => n.toStringDeep()).join('\n') ?? '';
  var kind = text.split('\n').first.replaceAll(RegExp(r'\d+(\.\d+)?'), '#');
  if (kind.length > 90) kind = kind.substring(0, 90);
  final marker = '$full\n$info'.indexOf('error-causing');
  final both = '$full\n$info';
  final m = _locRe.firstMatch(marker >= 0 ? both.substring(marker) : both) ?? _locRe.firstMatch(both);
  final stack = d.stack?.toString() ?? '';
  final sm = RegExp(r'package:phonedots/[^\s:)]+\.dart:\d+:\d+').firstMatch(stack);
  final cm = RegExp(r'creator: ([^\n]*)').firstMatch(both);
  final chain = cm?.group(1)?.split('←').map((e) => e.trim().replaceAll(RegExp(r'#[0-9a-f]{5}.*'), '')).where((e) => e != '⋯').take(12).join(' < ');
  final loc = m != null ? _shortLoc(m.group(1)!) : (chain ?? sm?.group(0) ?? 'unknown');
  final f = Finding(kind, loc, both);
  final px = RegExp(r'overflowed by ([\d.]+) pixels').firstMatch(text);
  if (px != null) f.maxPx = double.parse(px.group(1)!);
  return f;
}

// ---------------------------------------------------------------------------
// Harness
// ---------------------------------------------------------------------------

Future<void> _loadFonts() async {
  const files = {
    'Caveat': ['caveat_regular', 'caveat_semibold', 'caveat_bold'],
    'Inter': ['inter_regular', 'inter_medium', 'inter_semibold'],
    'Nunito': ['nunito_regular', 'nunito_semibold'],
    'ShantellSans': ['shantell_variable'],
    'PatrickHand': ['patrickhand_regular'],
  };
  for (final e in files.entries) {
    final loader = FontLoader(e.key);
    for (final f in e.value) {
      loader.addFont(rootBundle.load('assets/fonts/$f.ttf'));
    }
    await loader.load();
  }
}

Widget _app(AppState st, Screen sc, Cfg c, GlobalKey boundary) {
  Widget home = sc.home();
  if (sc.nav) {
    home = Scaffold(
      body: home,
      bottomNavigationBar: HandNav(index: 0, onTap: (_) {}, labels: const ['chat', 'saved', 'skills', 'models', 'you']),
    );
  }
  return RepaintBoundary(
    key: boundary,
    child: AppScope(
      state: st,
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light, voice: c.voice),
        darkTheme: buildTheme(Brightness.dark, voice: c.voice),
        themeMode: c.dark ? ThemeMode.dark : ThemeMode.light,
        home: home,
      ),
    ),
  );
}

/// Pumps [sc] under [c]; returns findings (also merged into [_all]).
Future<List<Finding>> _run(WidgetTester t, Screen sc, Cfg c,
    {String? png, bool scrollSweep = true, void Function(WidgetTester t)? probe}) async {
  final env = sc.bare ? await _bareEnv(t) : await _seededEnv(t);
  final settings = env.services.settings
    ..themeMode = c.dark ? ThemeMode.dark : ThemeMode.light
    ..voice = c.voice.name
    ..onboarded = !sc.onboarding;
  expect(settings.voice, c.voice.name);
  t.view.physicalSize = c.size;
  t.view.devicePixelRatio = 1.0;
  t.platformDispatcher.textScaleFactorTestValue = c.scale;
  if (sc.keyboard > 0) t.view.viewInsets = FakeViewPadding(bottom: sc.keyboard);

  final caught = <Finding>[];
  final old = FlutterError.onError;
  FlutterError.onError = (d) {
    // Plugins (record, tts) do not exist in the test VM: not an app bug.
    if (d.exception.toString().contains('MissingPluginException')) return;
    caught.add(_classify(d)); // describe now: the render tree is gone later
  };
  final st = AppState(env.services);
  final boundary = GlobalKey();
  try {
    sc.prep?.call(st, env);
    await t.pumpWidget(_app(st, sc, c, boundary));
    await _settle(t);
    if (sc.after != null) await sc.after!(t, env);
    if (_trace && sc.name == 'models') print('models ram=${env.services.models.device.totalRamMb} gb=${find.textContaining('GB memory').evaluate().length} ${c.label}');
    if (scrollSweep) await _scrollSweep(t);
    probe?.call(t);
    if (png != null) {
      final rb = t.renderObject<RenderRepaintBoundary>(find.byKey(boundary));
      await t.runAsync(() async {
        final img = await rb.toImage(pixelRatio: 2);
        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
        await Directory(_out).create(recursive: true);
        await File('$_out/$png.png').writeAsBytes(bytes!.buffer.asUint8List());
      });
    }
    await t.pumpWidget(const SizedBox());
    await t.pump(const Duration(milliseconds: 100));
  } finally {
    FlutterError.onError = old;
    st.chat.dispose();
    t.view.reset();
    t.platformDispatcher.clearTextScaleFactorTestValue();
    env.services.intake.value = null;
  }
  t.takeException();

  final out = <String, Finding>{};
  for (final f in caught) {
    final mine = out.putIfAbsent(f.key, () => f);
    mine.maxPx = mine.maxPx > f.maxPx ? mine.maxPx : f.maxPx;
  }
  for (final f in out.values) {
    final g = _all.putIfAbsent(f.key, () => f);
    g.screens.add(sc.name);
    g.configs.add(c.label);
    g.maxPx = g.maxPx > f.maxPx ? g.maxPx : f.maxPx;
  }
  return out.values.toList();
}

/// Scrolls every vertical scrollable to its end so lazily built rows get laid out.
Future<void> _scrollSweep(WidgetTester t) async {
  for (final e in find.byType(Scrollable).evaluate().toList()) {
    if (!e.mounted) continue;
    final st = (e as StatefulElement).state as ScrollableState;
    if (st.axisDirection != AxisDirection.down && st.axisDirection != AxisDirection.up) continue;
    final pos = st.position;
    if (!pos.hasContentDimensions || pos.maxScrollExtent <= 0) continue;
    var guard = 0;
    while (pos.pixels < pos.maxScrollExtent - 1 && guard++ < 40) {
      pos.jumpTo((pos.pixels + pos.viewportDimension * 0.7).clamp(0, pos.maxScrollExtent));
      await t.pump();
    }
    pos.jumpTo(0);
    await t.pump();
  }
}

String _describe(Finding f, Set<String> cfgs) {
  final px = f.maxPx > 0 ? ' (up to ${f.maxPx.toStringAsFixed(1)}px)' : '';
  return '  - ${f.kind}$px\n      at ${f.shortLocation}\n      e.g. ${cfgs.take(4).join(' | ')}${cfgs.length > 4 ? ' … (${cfgs.length} configs)' : ''}';
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(_loadFonts);

  tearDownAll(() async {
    final b = StringBuffer('QA UI sweep findings (${_all.length} distinct)\n\n');
    for (final f in _all.values) {
      b.writeln('${f.kind}${f.maxPx > 0 ? ' up to ${f.maxPx.toStringAsFixed(1)}px' : ''}');
      b.writeln('  at ${f.shortLocation}');
      b.writeln('  full chain: ${f.location}');
      b.writeln('  screens: ${f.screens.join(', ')}');
      b.writeln('  sizes: ${f.configs.map((c) => c.split(' ').first).toSet().join(', ')}; scales: ${f.configs.map((c) => c.split(' ')[2]).toSet().join(', ')}');
      b.writeln('  configs (${f.configs.length}): ${f.configs.join(' | ')}');
      b.writeln('  ${f.detail.split('\n').take(40).join('\n  ')}\n');
    }
    await Directory(_out).create(recursive: true);
    await File('$_out/findings.txt').writeAsString(b.toString());
    print(b);
  });

  testWidgets('sanity: real fonts are loaded (not Ahem)', (t) async {
    await t.pumpWidget(
      const Directionality(
        textDirection: TextDirection.ltr,
        child: Align(child: Text('iiiiiiiiii', style: TextStyle(fontFamily: 'Inter', fontSize: 20))),
      ),
    );
    // Ahem would be exactly 10 * 20 = 200 wide.
    expect(t.getSize(find.byType(Text)).width, lessThan(120));
  });

  // The whole matrix, one test per screen.
  for (final sc in _screens()) {
    testWidgets('layout sweep: ${sc.name}', timeout: const Timeout(Duration(minutes: 6)), (t) async {
      final perFinding = <String, (Finding, Set<String>)>{};
      for (final c in _configs()) {
        for (final f in await _run(t, sc, c)) {
          perFinding.putIfAbsent(f.key, () => (f, <String>{})).$2.add(c.label);
        }
      }
      if (perFinding.isNotEmpty) {
        fail(
          '${sc.name}: ${perFinding.length} distinct layout problem(s) over ${_configs().length} configs\n'
          '${perFinding.values.map((e) => _describe(e.$1, e.$2)).join('\n')}',
        );
      }
    });
  }

  // -------------------------------------------------------------------------
  // Accessibility
  // -------------------------------------------------------------------------

  final a11yScreens = [
    'chat-welcome-recent',
    'chat-long-messages',
    'chat-cards-a',
    'saved-list',
    'saved-detail-s_done_long',
    'skills-list',
    'models',
    'you',
    'settings',
    'onboarding-welcome',
  ];

  const a11yContrast = {'chat-welcome-recent', 'chat-cards-a', 'saved-list', 'saved-detail-s_done_long', 'models', 'settings'};

  for (final dark in [false, true]) {
    testWidgets('a11y: tap targets, labels and contrast (${dark ? 'dark' : 'light'})', timeout: const Timeout(Duration(minutes: 5)), (t) async {
      final problems = <String, Set<String>>{};
      final handle = t.ensureSemantics();
      try {
        for (final name in a11yScreens) {
          final sc = _screens().firstWhere((s) => s.name == name);
          for (final (size, scale) in const [(Size(412, 915), 1.0), (Size(360, 690), 1.6)]) {
            // Contrast analysis walks every pixel and is slow: a few screens, one size.
            final contrast = scale == 1.0 && a11yContrast.contains(name);
            final c = Cfg(size, dark, scale, Voice.neat);
            final env = sc.bare ? await _bareEnv(t) : await _seededEnv(t);
            env.services.settings
              ..themeMode = dark ? ThemeMode.dark : ThemeMode.light
              ..voice = c.voice.name
              ..onboarded = !sc.onboarding;
            t.view.physicalSize = size;
            t.view.devicePixelRatio = 1.0;
            t.platformDispatcher.textScaleFactorTestValue = scale;
            final st = AppState(env.services);
            final old = FlutterError.onError;
            FlutterError.onError = (_) {};
            try {
              sc.prep?.call(st, env);
              await t.pumpWidget(_app(st, sc, c, GlobalKey()));
              await _settle(t);
              if (sc.after != null) await sc.after!(t, env);
              final where = '$name ${c.label}';
              if (_trace) print('a11y $where');

              // DoodleButtons: labelled and big enough.
              for (final e in find.byType(DoodleButton).evaluate()) {
                final w = e.widget as DoodleButton;
                if (w.tooltip.trim().isEmpty) problems.putIfAbsent('DoodleButton without tooltip', () => {}).add(where);
                final box = e.renderObject! as RenderBox;
                if (box.size.width < 44 || box.size.height < 44) {
                  problems.putIfAbsent('DoodleButton smaller than 44dp (${w.tooltip}: ${box.size})', () => {}).add(where);
                }
              }
              // HandNav entries.
              if (sc.nav) {
                for (final l in ['chat', 'saved', 'skills', 'models', 'you']) {
                  final label = find.descendant(of: find.byType(HandNav), matching: find.text(l));
                  final p = find.ancestor(of: label, matching: find.byType(Pressable));
                  if (label.evaluate().isNotEmpty && p.evaluate().isNotEmpty) {
                    final s = t.getSize(p.first);
                    if (s.width < 44 || s.height < 44) problems.putIfAbsent('HandNav "$l" smaller than 44dp ($s)', () => {}).add(where);
                  }
                }
              }
              // Material guideline checks.
              for (final (gname, g) in <(String, AccessibilityGuideline)>[
                ('androidTapTargetGuideline (48dp)', androidTapTargetGuideline),
                ('iOSTapTargetGuideline (44pt)', iOSTapTargetGuideline),
                ('labeledTapTargetGuideline', labeledTapTargetGuideline),
                if (contrast) ('textContrastGuideline (AA)', textContrastGuideline),
              ]) {
                final sw = Stopwatch()..start();
                final r = await g.evaluate(t);
                if (_trace) print('   $gname ${sw.elapsedMilliseconds}ms');
                // Read-only selectable text (long-press to copy) is not a button; with a one-letter
                // fixture value it measures tiny. Every other failing node still counts.
                final onlySelectableText = (r.reason ?? '')
                    .split(RegExp(r'(?=SemanticsNode#)'))
                    .where((n) => n.contains('SemanticsNode#'))
                    .every((n) => n.contains('isReadOnly') && n.contains('isTextField'));
                if (!r.passed && !onlySelectableText) {
                  final reason = (r.reason ?? '')
                      .replaceAll(RegExp(r'SemanticsNode#\d+\(Rect\.fromLTRB\([^)]*\),?\s*'), 'node(')
                      .replaceAll(RegExp(r'See also:.*'), '')
                      .split('\n')
                      .where((l) => l.trim().isNotEmpty)
                      .take(3)
                      .join(' / ');
                  problems.putIfAbsent('$gname: $reason', () => {}).add(where);
                }
              }
            } finally {
              FlutterError.onError = old;
              st.chat.dispose();
              t.view.reset();
              t.platformDispatcher.clearTextScaleFactorTestValue();
              env.services.intake.value = null;
            }
            await t.pumpWidget(const SizedBox());
            t.takeException();
          }
        }
      } finally {
        if (_trace) print('a11y dispose');
        handle.dispose();
      }
      final msg = problems.entries
          .map((e) => '  - ${e.key}\n      on: ${e.value.take(5).join(' | ')}${e.value.length > 5 ? ' … (${e.value.length})' : ''}')
          .join('\n');
      Directory(_out).createSync(recursive: true);
      File('$_out/a11y_${dark ? 'dark' : 'light'}.txt').writeAsStringSync(msg);
      if (_trace) print('a11y done');
      if (problems.isNotEmpty) fail('accessibility problems (${dark ? 'dark' : 'light'}):\n$msg');
    });
  }

  // -------------------------------------------------------------------------
  // Alignment: every Column0 child should start at the page gutter.
  // Column0 centres its child, so anything narrower than the column (a short
  // headline, a pill, a Row of pills) floats in the middle instead of lining up
  // with the body copy.
  // -------------------------------------------------------------------------

  testWidgets('alignment: Column0 children start at the gutter', timeout: const Timeout(Duration(minutes: 3)), (t) async {
    final off = <String, Set<String>>{};
    for (final name in ['onboarding-welcome', 'onboarding-setup', 'chat-welcome-recent', 'saved-list', 'skills-list', 'models', 'you', 'settings', 'privacy']) {
      final sc = _screens().firstWhere((s) => s.name == name);
      for (final size in const [Size(360, 690), Size(412, 915)]) {
        await _run(t, sc, Cfg(size, false, 1.0, Voice.neat), scrollSweep: false, probe: (t) {
          final w = size.width;
          final expected = ((w - (maxColumn + gutter * 2)) / 2).clamp(0, w) + gutter;
          for (final e in find.byType(Column0).evaluate()) {
            final box = e.renderObject;
            if (box is! RenderBox || !box.attached) continue;
            // The child of Column0 sits inside Center > ConstrainedBox > Padding.
            RenderBox? inner;
            e.visitChildElements((c) => c.visitChildElements((c2) => c2.visitChildElements((c3) => c3.visitChildElements((c4) => inner = c4.renderObject as RenderBox?))));
            if (inner == null || !inner!.hasSize || inner!.size.width < 1) continue;
            final dx = inner!.localToGlobal(Offset.zero).dx;
            if ((dx - expected).abs() > 1.5 && dx > 0 && dx < w) {
              final label = (e.widget as Column0).child.runtimeType.toString();
              off.putIfAbsent('$label starts ${dx.toStringAsFixed(0)}dp from the edge, body text starts ${expected.toStringAsFixed(0)}dp (width ${inner!.size.width.toStringAsFixed(0)})', () => {}).add('$name ${size.width.toInt()}x${size.height.toInt()}');
            }
          }
        });
      }
    }
    final msg = off.entries.map((e) => '  - ${e.key}\n      on: ${e.value.take(6).join(' | ')}').join('\n');
    Directory(_out).createSync(recursive: true);
    File('$_out/alignment.txt').writeAsStringSync(msg);
    if (off.isNotEmpty) fail('Column0 children not aligned to the gutter:\n$msg');
  });

  // -------------------------------------------------------------------------
  // Screenshots for visual review (not assertions)
  // -------------------------------------------------------------------------

  testWidgets('render PNGs for review', timeout: const Timeout(Duration(minutes: 4)), (t) async {
    final shots = <(String, Cfg)>[
      for (final dark in [false, true])
        for (final n in [
          'onboarding-welcome',
          'onboarding-setup',
          'chat-welcome-recent',
          'chat-long-messages',
          'chat-cards-a',
          'chat-cards-b',
          'chat-steps-errors',
          'saved-list',
          'saved-detail-s_done_long',
          'skills-list',
          'models',
          'you',
          'settings',
          'past-chats-sheet',
        ])
          (n, Cfg(const Size(360, 690), dark, 1.0, Voice.neat)),
      ('chat-cards-a', const Cfg(Size(320, 568), false, 1.6, Voice.neat)),
      ('saved-list', const Cfg(Size(320, 568), false, 1.6, Voice.handwritten)),
      ('models', const Cfg(Size(320, 568), true, 1.6, Voice.loose)),
      ('chat-welcome-recent', const Cfg(Size(800, 1280), false, 1.0, Voice.formal)),
    ];
    for (final (name, c) in shots) {
      final sc = _screens().firstWhere((s) => s.name == name);
      await _run(t, sc, c, png: '${name}_${c.size.width.toInt()}x${c.size.height.toInt()}_${c.dark ? 'dark' : 'light'}_x${c.scale}_${c.voice.name}', scrollSweep: false);
    }
  });
}
