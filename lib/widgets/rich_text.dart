import 'package:flutter/material.dart';

import '../theme/theme.dart';

/// Long-form text (answers, summaries, articles): `reading` 17/26 in ink, at
/// most [readingColumn] wide, 12 between paragraphs, selectable.
///
/// Renders a small markdown subset without a dependency: paragraphs, `#`
/// headings (as `rowTitle`, never hand-lettering, so an answer has one level
/// of heading), `-` and `1.` lists, `>` quotes, `**bold**`, `` `code` `` and
/// fenced code blocks (mono).
class Prose extends StatelessWidget {
  const Prose(this.source, {super.key, this.style});
  final String source;

  /// Defaults to `reading`; pass `body` for shorter text.
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final t = context.type;
    final base = style ?? t.reading;
    final p = context.pal;
    final blocks = <Widget>[];
    // Space before the next block: 12 between paragraphs, 4 inside a list.
    var gap = 0.0;
    void add(Widget w, {double before = 12}) {
      blocks.add(Padding(padding: EdgeInsets.only(top: blocks.isEmpty ? 0 : (gap > 0 ? gap : before)), child: w));
      gap = 0;
    }

    final lines = source.split('\n');
    String? lastKind;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      if (line.trimLeft().startsWith('```')) {
        final code = <String>[];
        i++;
        while (i < lines.length && !lines[i].trimLeft().startsWith('```')) {
          code.add(lines[i++]);
        }
        add(
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(color: p.smudge, borderRadius: BorderRadius.circular(10)),
            child: Text(code.join('\n'), style: t.mono),
          ),
        );
        lastKind = 'code';
        continue;
      }
      if (line.trim().isEmpty) {
        lastKind = null;
        continue;
      }
      final heading = RegExp(r'^(#{1,6})\s+(.*)').firstMatch(line);
      if (heading != null) {
        add(Text.rich(_inline(heading.group(2)!, t.rowTitle, t, p)), before: 16);
        gap = 4;
        lastKind = 'heading';
        continue;
      }
      final quote = RegExp(r'^\s*>\s?(.*)').firstMatch(line);
      if (quote != null) {
        add(
          Container(
            padding: const EdgeInsets.only(left: 12),
            decoration: BoxDecoration(
              border: Border(left: BorderSide(color: p.rule, width: 3)),
            ),
            child: Text.rich(_inline(quote.group(1)!, base.copyWith(color: p.pencil), t, p)),
          ),
          before: lastKind == 'quote' ? 4 : 12,
        );
        lastKind = 'quote';
        continue;
      }
      final bullet = RegExp(r'^\s*([-*•]|\d+[.)])\s+(.*)').firstMatch(line);
      if (bullet != null) {
        final marker = bullet.group(1)!;
        add(
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 24,
                child: Text(RegExp(r'\d').hasMatch(marker) ? marker : '•', style: base.copyWith(color: p.pencil)),
              ),
              Expanded(child: Text.rich(_inline(bullet.group(2)!, base, t, p))),
            ],
          ),
          before: lastKind == 'list' ? 4 : 12,
        );
        lastKind = 'list';
        continue;
      }
      // A line straight after another plain line stays in the same paragraph.
      add(Text.rich(_inline(line, base, t, p)), before: lastKind == 'para' ? 0 : 12);
      lastKind = 'para';
    }
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: readingColumn),
      child: SelectionArea(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: blocks),
      ),
    );
  }

  static TextSpan _inline(String text, TextStyle base, TypeRoles t, Palette p) {
    final spans = <InlineSpan>[];
    final re = RegExp(r'\*\*(.+?)\*\*|`([^`]+)`');
    var last = 0;
    for (final m in re.allMatches(text)) {
      if (m.start > last) spans.add(TextSpan(text: text.substring(last, m.start)));
      if (m.group(1) != null) {
        spans.add(
          TextSpan(
            text: m.group(1),
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        );
      } else {
        spans.add(
          TextSpan(
            text: m.group(2),
            style: t.mono.copyWith(height: base.height, backgroundColor: p.smudge),
          ),
        );
      }
      last = m.end;
    }
    if (last < text.length) spans.add(TextSpan(text: text.substring(last)));
    return TextSpan(style: base, children: spans);
  }
}
