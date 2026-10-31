import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/app_state.dart';
import 'package:phonedots/core/app_log.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/features/settings/logs_screen.dart';
import 'package:phonedots/theme/theme.dart';

void main() {
  test('the log keeps the newest 500 lines and survives a restart', () async {
    final store = MemoryJsonStore();
    final log = AppLog(store);
    for (var i = 0; i < AppLog.limit + 3; i++) {
      log.add('models', 'step $i');
    }
    expect(log.lines, hasLength(AppLog.limit));
    expect(log.lines.last, endsWith('[models] step ${AppLog.limit + 2}'));
    await Future<void>.delayed(const Duration(milliseconds: 1100)); // The deferred save.
    final again = AppLog(store);
    await again.load();
    expect(again.lines, hasLength(AppLog.limit));
    expect(again.text(header: 'PhoneDots'), startsWith('PhoneDots\n'));
    await again.clear();
    final cleared = AppLog(store);
    await cleared.load();
    expect(cleared.lines, isEmpty);
  });

  testWidgets('the logs screen shows the lines and copies them with a header', (tester) async {
    final services = await tester.runAsync(() => AppServices.create(store: MemoryJsonStore(), platform: 'demo'));
    services!.log.add('models', 'gemma-4-e2b: checksum ok');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
      return null;
    });
    await tester.pumpWidget(
      AppScope(
        state: AppState(services),
        child: MaterialApp(theme: buildTheme(Brightness.light), home: const LogsScreen()),
      ),
    );
    await tester.pump();
    expect(find.textContaining('gemma-4-e2b: checksum ok'), findsOneWidget);
    await tester.tap(find.text('Copy all'));
    await tester.pump();
    expect(copied, startsWith('PhoneDots 0.2.0+2'));
    expect(copied, contains('[models] gemma-4-e2b: checksum ok'));
    expect(copied, contains('[app] PhoneDots 0.2.0+2 started on demo'));
  });
}
