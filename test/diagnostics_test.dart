import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:phonedots/agent/agent.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/core/app_log.dart';
import 'package:phonedots/core/crash_reporter.dart';
import 'package:phonedots/core/ledger.dart';
import 'package:phonedots/core/runtime/demo_engines.dart';
import 'package:phonedots/core/runtime/engine_types.dart';
import 'package:phonedots/core/settings.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/skills/skill.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// A model that never answers, like a stuck generation on a phone. As with
/// the real engine, cancelling ends its stream.
class _SilentEngine extends DemoLlmEngine {
  int cancels = 0;
  StreamController<GenEvent>? _c;
  @override
  Stream<GenEvent> generate(GenerationRequest request) => (_c = StreamController<GenEvent>()).stream;
  @override
  Future<void> cancel() async {
    cancels++;
    await _c?.close();
  }
}

/// A model that starts, then goes quiet.
class _StallingEngine extends _SilentEngine {
  @override
  Stream<GenEvent> generate(GenerationRequest request) {
    final s = super.generate(request);
    _c!.add(const TokenEvent('Let me check'));
    return s;
  }
}

void main() {
  setUp(() async {
    await appLog.clear();
    ChatController.outputLimit = const Duration(milliseconds: 200);
  });
  tearDown(() {
    ChatController.outputLimit = const Duration(seconds: 150);
  });

  test('a model that never answers ends with a clear error, not endless dots', () async {
    final engine = _SilentEngine();
    final s = await AppServices.create(store: MemoryJsonStore(), platform: 'demo', llm: engine);
    final chat = ChatController(s);
    await chat.send('what is on my calendar this week?').timeout(const Duration(seconds: 5));
    final reply = chat.messages.last;
    expect(reply.streaming, isFalse);
    expect(chat.busy, isFalse);
    expect(reply.error, contains('did not start answering'));
    expect(engine.cancels, greaterThan(0));
    expect(appLog.entries.any((e) => e.level == LogLevel.error && e.message.contains('no output')), isTrue);
  });

  test('a model that stalls mid-answer is stopped too', () async {
    final s = await AppServices.create(store: MemoryJsonStore(), platform: 'demo', llm: _StallingEngine());
    final chat = ChatController(s);
    await chat.send('text Sam I am late').timeout(const Duration(seconds: 5));
    expect(chat.messages.last.error, contains('stopped responding'));
    expect(chat.messages.last.text, contains('Let me check'));
  });

  test('a phone action that never answers fails after its limit', () async {
    final s = await AppServices.create(store: MemoryJsonStore(), platform: 'demo');
    final hang = FnSkill(
      id: 'qa_hang',
      name: 'Hang',
      description: 'never returns',
      kind: SkillKind.device,
      category: SkillCategory.phone,
      handler: (a, c) => Completer<SkillResult>().future,
    );
    s.skills.builtIns.add(hang);
    // Device actions get 30 s; run with fake time so the test is instant.
    final chat = ChatController(s);
    final done = chat.runSkill(hang, {});
    await Future<void>.delayed(Duration.zero);
    expect(chat.busy, isTrue);
    await done.timeout(const Duration(seconds: 40));
    expect(chat.messages.last.steps.single.result['error'], contains('did not answer within 30 seconds'));
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('the log records steps and timings but never what was written', () async {
    final s = await AppServices.create(store: MemoryJsonStore(), platform: 'demo');
    final chat = ChatController(s);
    await chat.send('My secret plan: call Bob at 555-0100 about the surprise party');
    final text = appLog.export();
    expect(text, contains('message sent'));
    expect(text, contains('planner round 1'));
    expect(text, isNot(contains('secret')));
    expect(text, isNot(contains('555-0100')));
    expect(text, isNot(contains('Bob')));
  });

  test('crash reports are only sent when switched on with an https address', () async {
    final store = MemoryJsonStore();
    final settings = AppSettings(store);
    final sent = <http.Request>[];
    final reporter = CrashReporter(
      settings: settings,
      ledger: Ledger(store),
      client: MockClient((r) async {
        sent.add(r);
        return http.Response('', 204);
      }),
    );
    expect(await reporter.send('boom'), isFalse);
    await settings.update((x) => x.crashReports = true);
    expect(await reporter.send('boom'), isFalse, reason: 'no address yet');
    await settings.update((x) => x.crashReportUrl = 'http://insecure.example/crash');
    expect(await reporter.send('boom'), isFalse, reason: 'https only');
    await settings.update((x) => x.crashReportUrl = 'https://reports.example/crash');
    expect(await reporter.send('boom', device: {'ramMb': 8000}), isTrue);
    expect(sent.single.url.host, 'reports.example');
    expect(sent.single.body, contains('"crash":"boom"'));
  });
}
