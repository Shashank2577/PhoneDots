import 'package:flutter_test/flutter_test.dart';
import 'package:phonedots/agent/agent.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';

void main() {
  testWidgets('debug', (t) async {
    final s = (await t.runAsync(() => AppServices.create(store: MemoryJsonStore(), platform: 'demo')))!;
    final chat = ChatController(s);
    chat.send('What is 18% of 2450?');
    for (var i = 0; i < 40; i++) {
      await t.pump(const Duration(milliseconds: 100));
    }
    // ignore: avoid_print
    print(
      'busy=${chat.busy} text=${chat.messages.last.text} steps=${chat.messages.last.steps.map((x) => '${x.skillId}:${x.status}')}',
    );
  });
}
