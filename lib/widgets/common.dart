import 'package:flutter/material.dart';

import '../theme/rough.dart';
import '../theme/theme.dart';
import 'sketch.dart';

/// The brand mark: a small solid dot.
class Dot extends StatelessWidget {
  const Dot({super.key, this.color, this.size = 7});
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(color: color ?? context.pal.dot, shape: BoxShape.circle),
  );
}

class SectionLabel extends StatelessWidget {
  const SectionLabel(this.label, {super.key, this.trailing, this.padding = const EdgeInsets.fromLTRB(20, 24, 20, 8)});
  final String label;
  final Widget? trailing;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      children: [
        Text(label, style: context.text.titleLarge?.copyWith(fontSize: 25, color: context.pal.muted)),
        const SizedBox(width: 8),
        Expanded(
          child: CustomPaint(
            size: const Size(double.infinity, 8),
            painter: _Squiggle(context.pal.hairline, seedOf(label)),
          ),
        ),
        if (trailing != null) ...[const SizedBox(width: 8), trailing!],
      ],
    ),
  );
}

class _Squiggle extends CustomPainter {
  _Squiggle(this.color, this.seed);
  final Color color;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    Rough.line(Offset(0, size.height / 2), Offset(size.width, size.height / 2), seed: seed, roughness: 1.6),
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.6
      ..strokeCap = StrokeCap.round,
  );

  @override
  bool shouldRepaint(_Squiggle o) => o.color != color;
}

/// Hand-drawn card used for every grouped block. Tappable panels squish.
class Panel extends StatelessWidget {
  const Panel({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.onTap,
    this.color,
    this.seed,
    this.shadow = 0,
  });
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets? margin;
  final VoidCallback? onTap;
  final Color? color;
  final int? seed;
  final double shadow;

  @override
  Widget build(BuildContext context) {
    Widget box = SketchBox(
      seed: seed ?? seedOf(key ?? child.runtimeType),
      fill: color,
      shadow: onTap != null && shadow == 0 ? 3 : shadow,
      padding: padding,
      child: child,
    );
    if (onTap != null) box = Pressable(onTap: onTap, child: box);
    // Panels rise into place as they scroll into view.
    return Enter(
      child: Padding(padding: margin ?? EdgeInsets.zero, child: box),
    );
  }
}

/// Small hand-drawn label, e.g. "Tools", "Beta", "4.2 GB".
class Tag extends StatelessWidget {
  const Tag(this.label, {super.key, this.color, this.filled = false, this.icon});
  final String label;
  final Color? color;
  final bool filled;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final c = color ?? p.muted;
    return SketchBox(
      seed: seedOf(label),
      radius: 12,
      strokeWidth: 1.1,
      stroke: filled ? c : p.faint,
      fill: filled ? c.withValues(alpha: 0.16) : Colors.transparent,
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[Icon(icon, size: 13, color: c), const SizedBox(width: 4)],
          Text(label, style: TextStyle(fontSize: 14, color: filled ? p.ink : c)),
        ],
      ),
    );
  }
}

class EmptyState extends StatelessWidget {
  const EmptyState({super.key, required this.icon, required this.title, this.body, this.action});
  final IconData icon;
  final String title;
  final String? body;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Enter(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Stack(
              alignment: Alignment.center,
              children: [
                DrawnPath(
                  size: const Size(76, 64),
                  color: context.pal.highlight,
                  width: 10,
                  builder: (s) => Rough.scribbleCircle((Offset.zero & s).deflate(8), seed: seedOf(title)),
                ),
                Icon(icon, size: 30, color: context.pal.ink),
              ],
            ),
            const SizedBox(height: 12),
            Text(title, style: context.text.titleLarge?.copyWith(fontSize: 28), textAlign: TextAlign.center),
            if (body != null) ...[
              const SizedBox(height: 6),
              Text(
                body!,
                style: context.text.bodyMedium?.copyWith(color: context.pal.muted),
                textAlign: TextAlign.center,
              ),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      ),
    ),
  );
}

/// Sticky note explaining the web preview's demo engine.
class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: Transform.rotate(
        angle: -0.012,
        child: SketchBox(
          seed: 77,
          fill: p.note(0),
          radius: 6,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.science_outlined, size: 18, color: p.ink),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Preview mode: a demo engine stands in for the on-device models. Install on a phone to run Gemma.',
                  style: context.text.bodySmall?.copyWith(color: p.ink),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

Future<bool> confirmDialog(
  BuildContext context, {
  required String title,
  String? body,
  String confirm = 'Continue',
  bool destructive = false,
}) async {
  final p = context.pal;
  final r = await showGeneralDialog<bool>(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'Dismiss',
    barrierColor: Colors.black38,
    transitionDuration: const Duration(milliseconds: 380),
    transitionBuilder: (_, a, _, child) {
      final t = Curves.easeOutBack.transform(a.value);
      return Opacity(
        opacity: a.value,
        child: Transform.rotate(
          angle: (1 - t) * -0.08,
          child: Transform.scale(scale: 0.85 + 0.15 * t, child: child),
        ),
      );
    },
    pageBuilder: (c, _, _) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body, style: context.text.bodyMedium?.copyWith(color: p.muted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        Pressable(
          onTap: () => Navigator.pop(c, true),
          child: IgnorePointer(
            child: FilledButton(
              style: destructive
                  ? FilledButton.styleFrom(backgroundColor: p.danger, foregroundColor: Colors.white)
                  : null,
              onPressed: () {},
              child: Text(confirm),
            ),
          ),
        ),
      ],
    ),
  );
  return r ?? false;
}

void toast(BuildContext context, String message) => ScaffoldMessenger.of(context)
  ..hideCurrentSnackBar()
  ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
