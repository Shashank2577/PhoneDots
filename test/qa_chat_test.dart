import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:phonedots/agent/agent.dart';
import 'package:phonedots/agent/conversation.dart';
import 'package:phonedots/agent/prompts.dart';
import 'package:phonedots/agent/tool_call_parser.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/app_state.dart';
import 'package:phonedots/core/runtime/engine_types.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/features/chat/cards.dart';
import 'package:phonedots/features/chat/chat_screen.dart';
import 'package:phonedots/features/chat/message_view.dart';
import 'package:phonedots/skills/skill.dart';
import 'package:phonedots/theme/theme.dart';
import 'package:phonedots/widgets/hand.dart';

Future<AppServices> _demo({MemoryJsonStore? store, http.Client? client}) =>
    AppServices.create(store: store ?? MemoryJsonStore(), platform: 'demo', linkClient: client);

bool _wellFormed(String s) {
  final u = s.codeUnits;
  for (var i = 0; i < u.length; i++) {
    final c = u[i];
    if (c >= 0xD800 && c <= 0xDBFF) {
      if (i + 1 >= u.length || u[i + 1] < 0xDC00 || u[i + 1] > 0xDFFF) {
        return false;
      }
      i++;
    } else if (c >= 0xDC00 && c <= 0xDFFF) {
      return false;
    }
  }
  return true;
}

Set<String> _tools = {'calculate', 'set_timer', 'get_datetime', 'call_number', 'open_app'};

/// A store whose conversation writes can be made to fail.
class _FlakyStore extends MemoryJsonStore {
  bool failConv = false;
  @override
  Future<void> write(String key, Object? value) {
    if (failConv && key.startsWith('conv/')) throw Exception('disk full');
    return super.write(key, value);
  }
}

