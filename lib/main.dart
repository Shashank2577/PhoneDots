import 'package:flutter/material.dart';

import 'app_services.dart';
import 'app_state.dart';
import 'features/shell/shell.dart';
import 'theme/theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final services = await AppServices.create();
  runApp(PhoneDotsApp(state: AppState(services)));
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
            home: const Shell(),
          ),
        ),
      );
}
