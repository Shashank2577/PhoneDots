import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/app_state.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/main.dart';

void main() {
  testWidgets('welcome, setup, then every tab', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final services = await tester.runAsync(() => AppServices.create(store: MemoryJsonStore(), platform: 'demo'));
    await tester.pumpWidget(PhoneDotsApp(state: AppState(services!)));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('your assistant'), findsWidgets);

    await tester.tap(find.text("let's start"));
    await tester.pump(const Duration(seconds: 1));
    expect(find.textContaining('you decide'), findsWidgets);

    await tester.tap(find.text('start · download later'));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('record a meeting'), findsOneWidget);

    await tester.tap(find.text('skills').last);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('transcribe audio'), findsOneWidget);

    await tester.tap(find.text('models').last);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('the models'), findsOneWidget);

    await tester.tap(find.text('you').last);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('privacy'), findsOneWidget);
  });
}