FnSkill _custom(
  String id,
  Future<SkillResult> Function(Map<String, dynamic>) run, {
  ConfirmPolicy confirm = ConfirmPolicy.never,
}) => FnSkill(
  id: id,
  name: 'Custom $id',
  description: 'qa skill $id',
  kind: SkillKind.ui,
  category: SkillCategory.output,
  confirm: confirm,
  handler: (args, ctx) => run(args),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // flutter test renders every font as Ahem unless the bundled fonts are loaded, which makes
  // overflow checks meaningless. Load the app's real fonts so layout matches a phone.
  setUpAll(() async {
    const fonts = {
      'Caveat': ['caveat_regular', 'caveat_semibold', 'caveat_bold'],
      'Inter': ['inter_regular', 'inter_medium', 'inter_semibold'],
      'Nunito': ['nunito_regular', 'nunito_semibold'],
      'ShantellSans': ['shantell_variable'],
      'PatrickHand': ['patrickhand_regular'],
    };
    for (final e in fonts.entries) {
      final loader = FontLoader(e.key);
      for (final f in e.value) {
        loader.addFont(rootBundle.load('assets/fonts/$f.ttf'));
      }
      await loader.load();
    }
  });

  final clipboardWrites = <String>[];
  setUp(() {
    clipboardWrites.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          clipboardWrites.add((call.arguments as Map)['text'] as String);
        }
        if (call.method == 'Clipboard.getData') return {'text': ''};
        return null;
      },
    );
  });

  // ---------------------------------------------------------------------------
  group('tool call parser', () {
    test('fenced tool_call block, with surrounding prose removed', () {
      final r = ToolCallParser.parse(
        'Sure thing.\n```tool_call\n{"name": "calculate", "arguments": {"expression": "2+2"}}\n```\nDone',
        _tools,
      );
      expect(r.calls.single.name, 'calculate');
      expect(r.calls.single.arguments, {'expression': '2+2'});
      expect(r.text, contains('Sure thing.'));
      expect(r.text, isNot(contains('tool_call')));
    });

    test('fenced json block, "parameters" key, string-encoded arguments, OpenAI function wrapper', () {
      var r = ToolCallParser.parse('```json\n{"name":"set_timer","parameters":{"seconds":5}}\n```', _tools);
      expect(r.calls.single.arguments['seconds'], 5);
      r = ToolCallParser.parse('```json\n{"name":"set_timer","arguments":"{\\"seconds\\": 7}"}\n```', _tools);
      expect(r.calls.single.arguments['seconds'], 7);
      r = ToolCallParser.parse(
        '```tool_call\n{"type":"function","function":{"name":"set_timer","arguments":{"seconds":9}}}\n```',
        _tools,
      );
      expect(r.calls.single.arguments['seconds'], 9);
    });

    test('a JSON list of calls in one fence yields every call', () {
      final r = ToolCallParser.parse(
        '```json\n[{"name":"get_datetime"},{"name":"set_timer","arguments":{"seconds":1}}]\n```',
        _tools,
      );
      expect(r.calls.map((c) => c.name), ['get_datetime', 'set_timer']);
      expect(r.calls.map((c) => c.id).toSet(), hasLength(2), reason: 'call ids must be unique');
    });

    test('two separate fenced blocks yield two calls', () {
      final r = ToolCallParser.parse(
        '```tool_call\n{"name":"get_datetime"}\n```\nand\n```tool_call\n{"name":"calculate","arguments":{"expression":"1"}}\n```',
        _tools,
      );
      expect(r.calls.map((c) => c.name), ['get_datetime', 'calculate']);
    });

    test('bare JSON object is a call; bare JSON for an unknown tool is just text', () {
      expect(ToolCallParser.parse('{"name":"get_datetime"}', _tools).calls.single.name, 'get_datetime');
      final r = ToolCallParser.parse('{"name":"format_disk","arguments":{}}', _tools);
      expect(r.calls, isEmpty);
      expect(r.text, contains('format_disk'));
    });

    test('unknown tool names in a fence are ignored and the text is kept', () {
      final r = ToolCallParser.parse('```tool_call\n{"name":"rm_rf","arguments":{}}\n```', _tools);
      expect(r.calls, isEmpty);
      expect(r.text, contains('rm_rf'));
    });

    test('malformed model output never throws and produces no calls', () {
      final bad = [
        '',
        '   ',
        '```tool_call\n{"name": "calculate", "arguments": {"expression": ',
        '```tool_call\n{"name": "calculate"',
        '```tool_call\n{name: calculate}\n```',
        '```tool_call\n```',
        '{"name": "calculate", ',
        '{}',
        '[]',
        '[calculate(',
        '[calculate(expression="2+2"',
        '<start_function_call>call:calculate{expression:<escape>2+2<escape>}',
        'plain answer with { braces } and [brackets]',
        '```\nnot json\n```',
        '```json\n"just a string"\n```',
        '```json\n42\n```',
        '```json\nnull\n```',
      ];
      for (final t in bad) {
        late ({List<ToolCallRequest> calls, String text}) r;
        expect(() => r = ToolCallParser.parse(t, _tools), returnsNormally, reason: 'input: $t');
        expect(r.calls, isEmpty, reason: 'input: $t');
      }
    });

    test('partial fence keeps the visible text untouched', () {
      const t = 'Let me check.\n```tool_call\n{"name": "calc';
      final r = ToolCallParser.parse(t, _tools);
      expect(r.calls, isEmpty);
      expect(r.text, t);
    });

    // BUG: arguments that are not a JSON object ("arguments": [1,2], or a string
    // that decodes to a non-map) hit `args as Map` in _fromJson and throw a TypeError.
    // In ChatController.send that becomes a raw "type 'List<dynamic>' is not a subtype..." error shown to the user.
    test('arguments that are not an object do not throw', () {
      for (final t in [
        '```tool_call\n{"name":"calculate","arguments":[1,2]}\n```',
        '```tool_call\n{"name":"calculate","arguments":"2+2"}\n```',
        '```tool_call\n{"name":"calculate","arguments":5}\n```',
        '{"name":"calculate","arguments":[]}',
      ]) {
        expect(() => ToolCallParser.parse(t, _tools), returnsNormally, reason: t);
      }
    });

    test('python style: one call with mixed types', () {
      final r = ToolCallParser.parse('[set_timer(seconds=90, label="Tea, green", loud=true)]', _tools);
      expect(r.calls.single.name, 'set_timer');
      expect(r.calls.single.arguments, {'seconds': 90, 'label': 'Tea, green', 'loud': true});
      expect(r.text, '');
    });

    test('python style: no args, single quotes, escaped quotes, parentheses inside string', () {
      expect(ToolCallParser.parse('[get_datetime()]', _tools).calls.single.arguments, isEmpty);
      expect(ToolCallParser.parse("[calculate(expression='3*(4+1)')]", _tools).calls.single.arguments, {
        'expression': '3*(4+1)',
      });
      expect(ToolCallParser.parse(r'[calculate(expression="say \"hi\"")]', _tools).calls.single.arguments, {
        'expression': 'say "hi"',
      });
    });

    // BUG: the Gemma 3 format can list several calls: [a(x=1), b(y=2)]. The regex
    // `^\[\s*(\w+)\((.*)\)\s*\]$` is greedy and swallows both, producing ONE call to `a`
    // with garbled arguments and silently dropping `b`.
    test('python style: several calls in one list', () {
      final r = ToolCallParser.parse('[set_timer(seconds=5), get_datetime()]', _tools);
      expect(r.calls.map((c) => c.name), ['set_timer', 'get_datetime']);
      expect(r.calls.first.arguments, {'seconds': 5});
    });

    test('python style call for an unknown tool is plain text', () {
      final r = ToolCallParser.parse('[wipe_phone(now=true)]', _tools);
      expect(r.calls, isEmpty);
      expect(r.text, '[wipe_phone(now=true)]');
    });

    test('FunctionGemma format with escaped strings and scalars', () {
      final r = ToolCallParser.parse(
        'ok <start_function_call>call:set_timer{seconds:300,label:<escape>Eggs, soft<escape>,on:true}<end_function_call>',
        _tools,
      );
      expect(r.calls.single.name, 'set_timer');
      expect(r.calls.single.arguments, {'seconds': 300, 'label': 'Eggs, soft', 'on': true});
      expect(r.text, 'ok');
    });

    test('FunctionGemma call for unknown tool is ignored', () {
      final r = ToolCallParser.parse('<start_function_call>call:nope{a:1}<end_function_call>', _tools);
      expect(r.calls, isEmpty);
    });

    // Suspicious (low): _scalar uses num.tryParse, so an unquoted 0123456789 becomes the number
    // 123456789 (leading zero lost). Documented here as current behaviour, not asserted as a bug.
    test('unquoted digit strings are turned into numbers (documents leading-zero loss)', () {
      final r = ToolCallParser.parse('[call_number(number=0123456789)]', _tools);
      expect(r.calls.single.arguments['number'], isA<num>());
    });
  });

  // ---------------------------------------------------------------------------
  group('ConversationStore and Conversation', () {
    test('save ignores an empty conversation', () async {
      final store = MemoryJsonStore();
      final s = await _demo(store: store);
      await s.conversations.save(Conversation(id: 'x'));
      expect(s.conversations.summaries, isEmpty);
      expect(store.data.keys.where((k) => k.startsWith('conv/')), isEmpty);
    });

    test('summary: preview strips markdown, truncates, prefixes user, counts user turns', () async {
      final c = Conversation(id: 'c', title: 't');
      c.messages.addAll([
        ChatMessage(id: '1', isUser: true, text: 'hi'),
        ChatMessage(id: '2', isUser: false, text: '**Bold** `code` # head\n\nline  two'),
      ]);
      var sum = ConversationSummary.of(c);
      expect(sum.preview, 'Bold code head line two');
      expect(sum.count, 1);

      c.messages.add(ChatMessage(id: '3', isUser: true, text: 'q' * 200));
      sum = ConversationSummary.of(c);
      expect(sum.preview, startsWith('you: '));
      expect(sum.preview.length, 'you: '.length + 91);
      expect(sum.preview, endsWith('…'));
      expect(sum.count, 2);
    });

    test('summary falls back to the last non-empty message, or empty preview when nothing was said', () {
      final c = Conversation(id: 'c');
      c.messages.addAll([
        ChatMessage(id: '1', isUser: true, text: 'question'),
        ChatMessage(id: '2', isUser: false, text: '  '),
      ]);
      expect(ConversationSummary.of(c).preview, 'you: question');
      final d = Conversation(id: 'd')
        ..messages.addAll([ChatMessage(id: '1', isUser: true), ChatMessage(id: '2', isUser: false, streaming: true)]);
      expect(ConversationSummary.of(d).preview, '');
    });

    test('summaries are newest first and re-saving moves a chat to the top', () async {
      final s = await _demo();
      final a = ChatController(s);
      final b = ChatController(s);
      await a.send('first chat');
      await b.send('second chat');
      expect(s.conversations.summaries.map((x) => x.title), ['second chat', 'first chat']);
      await a.send('more in first');
      expect(s.conversations.summaries.map((x) => x.title), ['first chat', 'second chat']);
      expect(s.conversations.summaries, hasLength(2));
    });

    test('everything survives a restart: steps, cards, link context, thinking, stats', () async {
      final store = MemoryJsonStore();
      final s = await _demo(
        store: store,
        client: MockClient((r) async => http.Response(jsonEncode({'title': 'A video', 'author_name': 'Me'}), 200)),
      );
      await s.settings.update((x) => x.thinking = true);
      final chat = ChatController(s);
      await chat.send('what is https://youtu.be/dCS4er4Xcjo');
      await chat.send('Make me a checklist');
      final again = await _demo(store: store);
      final c = (await again.conversations.open(chat.conversation.id))!;
      expect(c.messages, hasLength(4));
      expect(c.messages[0].linkContext, contains('A video'));
      expect(c.messages[1].steps.first.cards.single.type, 'link');
      expect(c.messages[3].cards.single.type, 'checklist');
      expect(c.messages[3].thinking, isNotEmpty);
      expect(c.messages[3].stats, isNotNull);
      expect(c.messages[3].turns, isNotEmpty);
      expect(c.messages[3].modelId, 'gemma-4-e2b');
    });

    test('opening an unknown id returns null', () async {
      final s = await _demo();
      expect(await s.conversations.open('nope'), isNull);
    });

    // BUG (robustness): one malformed entry in the index makes ConversationStore.load throw,
    // which makes AppServices.create (and therefore app start-up) fail. A single corrupt chat
    // should be skipped, not brick the app.
    test('a corrupt entry in the chat index does not stop the app starting', () async {
      final store = MemoryJsonStore();
      await store.write('conversations', [
        {'id': 'ok', 'title': 'fine', 'updated': DateTime.now().toIso8601String()},
        {'id': 'bad', 'title': 'no date'},
      ]);
      final s = await AppServices.create(store: store, platform: 'demo');
      expect(s.conversations.summaries.map((x) => x.id), contains('ok'));
    });

    // BUG (robustness): opening a conversation whose JSON is incomplete throws from open(),
    // and AppState.open (the tap handler for every chat row) does not catch it.
    test('opening a corrupt conversation returns null instead of throwing', () async {
      final store = MemoryJsonStore();
      final s = await _demo(store: store);
      await store.write('conv/broken', {'id': 'broken', 'title': 'x'});
      expect(await s.conversations.open('broken'), isNull);
    });

    test('delete removes the chat from the list, the store and the persisted index', () async {
      final store = MemoryJsonStore();
      final s = await _demo(store: store);
      final a = ChatController(s);
      final b = ChatController(s);
      await a.send('keep me');
      await b.send('delete me');
      await s.conversations.delete(b.conversation.id);
      expect(s.conversations.summaries.map((x) => x.title), ['keep me']);
      expect(store.data.containsKey('conv/${b.conversation.id}'), isFalse);
      final again = await _demo(store: store);
      expect(again.conversations.summaries.map((x) => x.title), ['keep me']);
      expect(await again.conversations.open(b.conversation.id), isNull);
    });

    test('deleting an id that does not exist is harmless', () async {
      final s = await _demo();
      await s.conversations.delete('ghost');
      expect(s.conversations.summaries, isEmpty);
    });

    test('deleteAll clears every record and the index, also after restart', () async {
      final store = MemoryJsonStore();
      final s = await _demo(store: store);
      for (final t in ['one', 'two', 'three']) {
        await ChatController(s).send(t);
      }
      expect(s.conversations.summaries, hasLength(3));
      await s.conversations.deleteAll();
      expect(s.conversations.summaries, isEmpty);
      expect(store.data.keys.where((k) => k.startsWith('conv/')), isEmpty);
      expect((await _demo(store: store)).conversations.summaries, isEmpty);
      await s.conversations.deleteAll(); // idempotent
    });

    test('deleting the chat that is open: the controller still works and re-saves it', () async {
      final s = await _demo();
      final chat = ChatController(s);
      await chat.send('hello');
      await s.conversations.delete(chat.conversation.id);
      expect(s.conversations.summaries, isEmpty);
      expect(chat.messages, hasLength(2), reason: 'open controller keeps its messages');
      await chat.send('still here?');
      expect(chat.messages, hasLength(4));
      // Documents current behaviour: the deleted chat silently comes back on the next message.
      expect(s.conversations.summaries, hasLength(1));
    });

    test('a failing disk write sets saveError and does not break the chat; the next good save clears it', () async {
      final store = _FlakyStore();
      final s = await _demo(store: store);
      final chat = ChatController(s);
      store.failConv = true;
      await chat.send('hello');
      expect(chat.messages.last.error, isNull);
      expect(s.conversations.saveError, contains('could not be saved'));
      expect(s.conversations.summaries, isEmpty);
      store.failConv = false;
      await chat.send('again');
      expect(s.conversations.saveError, isNull);
      expect(s.conversations.summaries, hasLength(1));
    });

    // BUG: ConversationStore.saveError is documented as "shown in the chat so a failure is never
    // silent" but nothing outside conversation.dart reads it (grep -rn saveError lib), so a full disk
    // loses chats without any visible warning.
    test('save failures are surfaced in the UI (saveError is read by some widget)', () async {
      final src = await _readLib();
      final users = src.entries.where(
        (e) => !e.key.endsWith('agent/conversation.dart') && e.value.contains('saveError'),
      );
      expect(users, isNotEmpty);
    });

    group('transcript', () {
      test('starts with title, labels speakers, includes attachments, skips empty messages', () {
        final c = Conversation(id: 'c', title: 'Trip notes')
          ..messages.addAll([
            ChatMessage(
              id: '1',
              isUser: true,
              text: '  Describe these  ',
              attachments: const [
                Attachment(id: 'a1', kind: 'image', path: '/p/a.png', name: 'a.png'),
                Attachment(id: 'a2', kind: 'audio', path: '/p/b.m4a', name: 'b.m4a'),
              ],
            ),
            ChatMessage(id: '2', isUser: false, text: 'A beach.\n\n- sand\n- sea'),
            ChatMessage(
              id: '3',
              isUser: true,
              attachments: const [Attachment(id: 'a3', kind: 'document', path: '/d', name: 'n.txt')],
            ),
            ChatMessage(id: '4', isUser: false, text: '   '),
            ChatMessage(id: '5', isUser: false),
          ]);
        final t = ConversationStore.transcript(c);
        expect(t, startsWith('Trip notes\n\n'));
        expect(t, contains('You: [image: a.png] [audio: b.m4a]\nDescribe these'));
        expect(t, contains('PhoneDots: A beach.\n\n- sand\n- sea'));
        expect(t, contains('You: [document: n.txt]'));
        expect(RegExp('PhoneDots:').allMatches(t), hasLength(1));
        expect(t, isNot(endsWith('\n')));
      });

      test('empty conversation is just the title; huge chats do not blow up', () {
        expect(ConversationStore.transcript(Conversation(id: 'c', title: 'T')), 'T');
        final big = Conversation(id: 'b', title: 'Big');
        for (var i = 0; i < 2000; i++) {
          big.messages.add(ChatMessage(id: '$i', isUser: i.isEven, text: 'm$i ' * 50));
        }
        final t = ConversationStore.transcript(big);
        expect(t, contains('m1999'));
      });
    });
  });

  // ---------------------------------------------------------------------------
  group('ChatController: send', () {
    test('empty and whitespace-only messages are ignored', () async {
      final s = await _demo();
      final chat = ChatController(s);
      for (final t in ['', ' ', '\n\t  \n']) {
        await chat.send(t);
      }
      expect(chat.messages, isEmpty);
      expect(chat.busy, isFalse);
      expect(s.conversations.summaries, isEmpty);
      expect(chat.conversation.title, 'New chat');
    });

    test('user text is trimmed; title is the first message', () async {
      final s = await _demo();
      final chat = ChatController(s);
      await chat.send('   hello there \n');
      expect(chat.messages.first.text, 'hello there');
      expect(chat.conversation.title, 'hello there');
      await chat.send('second');
      expect(chat.conversation.title, 'hello there', reason: 'title is set once');
    });

    test('long titles are cut at 48 characters with an ellipsis', () async {
      final s = await _demo();
      final chat = ChatController(s);
      await chat.send('w' * 100);
      expect(chat.conversation.title, '${'w' * 48}…');
      final exactly = ChatController(s);
      await exactly.send('x' * 48);
      expect(exactly.conversation.title, 'x' * 48);
    });

    // BUG: title (and the 90-char preview) are cut with String.substring, which can split a
    // surrogate pair (emoji) and leave a lone surrogate. Flutter's Text throws/renders garbage for
    // ill-formed UTF-16 in the chat rows.
    test('title and preview are cut on a character boundary (emoji)', () async {
      final s = await _demo();
      final chat = ChatController(s);
      await chat.send('${'a' * 47}😀 and more words after it');
      expect(
        _wellFormed(chat.conversation.title),
        isTrue,
        reason: 'title: ${chat.conversation.title.codeUnits.reversed.take(3)}',
      );
      final c = Conversation(id: 'p')
        ..messages.add(ChatMessage(id: '1', isUser: true, text: '${'b' * 84}😀 tail tail tail'));
      expect(_wellFormed(ConversationSummary.of(c).preview), isTrue);
    });

    test('a very long message is kept whole, saved, and answered', () async {
      final s = await _demo();
      final chat = ChatController(s);
      final long = List.generate(5000, (i) => 'word$i').join(' ');
      await chat.send(long);
      expect(chat.messages.first.text, long);
      expect(chat.messages.last.error, isNull);
      expect(chat.messages.last.text, isNotEmpty);
      final back = (await s.conversations.open(chat.conversation.id))!;
      expect(back.messages.first.text, long);
      expect(s.conversations.summaries.single.preview.length, lessThan(100));
    });

    test('multi-line, unicode and RTL text survive a round trip', () async {
      final s = await _demo();
      final chat = ChatController(s);
      const t = 'שלום\nこんにちは 👩‍👩‍👧‍👦\n"quotes" \\ back\\slash <b>tags</b>';
      await chat.send(t);
      final back = (await s.conversations.open(chat.conversation.id))!;
      expect(back.messages.first.text, t);
    });

    test('attachment with no text: sent, titled by file name, "See attachment." in history', () async {
      final s = await _demo();
      final chat = ChatController(s);
      await chat.send(
        '   ',
        attachments: const [Attachment(id: 'a1', kind: 'document', path: '/nope/notes.txt', name: 'notes.txt')],
      );
      expect(chat.messages, hasLength(2));
      expect(chat.messages.first.text, '');
      expect(chat.conversation.title, 'notes.txt');
      expect(chat.messages.last.error, isNull);
      expect(ConversationStore.transcript(chat.conversation), contains('You: [document: notes.txt]'));
      expect(s.conversations.summaries.single.preview, isNot(contains('null')));
    });

    test('attachment ids stay unique across turns', () async {
      final s = await _demo();
      final chat = ChatController(s);
      expect(chat.nextAttachmentId(0), 'a1');
      expect(chat.nextAttachmentId(2), 'a3');
      await chat.send(
        'look',
        attachments: const [Attachment(id: 'a1', kind: 'image', path: '/x.png', name: 'x.png')],
      );
      expect(chat.nextAttachmentId(0), 'a2');
      expect(chat.allAttachments.map((a) => a.id), ['a1']);
    });

    test('audio attachment that does not exist on disk fails gracefully, never throws', () async {
      final s = await _demo();
      final chat = ChatController(s);
      await chat.send(
        'Make minutes from this meeting',
        attachments: const [Attachment(id: 'a1', kind: 'audio', path: '/does/not/exist.wav', name: 'exist.wav')],
      );
      expect(chat.busy, isFalse);
      final reply = chat.messages.last;
      expect(reply.streaming, isFalse);
      expect(reply.steps.single.skillId, 'meeting_minutes');
    });

    test('busy re-entry: a second send while one is running is dropped', () async {
      final s = await _demo();
      final chat = ChatController(s);
      final first = chat.send('Tell me a story');
      expect(chat.busy, isTrue);
      await chat.send('this should be ignored');
      await chat.retry(); // also ignored while busy
      await chat.runSkill(s.skills.byId('get_datetime')!, {}); // also ignored
      await first;
      expect(chat.messages, hasLength(2));
      expect(chat.messages.first.text, 'Tell me a story');
      expect(chat.busy, isFalse);
    });

    test('streaming flag is cleared and listeners are notified', () async {
      final s = await _demo();
      final chat = ChatController(s);
      var n = 0;
      chat.addListener(() => n++);
      final f = chat.send('hello');
      expect(chat.messages.last.streaming, isTrue);
      await f;
      expect(chat.messages.last.streaming, isFalse);
      expect(n, greaterThan(3));
    });

    test('thinking text is captured when the setting is on', () async {
      final s = await _demo();
      await s.settings.update((x) => x.thinking = true);
      final chat = ChatController(s);
      await chat.send('hello');
      expect(chat.messages.last.thinking, isNotEmpty);
    });

    test('tool loop: model call, tool result and final text are all recorded for replay', () async {
      final s = await _demo();
      final chat = ChatController(s);
      await chat.send('What is 18% of 2450?');
      final turns = chat.messages.last.turns;
      expect(turns.map((t) => t.role), [TurnRole.model, TurnRole.tool, TurnRole.model]);
      expect(turns[0].toolCalls.single.name, 'calculate');
      expect(turns[1].toolResponses.single.response['result'], '441');
      // A follow-up replays them in history and still works.
      await chat.send('and what is 5% of 100?');
      expect(chat.messages.last.steps.single.result['result'], '5');
    });

    test('maxSteps = 0 never offers tools, so the reply is plain text', () async {
      final s = await _demo();
      await s.settings.update((x) => x.maxSteps = 0);
      final chat = ChatController(s);
      await chat.send('What is 18% of 2450?');
      expect(chat.messages.last.steps, isEmpty);
      expect(chat.messages.last.text, isNotEmpty);
    });

    test('a skill that throws is reported on the step, and the chat carries on', () async {
      final s = await _demo();
      s.skills.builtIns.add(_custom('qa_boom', (_) async => throw StateError('kaboom')));
      final chat = ChatController(s);
      await chat.runSkill(s.skills.byId('qa_boom')!, {});
      final reply = chat.messages.last;
      expect(reply.steps.single.status, StepStatus.failed);
      expect(reply.steps.single.result['error'], contains('kaboom'));
      expect(reply.error, contains('kaboom'));
      expect(chat.busy, isFalse);
    });

    test('a skill returning an error result marks the step failed', () async {
      final s = await _demo();
      s.skills.builtIns.add(_custom('qa_err', (_) async => SkillResult.error('nope')));
      final chat = ChatController(s);
      await chat.runSkill(s.skills.byId('qa_err')!, {});
      expect(chat.messages.last.steps.single.status, StepStatus.failed);
      expect(chat.messages.last.error, 'nope');
    });

    test('disabled skill cannot be run', () async {
      final s = await _demo();
      final k = s.skills.byId('calculate')!;
      await s.skills.setEnabled(k, false);
      final chat = ChatController(s);
      await chat.runSkill(k, {'expression': '1+1'});
      expect(chat.messages.last.steps.single.status, StepStatus.failed);
      expect(chat.messages.last.steps.single.result['error'], contains('Unknown or disabled'));
      // and through the planner the demo model cannot even see it
      await chat.send('What is 18% of 2450?');
      expect(chat.messages.last.steps, isEmpty);
    });

    test('huge tool results are trimmed before going back to the model, but the step keeps them', () async {
      final s = await _demo();
      s.skills.builtIns.add(
        _custom('qa_big', (_) async => SkillResult({'blob': 'z' * 10000, 'rows': List.generate(100, (i) => i)})),
      );
      final chat = ChatController(s);
      await chat.runSkill(s.skills.byId('qa_big')!, {});
      final reply = chat.messages.last;
      final sent = reply.turns[1].toolResponses.single.response;
      expect((sent['blob'] as String).length, 3001);
      expect((sent['rows'] as List).length, 31);
      expect((reply.steps.single.result['blob'] as String).length, 10000);
    });

    test('runSkill: label becomes user text and title, plain skills say Done.', () async {
      final s = await _demo();
      s.skills.builtIns.add(_custom('qa_plain', (_) async => const SkillResult({'ok': true})));
      final chat = ChatController(s);
      await chat.runSkill(s.skills.byId('qa_plain')!, {}, label: 'Try the thing');
      expect(chat.messages.first.text, 'Try the thing');
      expect(chat.conversation.title, 'Try the thing');
      expect(chat.messages.last.text, 'Done.');
      expect(chat.messages.last.steps.single.via, 'direct');
      expect(s.conversations.summaries.single.title, 'Try the thing');
    });

    test('runSkill keeps the existing title when the chat already has one', () async {
      final s = await _demo();
      final chat = ChatController(s);
      await chat.send('hello');
      await chat.runSkill(s.skills.byId('get_datetime')!, {});
      expect(chat.conversation.title, 'hello');
      expect(chat.messages, hasLength(4));
    });
  });

  // ---------------------------------------------------------------------------
  group('ChatController: links', () {
    MockClient web({List<String>? log, int status = 200}) => MockClient((r) async {
      log?.add(r.url.toString());
      return http.Response(jsonEncode({'title': 'T ${r.url.host}', 'author_name': 'Au'}), status);
    });

    test('more than three links: only three are read', () async {
      final log = <String>[];
      final s = await _demo(client: web(log: log));
      final chat = ChatController(s);
      await chat.send(
        'compare https://youtu.be/aaaaaaaaaaa https://youtu.be/bbbbbbbbbbb https://youtu.be/ccccccccccc '
        'https://youtu.be/ddddddddddd https://youtu.be/eeeeeeeeeee',
      );
      final reads = chat.messages.last.steps.where((x) => x.skillId == 'read_link');
      expect(reads, hasLength(3));
      expect(chat.messages.first.linkContext, isNot(contains('ddddddddddd')));
      expect(chat.busy, isFalse);
    });

    test('each distinct link is read once, in order, with the question kept', () async {
      final s = await _demo(
        client: MockClient((r) async => http.Response(jsonEncode({'full_name': r.url.path, 'description': 'd'}), 200)),
      );
      final chat = ChatController(s);
      await chat.send('look at github.com/o/a and https://github.com/o/b, then github.com/o/a');
      final reads = chat.messages.last.steps.where((x) => x.skillId == 'read_link').toList();
      expect(reads, hasLength(2));
      expect(chat.messages.first.text, startsWith('look at'));
      expect(chat.messages.first.linkContext, contains('github.com/o/a'));
      expect(
        chat.messages.first.linkContext.indexOf('/o/a'),
        lessThan(chat.messages.first.linkContext.indexOf('/o/b')),
      );
    });

    test('trailing punctuation and brackets are not part of the link', () async {
      final log = <String>[];
      final s = await _demo(client: web(log: log));
      final chat = ChatController(s);
      await chat.send('see (https://youtu.be/dCS4er4Xcjo).');
      expect(chat.messages.last.steps.first.args['url'], isNot(contains(')')));
      expect(chat.messages.last.steps.first.args['url'], isNot(endsWith('.')));
    });

    test('a link that errors (HTTP 500 / network exception) does not break the turn', () async {
      for (final client in [web(status: 500), MockClient((_) async => throw const SocketLikeException())]) {
        final s = await _demo(client: client);
        final chat = ChatController(s);
        await chat.send('what is https://example.com/post/1');
        expect(chat.busy, isFalse);
        expect(chat.messages.last.error, isNull);
        expect(chat.messages.last.text, isNotEmpty);
        expect(chat.messages.first.linkContext, contains('example.com'));
      }
    });

    test('a link in a message is sent to the planner, never the router, and is listed on the reply', () async {
      final s = await _demo(client: web());
      final chat = ChatController(s);
      await chat.send('set a timer for 5 minutes https://youtu.be/dCS4er4Xcjo');
      expect(chat.messages.last.steps.map((x) => x.via).toSet(), isNot(contains('router')));
      expect(chat.messages.last.steps.first.via, 'auto');
    });

    test('link context survives retry (read again) without duplicating steps', () async {
      final s = await _demo(client: web());
      final chat = ChatController(s);
      await chat.send('https://youtu.be/dCS4er4Xcjo');
      await chat.retry();
      expect(chat.messages, hasLength(2));
      expect(chat.messages.last.steps.where((x) => x.skillId == 'read_link'), hasLength(1));
    });
  });

  // ---------------------------------------------------------------------------
  group('ChatController: retry and stop', () {
    test('retry replaces the last reply, keeps the user message, resends same text', () async {
      final s = await _demo();
      final chat = ChatController(s);
      await chat.send('What is 18% of 2450?');
      final oldReplyId = chat.messages.last.id;
      await chat.retry();
      expect(chat.messages, hasLength(2));
      expect(chat.messages.first.text, 'What is 18% of 2450?');
      expect(chat.messages.last.id, isNot(oldReplyId));
      expect(chat.messages.last.steps.single.result['result'], '441');
      expect(s.conversations.summaries.single.count, 1);
    });

    test('retry keeps attachments', () async {
      final s = await _demo();
      final chat = ChatController(s);
      const a = Attachment(id: 'a1', kind: 'image', path: '/x.png', name: 'x.png');
      await chat.send('What is in this photo?', attachments: const [a]);
      await chat.retry();
      expect(chat.messages.first.attachments.single.name, 'x.png');
    });

    test('retry on an empty chat or with a single message does nothing', () async {
      final s = await _demo();
      final chat = ChatController(s);
      await chat.retry();
      expect(chat.messages, isEmpty);
      chat.messages.add(ChatMessage(id: 'u', isUser: true, text: 'lonely'));
      await chat.retry();
      expect(chat.messages, hasLength(1));
    });

    test('retry when the last two messages are not user+assistant leaves them alone', () async {
      final s = await _demo();
      final chat = ChatController(s);
      chat.messages.addAll([
        ChatMessage(id: '1', isUser: false, text: 'a'),
        ChatMessage(id: '2', isUser: false, text: 'b'),
      ]);
      await chat.retry();
      expect(chat.messages.map((m) => m.id), ['1', '2']);
    });

    test('retry after a failed step re-runs it and can succeed', () async {
      var calls = 0;
      final s = await _demo();
      s.skills.builtIns.add(
        _custom(
          'set_timer_flaky',
          (_) async => ++calls == 1 ? SkillResult.error('first try fails') : const SkillResult({'summary': 'worked'}),
        ),
      );
      final chat = ChatController(s);
      await chat.runSkill(s.skills.byId('set_timer_flaky')!, {}, label: 'flaky');
      expect(chat.messages.last.error, isNotNull);
      // retry resends as chat text, so the demo planner answers; the failed reply is gone either way
      await chat.retry();
      expect(chat.messages, hasLength(2));
      expect(chat.messages.last.error, isNull);
    });

    test('stop mid-generation keeps the partial text, clears busy, saves, and the chat stays usable', () async {
      final s = await _demo();
      final full = ChatController(s);
      await full.send('Tell me a story');
      final fullLength = full.messages.last.text.length;

      final chat = ChatController(s);
      final f = chat.send('Tell me a story');
      await Future<void>.delayed(const Duration(milliseconds: 120));
      expect(chat.busy, isTrue);
      await chat.stop();
      await f;
      expect(chat.busy, isFalse);
      expect(chat.messages.last.streaming, isFalse);
      expect(chat.messages.last.text.length, lessThan(fullLength));
      expect(chat.messages.last.text, isNotEmpty);
      expect(chat.messages.last.error, isNull);

      final saved = (await s.conversations.open(chat.conversation.id))!;
      expect(saved.messages.last.text, chat.messages.last.text);

      await chat.send('hello again');
      expect(chat.messages, hasLength(4));
      expect(chat.messages.last.text.length, greaterThan(20), reason: 'stop flag must not leak into the next turn');
    });

    test('stop before the first token leaves an empty, non-streaming reply that can be retried', () async {
      final s = await _demo();
      final chat = ChatController(s);
      final f = chat.send('Tell me a story');
      await chat.stop();
      await f;
      expect(chat.busy, isFalse);
      expect(chat.messages.last.streaming, isFalse);
      await chat.retry();
      expect(chat.messages, hasLength(2));
      expect(chat.messages.last.text, isNotEmpty);
    });

    test('stop while idle is harmless and does not swallow the next message', () async {
      final s = await _demo();
      final chat = ChatController(s);
      await chat.stop();
      await chat.send('What is 18% of 2450?');
      expect(chat.messages.last.steps.single.status, StepStatus.done);
      expect(chat.messages.last.text, contains('441'));
    });

    test('stop during the tool-call round does not run the tool', () async {
      final s = await _demo();
      final chat = ChatController(s);
      final f = chat.send('What is 18% of 2450?');
      await Future<void>.delayed(const Duration(milliseconds: 60));
      await chat.stop();
      await f;
      expect(chat.messages.last.steps, isEmpty, reason: 'demo tool call arrives after the stop');
      expect(chat.busy, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  group('ChatController: permission gates', () {
    test('no confirm handler means actions are declined (safe default)', () async {
      final s = await _demo();
      final chat = ChatController(s);
      await chat.runSkill(s.skills.byId('call_number')!, {'number': '123'});
      expect(chat.messages.last.steps.single.status, StepStatus.declined);
    });

    test('declined: error shown, skill not executed, tool turns still recorded', () async {
      final s = await _demo();
      var ran = false;
      s.skills.builtIns.add(
        _custom('qa_gate', (_) async {
          ran = true;
          return const SkillResult({'ok': 1});
        }, confirm: ConfirmPolicy.always),
      );
      final chat = ChatController(s)..onConfirm = (_, _) async => false;
      await chat.runSkill(s.skills.byId('qa_gate')!, {});
      expect(ran, isFalse);
      final reply = chat.messages.last;
      expect(reply.steps.single.status, StepStatus.declined);
      expect(reply.error, contains('declined'));
      expect(reply.text, '');
    });

    test('always policy asks every time; accepted runs the skill', () async {
      final s = await _demo();
      var asked = 0;
      final chat = ChatController(s)
        ..onConfirm = (k, a) async {
          asked++;
          expect(k.id, 'call_number');
          expect(a['number'], '555');
          return true;
        };
      final k = s.skills.byId('call_number')!;
      await chat.runSkill(k, {'number': '555'});
      await chat.runSkill(k, {'number': '555'});
      expect(asked, 2);
      expect(chat.messages.last.steps.single.status, StepStatus.done);
    });

    test('first-time policy: declining is not remembered; accepting is, even after restart', () async {
      final store = MemoryJsonStore();
      var s = await _demo(store: store);
      var asked = 0;
      var answer = false;
      ChatController make() => ChatController(s)
        ..onConfirm = (_, _) async {
          asked++;
          return answer;
        };
      var k = s.skills.byId('read_clipboard')!;
      await make().runSkill(k, {});
      await make().runSkill(k, {});
      expect(asked, 2, reason: 'no remembering after a no');
      expect(s.settings.grantedSkills, isNot(contains('read_clipboard')));
      answer = true;
      await make().runSkill(k, {});
      await make().runSkill(k, {});
      expect(asked, 3);
      expect(s.settings.grantedSkills, contains('read_clipboard'));

      s = await _demo(store: store);
      k = s.skills.byId('read_clipboard')!;
      final chat = make();
      await chat.runSkill(k, {});
      expect(asked, 3, reason: 'grant survives restart');
      expect(chat.messages.last.steps.single.status, StepStatus.done);
    });

    test('a confirm handler that throws fails the step instead of crashing the chat', () async {
      final s = await _demo();
      final chat = ChatController(s)..onConfirm = (_, _) async => throw StateError('dialog gone');
      await chat.runSkill(s.skills.byId('call_number')!, {'number': '1'});
      expect(chat.messages.last.steps.single.status, StepStatus.failed);
      expect(chat.busy, isFalse);
    });

    test('a slow confirm dialog keeps the chat busy; answering releases it', () async {
      final s = await _demo();
      final gate = Completer<bool>();
      final chat = ChatController(s)..onConfirm = (_, _) => gate.future;
      final f = chat.runSkill(s.skills.byId('call_number')!, {'number': '1'});
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(chat.busy, isTrue);
      await chat.send('ignored while waiting');
      expect(chat.messages, hasLength(2));
      gate.complete(true);
      await f;
      expect(chat.busy, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  group('resume after restart', () {
    test('continue an old chat in a new process; list and ordering stay right', () async {
      final store = MemoryJsonStore();
      final s1 = await _demo(store: store);
      final a = ChatController(s1);
      await a.send('What is 2+2?');
      await ChatController(s1).send('other chat');

      final s2 = await _demo(store: store);
      expect(s2.conversations.summaries.map((x) => x.title), ['other chat', 'What is 2+2?']);
      final c = (await s2.conversations.open(a.conversation.id))!;
      final resumed = ChatController(s2, conversation: c);
      await resumed.send('And 3+3?');
      expect(resumed.messages, hasLength(4));
      expect(s2.conversations.summaries.first.id, c.id);
      expect(s2.conversations.summaries, hasLength(2));
      expect(resumed.conversation.title, 'What is 2+2?');

      final s3 = await _demo(store: store);
      expect((await s3.conversations.open(c.id))!.messages, hasLength(4));
    });

    test('AppState.open swaps the controller, jumps to the chat tab; unknown id is ignored', () async {
      final store = MemoryJsonStore();
      final s1 = await _demo(store: store);
      final first = ChatController(s1);
      await first.send('hello');
      final s2 = await _demo(store: store);
      final state = AppState(s2)..tab = 2;
      final before = state.chat;
      await state.open('does-not-exist');
      expect(state.chat, same(before));
      await state.open(first.conversation.id);
      expect(state.tab, 0);
      expect(state.chat.messages, hasLength(2));
      expect(state.chat.conversation.id, first.conversation.id);
    });

    test('AppState.newChat does nothing on an empty chat and starts fresh otherwise', () async {
      final s = await _demo();
      final state = AppState(s);
      final c0 = state.chat;
      state.newChat();
      expect(state.chat, same(c0));
      await state.chat.send('hi');
      final id = state.chat.conversation.id;
      state.newChat();
      expect(state.chat.messages, isEmpty);
      expect(state.chat.conversation.id, isNot(id));
      expect(s.conversations.summaries.single.id, id);
    });

    // BUG: new chat (the button is enabled while busy) disposes the old ChatController while its
    // send() is still running; send()'s finally block calls notifyListeners() on the disposed
    // controller, which throws "A ChatController was used after being disposed" as an unhandled error
    // and skips the final conversations.save(), so the finished answer is never persisted.
    test('starting a new chat while the old one is still answering does not throw', () async {
      final s = await _demo();
      final state = AppState(s);
      final old = state.chat;
      final f = old.send('Tell me a story');
      state.newChat();
      Object? err;
      try {
        await f;
      } catch (e) {
        err = e;
      }
      expect(err, isNull);
      expect(s.conversations.summaries, hasLength(1));
    });
  });

  group('disposed-controller races', () {
    // BUG: same root cause as above, via a chat row tap / AppState.open while an answer is streaming.
    test('opening another chat while answering does not throw', () async {
      final s = await _demo();
      final other = ChatController(s);
      await other.send('older');
      final state = AppState(s);
      final f = state.chat.send('Tell me a story');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      await state.open(other.conversation.id);
      Object? err;
      try {
        await f;
      } catch (e) {
        err = e;
      }
      expect(err, isNull);
    });

    // BUG: consequence of the above: the finished answer is lost from disk.
    test('an answer finished after the user left the chat is still saved', () async {
      final s = await _demo();
      final state = AppState(s);
      final old = state.chat;
      final f = old.send('Tell me a story');
      await Future<void>.delayed(const Duration(milliseconds: 30));
      state.newChat();
      try {
        await f;
      } catch (_) {}
      final saved = (await s.conversations.open(old.conversation.id))!;
      expect(saved.messages.last.text, old.messages.last.text);
    });
  });

  // ---------------------------------------------------------------------------
  group('prompts', () {
    test('system prompt lists attachments, memory and, without native tools, the tool format', () {
      final p = Prompts.system(
        now: DateTime(2026, 3, 4, 9, 5),
        attachments: const [Attachment(id: 'a1', kind: 'image', path: '/p', name: 'cat.png')],
        memory: '- likes tea',
        tools: const [
          ToolSpec(name: 'calculate', description: 'd', parameters: {'type': 'object'}),
        ],
        nativeTools: false,
      );
      expect(p, contains('Wednesday 2026-03-04 09:05'));
      expect(p, contains('- a1: image, "cat.png"'));
      expect(p, contains('likes tea'));
      expect(p, contains('```tool_call'));
      expect(p, contains('"calculate"'));
    });

    test('native tools or no tools: no tool block; no attachments/memory: no headings', () {
      for (final (native, tools) in [
        (true, const [ToolSpec(name: 'x', description: 'd', parameters: {})]),
        (false, const <ToolSpec>[]),
      ]) {
        final p = Prompts.system(
          now: DateTime(2026),
          attachments: const [],
          memory: '',
          tools: tools,
          nativeTools: native,
        );
        expect(p, isNot(contains('tool_call')));
        expect(p, isNot(contains('Attachments in this conversation')));
        expect(p, isNot(contains('remember')));
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Widgets
  // ---------------------------------------------------------------------------
  Future<(AppServices, AppState)> pumpChat(
    WidgetTester tester, {
    MemoryJsonStore? store,
    http.Client? client,
    int seed = 0,
    Size size = const Size(360, 690),
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final services = (await tester.runAsync(() async {
      final s = await _demo(store: store, client: client);
      for (var i = 0; i < seed; i++) {
        await ChatController(s).send('old chat number $i');
      }
      return s;
    }))!;
    final state = AppState(services);
    await tester.pumpWidget(
      AppScope(
        state: state,
        child: MaterialApp(theme: buildTheme(Brightness.light), home: const ChatScreen()),
      ),
    );
    await tester.pump(const Duration(seconds: 1));
    return (services, state);
  }

  Future<void> settle(WidgetTester tester, [int ms = 1500]) async {
    for (var i = 0; i < ms ~/ 50; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  group('chat screen', () {
    testWidgets('welcome screen at 360x690: suggestions, no carry-on, no copy button, new chat disabled', (
      tester,
    ) async {
      await pumpChat(tester);
      expect(find.text('record a meeting'), findsOneWidget);
      expect(find.text('carry on'), findsNothing);
      expect(find.byTooltip('Copy this chat'), findsNothing);
      expect(find.byTooltip('Past chats'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('welcome: three recent chats under "carry on", link to all, tapping one opens it', (tester) async {
      final (s, state) = await pumpChat(tester, seed: 5);
      expect(find.text('carry on'), findsOneWidget);
      expect(find.text('all 5 chats'), findsOneWidget);
      expect(find.textContaining('old chat number'), findsNWidgets(3 * 2)); // title + preview
      await tester.tap(find.text('old chat number 4').first);
      await settle(tester, 600);
      expect(state.chat.messages, hasLength(2));
      expect(state.chat.conversation.title, 'old chat number 4');
      expect(find.text('carry on'), findsNothing);
      expect(find.byTooltip('Copy this chat'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(s.conversations.summaries, hasLength(5));
    });

    testWidgets('welcome with 1-3 chats says "past chats" instead of a count', (tester) async {
      await pumpChat(tester, seed: 2);
      expect(find.text('past chats'), findsOneWidget);
      expect(find.textContaining('all 2'), findsNothing);
    });

    testWidgets('past chats sheet: empty state, then list with count/preview, "open now", delete', (tester) async {
      final (s, state) = await pumpChat(tester);
      await tester.tap(find.byTooltip('Past chats'));
      await settle(tester, 600);
      expect(find.text('nothing yet'), findsOneWidget);
      expect(find.text('start a new chat'), findsOneWidget);
      await tester.tapAt(const Offset(10, 10));
      await settle(tester, 600);

      await tester.runAsync(() => state.chat.send('first question'));
      await tester.runAsync(() => ChatController(s).send('another chat'));
      await tester.pump();
      await tester.tap(find.byTooltip('Past chats'));
      await settle(tester, 600);
      expect(find.text('first question'), findsWidgets);
      expect(find.textContaining('open now'), findsOneWidget);
      expect(find.textContaining('1 message'), findsWidgets);
      expect(tester.takeException(), isNull);

      await tester.tap(find.byTooltip('Delete chat').first);
      await settle(tester, 300);
      expect(s.conversations.summaries, hasLength(1));
      expect(find.text('another chat'), findsNothing, reason: 'first row (the newest) was deleted');
    });

    testWidgets('past chats: "start a new chat" resets the conversation', (tester) async {
      final (_, state) = await pumpChat(tester);
      await tester.runAsync(() => state.chat.send('hello'));
      await tester.pump();
      await tester.tap(find.byTooltip('Past chats'));
      await settle(tester, 600);
      await tester.tap(find.text('start a new chat'));
      await settle(tester, 600);
      expect(state.chat.messages, isEmpty);
      expect(find.text('record a meeting'), findsOneWidget);
    });

    testWidgets('past chats: tapping a row opens it and closes the sheet', (tester) async {
      final (_, state) = await pumpChat(tester, seed: 4);
      await tester.tap(find.text('all 4 chats'));
      await settle(tester, 600);
      expect(find.text('past chats'), findsWidgets);
      await tester.tap(find.text('old chat number 0').last);
      await settle(tester, 800);
      expect(state.chat.conversation.title, 'old chat number 0');
      expect(find.text('start a new chat'), findsNothing);
    });

    testWidgets('deleting the chat that is open from the sheet: list updates, chat on screen stays', (tester) async {
      final (s, state) = await pumpChat(tester);
      await tester.runAsync(() => state.chat.send('current chat'));
      await tester.pump();
      await tester.tap(find.byTooltip('Past chats'));
      await settle(tester, 600);
      await tester.tap(find.byTooltip('Delete chat'));
      await settle(tester, 300);
      expect(find.text('nothing yet'), findsOneWidget);
      expect(s.conversations.summaries, isEmpty);
      expect(tester.takeException(), isNull);
    });

    testWidgets('copy chat button puts the whole transcript on the clipboard and confirms', (tester) async {
      final (_, state) = await pumpChat(tester);
      await tester.runAsync(() => state.chat.send('What is 18% of 2450?'));
      await tester.pump();
      await tester.tap(find.byTooltip('Copy this chat'));
      await tester.pump();
      expect(clipboardWrites, hasLength(1));
      expect(clipboardWrites.single, ConversationStore.transcript(state.chat.conversation));
      expect(clipboardWrites.single, startsWith('What is 18% of 2450?'));
      expect(clipboardWrites.single, contains('PhoneDots:'));
      expect(find.text('chat copied'), findsOneWidget);
      await settle(tester, 2500);
    });

    testWidgets('per-message copy copies only that reply; retry button only on the last reply', (tester) async {
      final (_, state) = await pumpChat(tester);
      await tester.runAsync(() => state.chat.send('What is 18% of 2450?'));
      await tester.runAsync(() => state.chat.send('hello'));
      await tester.pump();
      expect(find.byTooltip('Copy'), findsNWidgets(2));
      expect(find.byTooltip('Try again'), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('Copy').first);
      await tester.pump();
      await tester.tap(find.byTooltip('Copy').first);
      await tester.pump();
      expect(clipboardWrites.single, state.chat.messages[1].text);
      expect(find.text('copied'), findsOneWidget);
      await settle(tester, 2500);
    });

    testWidgets('retry button re-asks the last question', (tester) async {
      final (_, state) = await pumpChat(tester);
      await tester.runAsync(() => state.chat.send('What is 18% of 2450?'));
      await tester.pump();
      final oldId = state.chat.messages.last.id;
      await tester.tap(find.byTooltip('Try again'));
      await settle(tester, 2000);
      expect(state.chat.messages, hasLength(2));
      expect(state.chat.messages.last.id, isNot(oldId));
      expect(state.chat.messages.last.text, contains('441'));
    });

    testWidgets('typing and sending shows both bubbles, step tile and clears the box', (tester) async {
      final (_, state) = await pumpChat(tester);
      await tester.enterText(find.byType(TextField), 'What is 18% of 2450?');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send'));
      await settle(tester, 2000);
      expect(state.chat.messages, hasLength(2));
      expect(find.text('What is 18% of 2450?'), findsWidgets);
      expect(find.text('calculate'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, '');
      expect(tester.takeException(), isNull);
    });

    testWidgets('whitespace-only input cannot be sent', (tester) async {
      final (_, state) = await pumpChat(tester);
      await tester.enterText(find.byType(TextField), '   \n  ');
      await tester.pump();
      await tester.tap(find.bySemanticsLabel('Send'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.chat.messages, isEmpty);
      expect(find.text('record a meeting'), findsOneWidget);
    });

    testWidgets('very long message in a 360px column wraps without overflow', (tester) async {
      final (_, state) = await pumpChat(tester);
      await tester.runAsync(() => state.chat.send('${'unbreakable' * 40} ${'word ' * 400}'));
      await settle(tester, 300);
      expect(tester.takeException(), isNull);
    });

    testWidgets('stop button appears while answering and halts generation', (tester) async {
      final (_, state) = await pumpChat(tester);
      unawaited(state.chat.send('Tell me a story'));
      await tester.pump(const Duration(milliseconds: 100));
      final stop = find.byWidgetPredicate((w) => w is DoodleIcon && w.semanticLabel == 'Stop');
      expect(stop, findsOneWidget);
      await tester.tap(stop);
      await settle(tester, 1500);
      expect(state.chat.busy, isFalse);
      expect(find.byWidgetPredicate((w) => w is DoodleIcon && w.semanticLabel == 'Send'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('new chat button returns to the welcome screen and keeps the old chat in the list', (tester) async {
      final (s, state) = await pumpChat(tester);
      await tester.runAsync(() => state.chat.send('hello'));
      await tester.pump();
      await tester.tap(find.byTooltip('New chat'));
      await settle(tester, 600);
      expect(find.text('record a meeting'), findsOneWidget);
      expect(find.text('carry on'), findsOneWidget);
      expect(s.conversations.summaries, hasLength(1));
    });

    testWidgets('a suggestion that sends (set a timer) runs through the fast tool path', (tester) async {
      final (_, state) = await pumpChat(tester);
      await tester.tap(find.text('set a timer'));
      await settle(tester, 2500);
      expect(state.chat.messages.first.text, 'Set a timer for 10 minutes');
      expect(state.chat.messages.last.steps.single.skillId, 'set_timer');
      expect(tester.takeException(), isNull);
    });

    testWidgets('a suggestion that only fills the box (redact) does not send', (tester) async {
      final (_, state) = await pumpChat(tester);
      await tester.tap(find.text('mask before you share'));
      await tester.pump(const Duration(milliseconds: 300));
      expect(state.chat.messages, isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, startsWith('Redact my email'));
    });

    testWidgets('shared content (intake) opens a fresh chat with text and attachment ready', (tester) async {
      final (s, state) = await pumpChat(tester);
      await tester.runAsync(() => state.chat.send('hello'));
      await tester.pump();
      s.intake.value = const SharedIntake(
        text: 'shared words',
        attachments: [Attachment(id: 'a1', kind: 'document', path: '/x/shared.txt', name: 'shared.txt')],
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(s.intake.value, isNull);
      expect(state.chat.messages, isEmpty);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text, 'shared words');
      expect(find.text('shared.txt'), findsOneWidget);
    });

    testWidgets('permission sheet: allow runs the skill, remembered for first-time skills', (tester) async {
      final (s, state) = await pumpChat(tester);
      final k = s.skills.byId('read_clipboard')!;
      unawaited(state.chat.runSkill(k, {}));
      await settle(tester, 600);
      expect(find.text('allow read clipboard?'), findsOneWidget);
      expect(find.textContaining('You will not be asked again'), findsOneWidget);
      await tester.tap(find.text('allow'));
      await settle(tester, 1200);
      expect(state.chat.messages.last.steps.single.status, StepStatus.done);
      expect(s.settings.grantedSkills, contains('read_clipboard'));
    });

    // BUG: AppState.startChat (skills "Try it", saved-post actions) swaps in a fresh ChatController
    // when the current chat has messages, then runs the action immediately. ChatScreen only wires
    // onConfirm in didChangeDependencies on the next frame, so the action sees onConfirm == null and
    // every skill that needs permission is silently declined without ever asking.
    testWidgets('startChat from a non-empty chat still asks permission for call_number', (tester) async {
      final (s, state) = await pumpChat(tester);
      await tester.runAsync(() => state.chat.send('hello'));
      await tester.pump();
      final k = s.skills.byId('call_number')!;
      state.startChat((chat) => chat.runSkill(k, {'number': '123'}, label: 'call'));
      await settle(tester, 800);
      expect(find.text('allow call?'), findsOneWidget);
      await tester.tap(find.text('allow'));
      await settle(tester, 1200);
      expect(state.chat.messages.last.steps.single.status, StepStatus.done);
    });

    testWidgets('startChat from an empty chat asks permission (control for the test above)', (tester) async {
      final (s, state) = await pumpChat(tester);
      final k = s.skills.byId('call_number')!;
      state.startChat((chat) => chat.runSkill(k, {'number': '123'}, label: 'call'));
      await settle(tester, 800);
      expect(find.text('allow call?'), findsOneWidget);
      await tester.tap(find.text('allow'));
      await settle(tester, 1200);
    });

    testWidgets('permission sheet: dismissing it (back/scrim) counts as no', (tester) async {
      final (s, state) = await pumpChat(tester);
      final k = s.skills.byId('call_number')!;
      unawaited(state.chat.runSkill(k, {'number': '123'}));
      await settle(tester, 600);
      expect(find.text('allow call?'), findsOneWidget);
      expect(find.textContaining('number: 123'), findsOneWidget);
      expect(find.textContaining('not be asked again'), findsNothing, reason: 'always-ask skills never remember');
      await tester.tapAt(const Offset(180, 20));
      await settle(tester, 1000);
      expect(state.chat.messages.last.steps.single.status, StepStatus.declined);
      expect(find.text('you said no'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------------------
  group('message view', () {
    Future<void> pumpMessage(
      WidgetTester tester,
      ChatMessage m, {
      bool isLast = true,
      VoidCallback? onModels,
      VoidCallback? onRetry,
    }) async {
      tester.view.physicalSize = const Size(360, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(() => _demo()))!;
      await tester.pumpWidget(
        AppScope(
          state: AppState(s),
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(
              body: SingleChildScrollView(
                child: MessageView(message: m, isLast: isLast, onOpenModels: onModels, onRetry: onRetry),
              ),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 500));
    }

    testWidgets('streaming reply with nothing yet shows dots, no footer', (tester) async {
      await pumpMessage(tester, ChatMessage(id: 'r', isUser: false, streaming: true));
      expect(find.byTooltip('Copy'), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('error reply that mentions Models offers the models shortcut', (tester) async {
      var opened = 0;
      await pumpMessage(
        tester,
        ChatMessage(
          id: 'r',
          isUser: false,
          error: 'No language model yet. Download Gemma 4 E2B in Models to start chatting.',
        ),
        onModels: () => opened++,
      );
      await tester.tap(find.text('open models'));
      expect(opened, 1);
      expect(find.byTooltip('Copy'), findsNothing, reason: 'nothing to copy when the reply has no text');
    });

    testWidgets('thinking section expands; user message with attachments and long file name lays out', (tester) async {
      await pumpMessage(tester, ChatMessage(id: 'r', isUser: false, text: 'ok', thinking: 'hmm ' * 100));
      await tester.tap(find.text('thinking'));
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.textContaining('hmm hmm'), findsOneWidget);
      await pumpMessage(
        tester,
        ChatMessage(
          id: 'u',
          isUser: true,
          text: 'look',
          attachments: [
            const Attachment(id: 'a1', kind: 'image', path: '/missing.png', name: 'img.png'),
            const Attachment(
              id: 'a2',
              kind: 'audio',
              path: '/missing.m4a',
              name: 'a_really_long_recording_name_that_goes_on_and_on_forever.m4a',
            ),
            const Attachment(id: 'a3', kind: 'document', path: '/missing.txt', name: 'n.txt'),
          ],
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('every step status renders; tapping a step opens the trace sheet', (tester) async {
      final steps = [
        for (final st in StepStatus.values)
          AgentStep(
            skillId: 'calculate',
            skillName: 'Calculate',
            args: {'e': '1'},
            status: st,
            via: st == StepStatus.done ? 'router' : 'planner',
            result: st == StepStatus.failed ? {'error': 'x' * 300} : {'a': 1},
            ms: 1234,
          )..progress = st == StepStatus.running ? 'halfway' : null,
      ];
      await pumpMessage(tester, ChatMessage(id: 'r', isUser: false, text: 'done', steps: steps));
      expect(find.text('halfway'), findsOneWidget);
      expect(find.text('you said no'), findsOneWidget);
      expect(find.text('fast path'), findsOneWidget);
      await tester.tap(find.text('calculate').first);
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('what went in'), findsOneWidget);
      expect(find.text('what came out'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('markdown-ish reply text with code, lists and long lines renders', (tester) async {
      await pumpMessage(
        tester,
        ChatMessage(
          id: 'r',
          isUser: false,
          text:
              '# Title\n\n**bold** _it_ `code`\n\n- one\n- two\n\n1. a\n2. b\n\n```\nlong_code_line_${'x' * 200}\n```\n\n${'long ' * 200}\n\n[link](https://x.y) ***',
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  group('result cards (360x690)', () {
    Future<void> pumpCard(WidgetTester tester, UiCard card) async {
      tester.view.physicalSize = const Size(360, 690);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final s = (await tester.runAsync(() => _demo()))!;
      await tester.pumpWidget(
        AppScope(
          state: AppState(s),
          child: MaterialApp(
            theme: buildTheme(Brightness.light),
            home: Scaffold(
              body: SingleChildScrollView(padding: const EdgeInsets.symmetric(horizontal: 16), child: ResultCard(card)),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 900));
    }

    final long = 'supercalifragilistic' * 12;
    final cards = <String, UiCard>{
      'text': UiCard('text', title: 'Plain', data: {'text': 'hello\nworld $long', 'copy': true}),
      'text empty': const UiCard('text', data: {}),
      'unknown type falls back to text': const UiCard('mystery', data: {'text': 'fallback'}),
      'kv': UiCard(
        'kv',
        title: 'Details',
        data: {'name': 'Ann', 'long key that is quite long': long, 'n': 5, 'demo': true},
      ),
      'kv empty': const UiCard('kv', data: {}),
      'table wide': UiCard(
        'table',
        title: 'T',
        data: {
          'columns': ['a', 'b', 'c', 'd', 'e', 'f', 'g'],
          'rows': [
            for (var i = 0; i < 20; i++) ['row $i', long, 3, null, true, 'x', 'y'],
          ],
        },
      ),
      'table ragged': const UiCard(
        'table',
        data: {
          'columns': ['a'],
          'rows': [
            ['1', '2', '3'],
            [],
          ],
        },
      ),
      'table empty': const UiCard('table', data: {'columns': [], 'rows': []}),
      'table no columns': const UiCard(
        'table',
        data: {
          'rows': [
            ['x', 'y'],
          ],
        },
      ),
      'checklist': UiCard(
        'checklist',
        title: 'Pack',
        data: {
          'items': ['Passport', 'Charger', long, for (var i = 0; i < 30; i++) 'item $i'],
        },
      ),
      'checklist readonly': const UiCard(
        'checklist',
        data: {
          'readonly': true,
          'items': ['a', 'b'],
        },
      ),
      'checklist empty': const UiCard('checklist', data: {'items': []}),
      'transcript one speaker': UiCard(
        'transcript',
        data: {
          'segments': [
            {'speaker': 0, 'start': 0.0, 'end': 3.0, 'text': 'Hello there'},
            {'speaker': 0, 'start': 3.5, 'end': 6.0, 'text': long},
          ],
        },
      ),
      'transcript many speakers + >40 segments': UiCard(
        'transcript',
        data: {
          'segments': [
            for (var i = 0; i < 55; i++) {'speaker': i % 6, 'start': i * 7.5, 'end': i * 7.5 + 5, 'text': 'line $i'},
          ],
        },
      ),
      'transcript no speaker/start': const UiCard(
        'transcript',
        data: {
          'segments': [
            {'text': 'only text'},
            {'text': 'again', 'start': 61},
          ],
        },
      ),
      'transcript empty': const UiCard('transcript', data: {}),
      'tags': UiCard(
        'tags',
        data: {
          'tags': ['a', 'bb', long, for (var i = 0; i < 25; i++) '#tag$i'],
        },
      ),
      'tags large (emoji)': const UiCard(
        'tags',
        data: {
          'large': true,
          'tags': ['✨', '🎉', '😀', '👍', '🔥', '🙂', '😎', '🤖', '💡'],
        },
      ),
      'tags empty': const UiCard('tags', data: {}),
      'bars': UiCard(
        'bars',
        title: 'Chart',
        data: {
          'labels': ['alpha', 'beta', long, 'delta'],
          'values': [4, 2.5, 10, 0],
        },
      ),
      'bars all zero': const UiCard(
        'bars',
        data: {
          'labels': ['a', 'b'],
          'values': [0, 0],
        },
      ),
      'bars negative': const UiCard(
        'bars',
        data: {
          'labels': ['a', 'b'],
          'values': [-3, -9],
        },
      ),
      'bars mismatched lengths': const UiCard(
        'bars',
        data: {
          'labels': ['a', 'b', 'c'],
          'values': [1],
        },
      ),
      'bars empty': const UiCard('bars', data: {}),
      'bars single huge': const UiCard(
        'bars',
        data: {
          'labels': ['a'],
          'values': [123456789012.5],
        },
      ),
      'timeline': UiCard(
        'timeline',
        title: 'Today',
        data: {
          'items': [
            {'time': '09:00', 'text': 'Standup'},
            {'time': '10:30', 'text': long},
            {'time': '12:00', 'text': ''},
          ],
        },
      ),
      'timeline empty': const UiCard('timeline', data: {'items': []}),
      'image missing file': const UiCard('image', title: 'Pic', data: {'path': '/no/such/file.png'}),
      'image null path': const UiCard('image', data: {}),
      'file with preview': UiCard('file', title: 'Saved', data: {'path': '/a/b/notes.txt', 'preview': 'line\n' * 100}),
      'file audio, no path': const UiCard('file', data: {'kind': 'audio'}),
      'file long name': UiCard('file', data: {'path': '/x/$long.txt'}),
      'link rich': UiCard(
        'link',
        title: 'Link',
        data: {
          'platform': 'youtube',
          'kind': 'video',
          'title': 'How LiteRT works $long',
          'author': 'Google for Developers',
          'description': 'A description. ' * 40,
          'rich': true,
          'url': 'https://youtu.be/x',
        },
      ),
      'link not rich': const UiCard(
        'link',
        data: {
          'platform': 'instagram',
          'kind': 'post',
          'title': 'Post',
          'rich': false,
          'url': 'https://instagram.com/p/x',
        },
      ),
      for (final p in ['tiktok', 'github', 'medium', 'linkedin', 'threads', 'x', 'web'])
        'link $p': UiCard('link', data: {'platform': p, 'kind': 'page', 'title': p, 'url': 'https://$p.com'}),
      'title very long': UiCard('text', title: long, data: {'text': 'x', 'demo': true}),
    };

    for (final e in cards.entries) {
      testWidgets('renders: ${e.key}', (tester) async {
        await pumpCard(tester, e.value);
        expect(tester.takeException(), isNull);
        expect(find.byType(ResultCard), findsOneWidget);
      });
    }

    testWidgets('checklist items tick and untick, readonly ones do not', (tester) async {
      await pumpCard(
        tester,
        const UiCard(
          'checklist',
          data: {
            'items': ['one', 'two'],
          },
        ),
      );
      await tester.tap(find.text('one'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('one'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
      await pumpCard(
        tester,
        const UiCard(
          'checklist',
          data: {
            'readonly': true,
            'items': ['one'],
          },
        ),
      );
      await tester.tap(find.text('one'), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 500));
      expect(tester.takeException(), isNull);
    });

    testWidgets('text card copy link puts the text on the clipboard', (tester) async {
      await pumpCard(tester, const UiCard('text', data: {'text': 'copy me', 'copy': true}));
      await tester.tap(find.text('copy'));
      await tester.pump();
      expect(clipboardWrites, ['copy me']);
      await settle(tester, 2500);
    });

    testWidgets('file card copy puts the preview on the clipboard', (tester) async {
      await pumpCard(tester, const UiCard('file', data: {'path': '/a/b.txt', 'preview': 'PREVIEW'}));
      expect(find.text('b.txt'), findsOneWidget);
      await tester.tap(find.text('copy'));
      await tester.pump();
      expect(clipboardWrites, ['PREVIEW']);
      await settle(tester, 2500);
    });

    testWidgets('demo-flagged card shows the demo tag', (tester) async {
      await pumpCard(tester, const UiCard('text', title: 'Hi', data: {'text': 'x', 'demo': true}));
      expect(find.text('demo data'), findsOneWidget);
    });

    // Malformed skill data should degrade gracefully, never red-screen the chat.
    // BUG (robustness): _Bars does `(e as num)` and _Transcript does `s['speaker'] as int`; community
    // skills / odd model output with strings in those fields throw during build.
    testWidgets('bars with numeric strings do not crash the chat', (tester) async {
      await pumpCard(
        tester,
        const UiCard(
          'bars',
          data: {
            'labels': ['a', 'b'],
            'values': ['3', '4'],
          },
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('transcript with a mix of missing and present speakers does not crash', (tester) async {
      await pumpCard(
        tester,
        const UiCard(
          'transcript',
          data: {
            'segments': [
              {'speaker': 0, 'text': 'a'},
              {'text': 'b'},
            ],
          },
        ),
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('table rows that are not lists do not crash', (tester) async {
      await pumpCard(
        tester,
        const UiCard(
          'table',
          data: {
            'columns': ['a'],
            'rows': ['not a list'],
          },
        ),
      );
      expect(tester.takeException(), isNull);
    });
  });

  // ---------------------------------------------------------------------------
  group('cards produced by real skills render in the chat', () {
    testWidgets('checklist, redact, calculate, datetime flows end to end at 360x690', (tester) async {
      final (_, state) = await pumpChat(tester);
      for (final q in [
        'Make me a checklist',
        'What is 18% of 2450?',
        'redact my email bob@acme.com',
        'what time is it',
      ]) {
        await tester.runAsync(() => state.chat.send(q));
        await tester.pump(const Duration(milliseconds: 600));
        expect(tester.takeException(), isNull, reason: q);
      }
      expect(state.chat.messages, hasLength(8));
      expect(state.chat.messages.expand((m) => m.cards), isNotEmpty);
    });

    testWidgets('link read shows a link card in the reply', (tester) async {
      final (_, state) = await pumpChat(
        tester,
        client: MockClient(
          (r) async => http.Response(jsonEncode({'title': 'How LiteRT works', 'author_name': 'G'}), 200),
        ),
      );
      await tester.runAsync(() => state.chat.send('https://youtu.be/dCS4er4Xcjo'));
      await tester.pump(const Duration(milliseconds: 800));
      expect(find.text('How LiteRT works'), findsWidgets);
      expect(find.text('open'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

class SocketLikeException implements Exception {
  const SocketLikeException();
  @override
  String toString() => 'SocketException: connection refused';
}

/// Source text of the lib/ folder, keyed by path (used for the "is saveError displayed" check).
Future<Map<String, String>> _readLib() async {
  final out = <String, String>{};
  // flutter test runs with the package root as cwd.
  final dir = Directory('lib');
  for (final f in dir.listSync(recursive: true).whereType<File>()) {
    if (f.path.endsWith('.dart')) out[f.path] = f.readAsStringSync();
  }
  return out;
}
