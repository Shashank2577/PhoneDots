import 'package:flutter/material.dart';

import '../theme/theme.dart';

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
        child: Row(children: [
          Expanded(child: Text(label.toUpperCase(), style: context.text.labelSmall)),
          ?trailing,
        ]),
      );
}

/// Bordered surface used for every grouped block.
class Panel extends StatelessWidget {
  const Panel({super.key, required this.child, this.padding = const EdgeInsets.all(16), this.margin, this.onTap, this.color});
  final Widget child;
  final EdgeInsets padding;
  final EdgeInsets? margin;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: margin ?? EdgeInsets.zero,
      child: Material(
        color: color ?? p.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: p.hairline)),
        clipBehavior: Clip.antiAlias,
        child: InkWell(onTap: onTap, child: Padding(padding: padding, child: child)),
      ),
    );
  }
}

/// Small rounded label, e.g. "Tools", "Beta", "4.2 GB".
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
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: filled ? c.withValues(alpha: 0.12) : Colors.transparent,
        border: Border.all(color: filled ? Colors.transparent : p.hairline),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 12, color: c), const SizedBox(width: 4)],
        Text(label, style: TextStyle(fontSize: 11.5, color: c, fontWeight: FontWeight.w500)),
      ]),
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
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(icon, size: 28, color: context.pal.faint),
            const SizedBox(height: 12),
            Text(title, style: context.text.titleMedium, textAlign: TextAlign.center),
            if (body != null) ...[
              const SizedBox(height: 6),
              Text(body!, style: context.text.bodySmall, textAlign: TextAlign.center),
            ],
            if (action != null) ...[const SizedBox(height: 16), action!],
          ]),
        ),
      );
}

class DemoBanner extends StatelessWidget {
  const DemoBanner({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(color: p.warn.withValues(alpha: 0.1), borderRadius: BorderRadius.circular(10)),
      child: Row(children: [
        Dot(color: p.warn, size: 6),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Preview mode: the demo engine stands in for on-device models. Install on a phone to run Gemma.',
            style: context.text.bodySmall?.copyWith(color: p.ink),
          ),
        ),
      ]),
    );
  }
}

Future<bool> confirmDialog(BuildContext context, {required String title, String? body, String confirm = 'Continue', bool destructive = false}) async {
  final p = context.pal;
  final r = await showDialog<bool>(
    context: context,
    builder: (c) => AlertDialog(
      title: Text(title),
      content: body == null ? null : Text(body, style: context.text.bodyMedium?.copyWith(color: p.muted)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(
          style: destructive ? FilledButton.styleFrom(backgroundColor: p.danger, foregroundColor: Colors.white) : null,
          onPressed: () => Navigator.pop(c, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return r ?? false;
}

void toast(BuildContext context, String message) =>
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));
