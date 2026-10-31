import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonedots/agent/agent.dart';
import 'package:phonedots/agent/conversation.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/core/models/model_catalog.dart';
import 'package:phonedots/core/models/model_manager.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/knowledge/knowledge_base.dart';
import 'package:phonedots/skills/skill.dart';

Future<AppServices> demoServices() => AppServices.create(store: MemoryJsonStore(), platform: 'demo');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.getData') return {'text': ''};
        return null;
      },
    );
  });

  test('registry exposes the built-in catalog', () async {
    final s = await demoServices();
    expect(s.skills.builtIns.length, greaterThanOrEqualTo(55));
    final ids = s.skills.all.map((k) => k.id).toList();
    expect(ids.toSet().length, ids.length, reason: 'skill ids must be unique');
    for (final k in s.skills.all) {
      expect(RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(k.id), isTrue, reason: k.id);
      expect(k.toToolSpec().parameters['type'], 'object');
    }
  });

  test('selector favours relevant skills and attachments', () async {
    final s = await demoServices();
    final timer = s.skills.selectFor('set a timer for ten minutes').map((k) => k.id);
    expect(timer, contains('set_timer'));
    final audio = s.skills
        .selectFor(
          'make minutes',
          attachments: const [Attachment(id: 'a1', kind: 'audio', path: '/x.wav', name: 'x.wav')],
        )
        .map((k) => k.id);
    expect(audio, contains('meeting_minutes'));
    expect(audio.length, lessThanOrEqualTo(12));
  });

  test('agent runs a tool loop end to end', () async {
    final s = await demoServices();
    final chat = ChatController(s);
    await chat.send('What is 18% of 2450?');
    final reply = chat.messages.last;
    expect(reply.steps.single.skillId, 'calculate');
    expect(reply.steps.single.status, StepStatus.done);
    expect(reply.steps.single.result['result'], '441');
    expect(reply.text, contains('441'));
    expect(s.conversations.summaries, hasLength(1));
  });

  test('confirmation gate blocks declined actions', () async {
    final s = await demoServices();
    final chat = ChatController(s)..onConfirm = (_, _) async => false;
    final skill = s.skills.byId('call_number')!;
    await chat.runSkill(skill, {'number': '123'});
    expect(chat.messages.last.steps.single.status, StepStatus.declined);
  });

  test('first-time permission is remembered', () async {
    final s = await demoServices();
    var asked = 0;
    final chat = ChatController(s)
      ..onConfirm = (_, _) async {
        asked++;
        return true;
      };
    final skill = s.skills.byId('read_clipboard')!;
    await chat.runSkill(skill, {});
    await chat.runSkill(skill, {});
    expect(asked, 1);
  });

  test('recipes chain skills', () async {
    final s = await demoServices();
    final chat = ChatController(s);
    final recipe = s.skills.byId('recipe_private_share')!;
    await chat.runSkill(recipe, {'input': 'Mail me at jo@example.com'});
    final step = chat.messages.last.steps.single;
    expect(step.status, StepStatus.done, reason: '${step.result}');
    expect(step.cards.first.data['text'], contains('[EMAIL_1]'));
  });

  test('memory skills round-trip', () async {
    final s = await demoServices();
    final chat = ChatController(s);
    await chat.send('Remember that I am vegetarian');
    expect(s.memory.facts.single.text, 'I am vegetarian');
    expect(s.memory.recall('food preferences vegetarian'), contains('I am vegetarian'));
  });

  test('knowledge base finds the right passage', () async {
    final s = await demoServices();
    await s.knowledge.add('Lease', 'The landlord said the deposit will be returned within 30 days after move out.');
    await s.knowledge.add('Recipe', 'Mix flour, sugar and eggs. Bake for 20 minutes.');
    final hits = await s.knowledge.search('when do I get my deposit back');
    expect(hits.first['title'], 'Lease');
    expect(KnowledgeBase.chunk(List.filled(300, 'w').join(' ')).length, 3);
  });

  test('conversations persist and reload', () async {
    final store = MemoryJsonStore();
    final s = await AppServices.create(store: store, platform: 'demo');
    final chat = ChatController(s);
    await chat.send('What is 2+2?');
    final again = await AppServices.create(store: store, platform: 'demo');
    final c = await again.conversations.open(chat.conversation.id);
    expect(c!.messages, hasLength(2));
    expect(c.messages.last.steps.single.skillId, 'calculate');
  });

  test('gated models: access classification and download guard', () async {
    expect(classifyAccess(206, hasToken: true), Access.ok);
    expect(classifyAccess(302, hasToken: true), Access.ok);
    expect(classifyAccess(401, hasToken: false), Access.needsToken);
    expect(classifyAccess(401, hasToken: true), Access.badToken);
    expect(classifyAccess(403, hasToken: true), Access.needsLicence);

    final fg = modelById('functiongemma-270m-mobile-actions')!;
    expect(fg.gated, isTrue);
    expect(modelById('gemma-4-e2b')!.gated, isFalse);

    // On a phone (not demo) with no token, a gated download fails fast with guidance.
    final s = await AppServices.create(store: MemoryJsonStore(), platform: 'demo');
    expect(s.models.canTryDownload(fg), isTrue, reason: 'demo engine never blocks');
  });
}
