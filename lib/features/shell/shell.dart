import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../chat/chat_screen.dart';
import '../models/models_screen.dart';
import '../settings/settings_screen.dart';
import '../skills/skills_screen.dart';
import 'onboarding.dart';

class Shell extends StatelessWidget {
  const Shell({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return ListenableBuilder(
      listenable: state.services.settings,
      builder: (context, _) {
        if (!state.services.settings.onboarded) return const Onboarding();
        return Scaffold(
          body: IndexedStack(index: state.tab, children: const [
            ChatScreen(),
            SkillsScreen(),
            ModelsScreen(),
            YouScreen(),
          ]),
          bottomNavigationBar: DecoratedBox(
            decoration: BoxDecoration(border: Border(top: BorderSide(color: Theme.of(context).dividerTheme.color!))),
            child: NavigationBar(
              selectedIndex: state.tab,
              onDestinationSelected: state.goTo,
              destinations: const [
                NavigationDestination(icon: Icon(Icons.chat_bubble_outline_rounded), selectedIcon: Icon(Icons.chat_bubble_rounded), label: 'Chat'),
                NavigationDestination(icon: Icon(Icons.widgets_outlined), selectedIcon: Icon(Icons.widgets_rounded), label: 'Skills'),
                NavigationDestination(icon: Icon(Icons.memory_outlined), selectedIcon: Icon(Icons.memory_rounded), label: 'Models'),
                NavigationDestination(icon: Icon(Icons.person_outline_rounded), selectedIcon: Icon(Icons.person_rounded), label: 'You'),
              ],
            ),
          ),
        );
      },
    );
  }
}
