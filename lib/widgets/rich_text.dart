import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Minimal markdown: paragraphs, #/## headings, - and 1. lists, **bold**,
/// `code` and fenced code blocks. Enough for chat without a dependency.
class LiteMarkdown extends StatelessWidget {
  const LiteMarkdown(this.source, {super.key, this.style});
  final String source;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? context.text.bodyLarge!;
    final p = context.pal;
    final blocks = <Widget>[];
    final lines = source.split('\n');
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('```')) {
        final code = <String>[];
        i++;
        while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
          code.add(lines[i++]);
        }
        blocks.add(Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 6),
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: p.surfaceAlt, borderRadius: BorderRadius.circular(10)),
          child: SelectableText(code.join('\n'), style: base.copyWith(fontFamily: 'monospace', fontSize: 13, height: 1.4)),
        ));
        continue;
      }
      if (line.trim().isEmpty) {
        blocks.add(const SizedBox(height: 8));
        continue;
      }
      final heading = RegExp(r'^(#{1,3})\s+(.*)').firstMatch(line);
      if (heading != null) {
        blocks.add(Padding(
          padding: const EdgeInsets.only(top: 6, bottom: 2),
          child: Text.rich(_inline(heading.group(2)!, base.copyWith(fontWeight: FontWeight.w600, fontSize: base.fontSize! + (4 - heading.group(1)!.length)), p)),
        ));
        continue;
      }
      final bullet = RegExp(r'^\s*([-*•]|\d+[.)])\s+(.*)').firstMatch(line);
      if (bullet != null) {
        final marker = bullet.group(1)!;
        blocks.add(Padding(
          padding: const EdgeInsets.only(left: 2, top: 2, bottom: 2),
          child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            SizedBox(
              width: 20,
              child: Text(RegExp(r'\d').hasMatch(marker) ? marker : '•', style: base.copyWith(color: p.muted)),
            ),
            Expanded(child: Text.rich(_inline(bullet.group(2)!, base, p))),
          ]),
        ));
        continue;
      }
      blocks.add(Text.rich(_inline(line, base, p)));
    }
    return SelectionArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: blocks));
  }

  static TextSpan _inline(String text, TextStyle base, Palette p) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      if (m.group(1) != null) {
        spans.add(TextSpan(text: m.group(1), style: const TextStyle(fontWeight: FontWeight.w600)));
      } else {
        spans.add(TextSpan(
          text: m.group(2),
          style: TextStyle(fontFamily: 'monospace', fontSize: base.fontSize! - 1.5, backgroundColor: p.surfaceAlt),
        ));
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return TextSpan(style: base, children: spans);
  }
}
