import 'package:flutter/material.dart';

import '../theme/theme.dart';
import 'hand.dart';

/// A small solid dot (model loaded, speaker colour).
class Dot extends StatelessWidget {
  const Dot({super.key, this.color, this.size = 7});
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color ?? context.pal.ink, shape: BoxShape.circle),
  );
}

/// Section head inside a page (Caveat, with an optional right-hand note).
class SectionLabel extends StatelessWidget {
  const SectionLabel(
    this.label, {
    super.key,
    this.trailing,
    this.padding = const EdgeInsets.fromLTRB(gutter, 22, gutter, 6),
  });
  final String label;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Expanded(
          child: Text(label, style: Hand.title.copyWith(fontSize: 27, color: context.pal.ink)),
        ),
        ?trailing,
      ],
    ),
  );
}

/// A block of content sitting straight on the paper: no card, separated
/// from the next block by a sketchy hairline. Tappable blocks squish.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(vertical: 4),
    this.margin,
    this.onTap,
    this.color,
    this.divider = true,
  });
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets? margin;
  final VoidCallback? onTap;

  /// A smudge well instead of bare paper (inputs, the mask box).
  final Color? color;
  final bool divider;

  @override
  Widget build(BuildContext context) {
    Widget content = Padding(padding: padding, child: child);
    if (color != null) {
      content = DecoratedBox(
        decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(radius)),
        child: Padding(padding: const EdgeInsets.all(14), child: content),
      );
    }
    if (onTap != null) content = Pressable(onTap: onTap, child: content);
    return Enter(
      child: Padding(
        padding: margin ?? EdgeInsets.zero,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            content,
            if (divider && color == null) HandDivider(seed: seedOf(key ?? child.runtimeType)),
          ],
        ),
      ),
    );
  }
}

/// Small pill label ("tools", "beta", "2.6 GB"). [filled] marks it.
class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.color, this.filled = false, this.icon});
  final String label;
  final Color? color;
  final bool filled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => HandTag(label, marked: filled, color: color);
}

class EmptyState extends StatelessWidget {
  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.action,
    this.doodle = Doodle.spark,
  });
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;
  final Doodle doodle;

  @override
  Widget build(BuildContext context) => Center(
    child: HandEmpty(title: title, body: body, doodle: doodle, action: action),
  );
}

/// Note shown in the web preview, where a demo engine replaces the models.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key});

  @override
  Widget build(BuildContext context) => Column0(
    child: Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          DoodleIcon(Doodle.flask, size: 18, color: context.pal.pencil, stroke: 1.6),
          const SizedBox(width: 8),
          const Expanded(
            child: Meta('preview: a demo engine stands in for the models. Install on a phone to run Gemma.'),
          ),
        ],
      ),
    ),
  );
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? body,
  String confirm = 'continue',
  bool destructive = false,
}) async {
  final r = await showModalBottomSheet<bool>(
    context: context,
    // Long reviews (an install, a permission) scroll instead of pushing the button off screen.
    isScrollControlled: true,
    constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
    builder: (c) => SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Hand.title.copyWith(color: context.pal.ink)),
            if (body != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Body(body, color: context.pal.pencil),
              ),
            const SizedBox(height: 20),
            InkButton(confirm, onTap: () => Navigator.pop(c, true), danger: destructive, expand: true),
            const SizedBox(height: 4),
            Center(
              child: HandLink('not now', onTap: () => Navigator.pop(c, false), color: context.pal.pencil),
            ),
          ],
        ),
      ),
    ),
  );
  return r ?? false;
}

void toast(BuildContext context, String message) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
