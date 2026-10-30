import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../widgets/sketch.dart';
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
          // Tabs keep their state; switching slides the new page up a little.
          body: _TabSwitch(
            index: state.tab,
            child: IndexedStack(
              index: state.tab,
              children: const [ChatScreen(), SkillsScreen(), ModelsScreen(), YouScreen()],
            ),
          ),
          bottomNavigationBar: SketchNavBar(
            index: state.tab,
            onTap: state.goTo,
            items: const [
              (Icons.chat_bubble_outline_rounded, Icons.chat_bubble_rounded, 'Chat'),
              (Icons.auto_awesome_outlined, Icons.auto_awesome, 'Skills'),
              (Icons.memory_outlined, Icons.memory_rounded, 'Models'),
              (Icons.sentiment_satisfied_outlined, Icons.sentiment_satisfied_rounded, 'You'),
            ],
          ),
        );
      },
    );
  }
}

/// Replays a short rise-and-fade whenever [index] changes, without
/// rebuilding the tabs (so scroll positions and drafts survive).
class _TabSwitch extends StatefulWidget {
  const _TabSwitch({required this.index, required this.child});
  final int index;
  final Widget child;

  @override
  State<_TabSwitch> createState() => _TabSwitchState();
}

class _TabSwitchState extends State<_TabSwitch> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 320), value: 1);

  @override
  void didUpdateWidget(_TabSwitch old) {
    super.didUpdateWidget(old);
    if (old.index != widget.index) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: widget.child,
    builder: (_, child) {
      final t = Curves.easeOutCubic.transform(_c.value);
      return Opacity(
        opacity: t,
        child: Transform.translate(offset: Offset(0, 14 * (1 - t)), child: child),
      );
    },
  );
}
