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
    this.padding = const EdgeInsets.fromLTRB(gutter, 40, gutter, 12),
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
          child: Text(label, style: Hand.title.copyWith(color: context.pal.ink), textScaler: Hand.scaler(context)),
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

/// Said once in the web preview, where a demo engine replaces the models;
/// after that the model line under the chat says "Demo engine".
class DemoNote extends StatelessWidget {
  const DemoNote({super.key, required this.onDone});
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) => DoneNote(
    'This preview runs a demo engine. Install PhoneDots on a phone to run Gemma.',
    doodle: Doodle.flask,
    action: 'got it',
    onAction: onDone,
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
            Text(title, style: Hand.title.copyWith(color: context.pal.ink), textScaler: Hand.scaler(context)),
            if (body != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Body(body),
              ),
            const SizedBox(height: 20),
            InkButton(confirm, onTap: () => Navigator.pop(c, true), danger: destructive, expand: true),
            const SizedBox(height: 4),
            Center(
              child: HandLink('not now', onTap: () => Navigator.pop(c, false)),
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

/// A sheet that asks for a line or two of text (a fact to remember, a note):
/// a title, the fields and one ink pill. Returns the texts, or null.
Future<List<String>?> askSheet(
  BuildContext context, {
  required String title,
  required List<({String hint, int lines})> fields,
  String confirm = 'save',
}) => showModalBottomSheet<List<String>>(
  context: context,
  isScrollControlled: true,
  builder: (_) => _AskSheet(title: title, fields: fields, confirm: confirm),
);

class _AskSheet extends StatefulWidget {
  const _AskSheet({required this.title, required this.fields, required this.confirm});
  final String title;
  final List<({String hint, int lines})> fields;
  final String confirm;

  @override
  State<_AskSheet> createState() => _AskSheetState();
}

class _AskSheetState extends State<_AskSheet> {
  late final _c = [for (final _ in widget.fields) TextEditingController()];

  @override
  void dispose() {
    for (final c in _c) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SafeArea(
    child: SingleChildScrollView(
      padding: EdgeInsets.fromLTRB(gutter, 0, gutter, 20 + MediaQuery.viewInsetsOf(context).bottom),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(widget.title, style: Hand.title.copyWith(color: context.pal.ink), textScaler: Hand.scaler(context)),
          const SizedBox(height: 12),
          for (final (i, f) in widget.fields.indexed)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: TextField(
                controller: _c[i],
                autofocus: i == 0,
                minLines: f.lines,
                maxLines: f.lines == 1 ? 1 : f.lines + 4,
                textCapitalization: TextCapitalization.sentences,
                decoration: InputDecoration(hintText: f.hint),
              ),
            ),
          const SizedBox(height: 6),
          InkButton(
            widget.confirm,
            expand: true,
            onTap: () => Navigator.pop(context, [for (final c in _c) c.text]),
          ),
        ],
      ),
    ),
  );
}
