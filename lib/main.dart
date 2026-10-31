import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';

import 'app_services.dart';
import 'app_state.dart';
import 'core/app_log.dart';
import 'features/shell/shell.dart';
import 'theme/theme.dart';

Future<void> main() async {
  // Every error, anywhere, lands in the diagnostics log instead of vanishing.
  await runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (d) {
      FlutterError.presentError(d);
      appLog.error(
        'flutter',
        d.exceptionAsString().split('\n').first,
        {if (d.library != null) 'library': d.library},
        d.exception,
        d.stack,
      );
    };
    PlatformDispatcher.instance.onError = (e, s) {
      appLog.error('app', 'uncaught error', null, e, s);
      return true;
    };
    final services = await AppServices.create();
    runApp(PhoneDotsApp(state: AppState(services)));
  }, (e, s) => appLog.error('app', 'uncaught async error', null, e, s));
}

class PhoneDotsApp extends StatelessWidget {
  const PhoneDotsApp({super.key, required this.state});
  final AppState state;

  Voice get _voice => Voice.values.firstWhere((v) => v.name == state.services.settings.voice, orElse: () => Voice.neat);

  @override
  Widget build(BuildContext context) => AppScope(
    state: state,
    child: ListenableBuilder(
      listenable: state.services.settings,
      builder: (context, _) => MaterialApp(
        title: 'PhoneDots',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light, voice: _voice),
        darkTheme: buildTheme(Brightness.dark, voice: _voice),
        themeMode: state.services.settings.themeMode,
        home: const Shell(),
      ),
    ),
  );
}
