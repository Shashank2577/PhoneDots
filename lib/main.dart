import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';

import 'app_services.dart';
import 'app_state.dart';
import 'core/app_log.dart';
import 'features/shell/shell.dart';
import 'theme/theme.dart';
import 'widgets/sketch.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.create();
  _logErrors(services.log);
  runApp(PhoneDotsApp(state: AppState(services)));
}

/// Errors Flutter catches also go to Settings → Logs (tests don't call main).
void _logErrors(AppLog log) {
  final previous = FlutterError.onError;
  FlutterError.onError = (details) {
    log.add('error', details.exceptionAsString());
    previous?.call(details);
  };
  final platform = PlatformDispatcher.instance.onError;
  PlatformDispatcher.instance.onError = (error, stack) {
    log.add('error', '$error');
    return platform?.call(error, stack) ?? false;
  };
}

class PhoneDotsApp extends StatelessWidget {
  const PhoneDotsApp({super.key, required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) => AppScope(
    state: state,
    child: ListenableBuilder(
      listenable: state.services.settings,
      builder: (context, _) => MaterialApp(
        title: 'PhoneDots',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(Brightness.light),
        darkTheme: buildTheme(Brightness.dark),
        themeMode: state.services.settings.themeMode,
        // Dotted paper under every route; scaffolds are transparent.
        builder: (context, child) => PaperBackground(child: child!),
        home: const Shell(),
      ),
    ),
  );
}
