import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:phonedots/app_services.dart';
import 'package:phonedots/app_state.dart';
import 'package:phonedots/core/storage/memory_json_store.dart';
import 'package:phonedots/main.dart';

void main() {
  testWidgets('onboarding then shell with all tabs', (tester) async {
    tester.view.physicalSize = const Size(1170, 2532);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
    final services = await tester.runAsync(() => AppServices.create(store: MemoryJsonStore(), platform: 'demo'));
    await tester.pumpWidget(PhoneDotsApp(state: AppState(services!)));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('AI that lives'), findsOneWidget);

    await tester.tap(find.text('Skip'));
    await tester.pump(const Duration(seconds: 2));
    expect(find.textContaining('What can I do'), findsOneWidget);

    await tester.tap(find.text('Skills').last);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Transcribe audio'), findsOneWidget);

    await tester.tap(find.text('Models').last);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Gemma 4 E2B'), findsOneWidget);

    await tester.tap(find.text('You').last);
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('Privacy'), findsOneWidget);
    await tester.tap(find.text('Chat').last);
    await tester.pump(const Duration(seconds: 2));
  });
}
