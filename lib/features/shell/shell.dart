import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../theme/theme.dart';
import '../../widgets/hand.dart';
import '../chat/chat_screen.dart';
import '../privacy/privacy_screen.dart';
import '../saved/saved_screen.dart';
import '../settings/settings_screen.dart';
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
        final wide = MediaQuery.sizeOf(context).width >= railBreakpoint;
        // While typing, every line goes to what is being typed.
        final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
        final pages = _TabSwitch(
          index: state.tab,
          child: IndexedStack(
            index: state.tab,
            children: const [ChatScreen(), SavedScreen(), YouScreen()],
          ),
        );
        void push(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
        if (wide) {
          return Scaffold(
            body: RailScope(
              rail: true,
              child: Row(
                children: [
                  HandRail(
                    index: state.tab,
                    onTap: state.goTo,
                    labels: AppState.tabs,
                    footer: [
                      DoodleButton(Doodle.gear, tooltip: 'Settings', onTap: () => push(const SettingsScreen())),
                      DoodleButton(Doodle.lock, tooltip: 'Privacy', onTap: () => push(const PrivacyScreen())),
                    ],
                  ),
                  Expanded(child: pages),
                ],
              ),
            ),
          );
        }
        return Scaffold(
          body: pages,
          bottomNavigationBar: typing
              ? null
              : HandNav(index: state.tab, onTap: state.goTo, labels: AppState.tabs),
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
