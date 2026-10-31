import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app_state.dart';

import '../../core/util/format.dart';
import '../../skills/skill.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/local_image.dart';
import '../../widgets/hand.dart';

/// Renders a skill's [UiCard] in the chat.
class ResultCard extends StatelessWidget {
  const ResultCard(this.card, {super.key});
  final UiCard card;

  @override
  Widget build(BuildContext context) {
    final body = switch (card.type) {
      'kv' => _KeyValues(card.data),
      'table' => _Table(card.data),
      'checklist' => _Checklist(card.data),
      'transcript' => _Transcript(card.data),
      'tags' => _Tags(card.data),
      'bars' => _Bars(card.data),
      'timeline' => _Timeline(card.data),
      'image' => ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: localImage('${card.data['path']}', height: 220, width: double.infinity),
      ),
      'file' => _FileCard(card.data),
      'link' => _LinkCard(card.data),
      _ => _TextBlock(card.data),
    };
    // Results sit on the paper under a hand-lettered head, closed by a hairline.
    return Panel(
      margin: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (card.title != null && card.title!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      card.title!.toLowerCase(),
                      style: Hand.title.copyWith(fontSize: 25, color: context.pal.ink),
                    ),
                  ),
                  if (card.data['demo'] == true) const HandTag('demo data'),
                ],
              ),
            ),
          body,
        ],
      ),
    );
  }
}

class _TextBlock extends StatelessWidget {
  const _TextBlock(this.data);
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final text = '${data['text'] ?? ''}';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SelectableText(text, style: context.text.bodyMedium),
        if (data['copy'] == true)
          Align(
            alignment: Alignment.centerRight,
            child: HandLink(
              'copy',
              onTap: () {
                Clipboard.setData(ClipboardData(text: text));
                toast(context, 'copied');
              },
            ),
          ),
      ],
    );
  }
}

class _KeyValues extends StatelessWidget {
  const _KeyValues(this.data);
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) => Column(
    children: [
      for (final e in data.entries.where((e) => e.key != 'demo'))
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 5),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(width: 110, child: Text(e.key, style: context.text.bodySmall)),
              Expanded(child: SelectableText('${e.value}', style: context.text.bodyMedium)),
            ],
          ),
        ),
    ],
  );
}

class _Table extends StatelessWidget {
  const _Table(this.data);
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final columns = (data['columns'] as List? ?? const []).map((e) => '$e').toList();
    final rows = (data['rows'] as List? ?? const []).map((r) => (r as List).map((e) => '$e').toList()).toList();
    final width = max(columns.length, rows.isEmpty ? 0 : rows.map((r) => r.length).reduce(max));
    if (width == 0) return const SizedBox.shrink();
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Table(
        defaultColumnWidth: const IntrinsicColumnWidth(),
        border: TableBorder(horizontalInside: BorderSide(color: p.hairline)),
        children: [
          if (columns.isNotEmpty)
            TableRow(
              children: [
                for (var i = 0; i < width; i++)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 0, 20, 8),
                    child: Text(i < columns.length ? columns[i] : '', style: context.text.labelMedium),
                  ),
              ],
            ),
          for (final r in rows)
            TableRow(
              children: [
                for (var i = 0; i < width; i++)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(0, 8, 20, 8),
                    child: Text(i < r.length ? r[i] : '', style: context.text.bodyMedium),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}

class _Checklist extends StatefulWidget {
  const _Checklist(this.data);
  final Map<String, dynamic> data;

  @override
  State<_Checklist> createState() => _ChecklistState();
}

class _ChecklistState extends State<_Checklist> {
  late final List<String> items = (widget.data['items'] as List? ?? const []).map((e) => '$e').toList();
  late final List<bool> done = List.filled(items.length, false);

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final readonly = widget.data['readonly'] == true;
    return Column(
      children: [
        for (var i = 0; i < items.length; i++)
          Pressable(
            onTap: readonly ? null : () => setState(() => done[i] = !done[i]),
            scale: 0.97,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: readonly
                        ? Padding(
                            padding: const EdgeInsets.all(6),
                            child: Dot(color: p.ink, size: 6),
                          )
                        : Container(
                            width: 22,
                            height: 22,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: p.ink, width: 1.6),
                            ),
                            child: done[i] ? DrawnDoodle(Doodle.tick, key: ValueKey('c$i'), size: 18) : null,
                          ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Stack(
                      children: [
                        AnimatedDefaultTextStyle(
                          duration: const Duration(milliseconds: 250),
                          style: context.text.bodyMedium!.copyWith(color: done[i] ? p.pencil : p.ink),
                          child: Text(items[i]),
                        ),
                        // A pen line strikes the item through when ticked.
                        if (done[i])
                          Positioned.fill(
                            child: LayoutBuilder(
                              builder: (_, c) => _StrikeThrough(
                                key: ValueKey('s$i'),
                                width: min(c.maxWidth, items[i].length * 8.0),
                                color: p.pencil,
                                seed: i,
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

class _Transcript extends StatelessWidget {
  const _Transcript(this.data);
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final segments = (data['segments'] as List? ?? const []).cast<Map>();
    final speakers = segments.map((s) => s['speaker']).toSet().length;
    final shades = [p.ink, p.muted, p.dot, p.warn];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final s in segments.take(40))
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 44,
                  child: Text(
                    formatDuration(((s['start'] as num?) ?? 0).toDouble()),
                    style: context.text.bodySmall?.copyWith(fontFeatures: const [FontFeature.tabularFigures()]),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (speakers > 1)
                        Row(
                          children: [
                            Dot(color: shades[(s['speaker'] as int) % shades.length], size: 6),
                            const SizedBox(width: 6),
                            Text('Speaker ${(s['speaker'] as int) + 1}', style: context.text.labelMedium),
                          ],
                        ),
                      SelectableText('${s['text']}', style: context.text.bodyMedium),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (segments.length > 40) Text('+ ${segments.length - 40} more segments', style: context.text.bodySmall),
      ],
    );
  }
}

class _Tags extends StatelessWidget {
  const _Tags(this.data);
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final tags = (data['tags'] as List? ?? const []).map((e) => '$e').toList();
    if (data['large'] == true) {
      return Wrap(spacing: 12, children: [for (final t in tags) Text(t, style: const TextStyle(fontSize: 30))]);
    }
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [for (final t in tags) Chip(label: Text(t), visualDensity: VisualDensity.compact)],
    );
  }
}

class _Bars extends StatelessWidget {
  const _Bars(this.data);
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final labels = (data['labels'] as List? ?? const []).map((e) => '$e').toList();
    final values = (data['values'] as List? ?? const []).map((e) => (e as num).toDouble()).toList();
    final n = min(labels.length, values.length);
    if (n == 0) return const SizedBox.shrink();
    final top = values.take(n).map((v) => v.abs()).reduce(max);
    return Column(
      children: [
        for (var i = 0; i < n; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                SizedBox(
                  width: 90,
                  child: Text(labels[i], style: context.text.bodySmall, overflow: TextOverflow.ellipsis),
                ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (_, c) => Align(
                      alignment: Alignment.centerLeft,
                      // Bars grow in and are filled with pen hatching.
                      child: TweenAnimationBuilder<double>(
                        tween: Tween(begin: 0, end: top == 0 ? 0 : values[i].abs() / top),
                        duration: Duration(milliseconds: 500 + 80 * i),
                        curve: Curves.easeOutBack,
                        builder: (_, f, _) => Container(
                          height: 12,
                          width: max(4, c.maxWidth * f),
                          decoration: BoxDecoration(
                            color: i == values.indexOf(values.reduce(max)) ? p.marker : p.ink,
                            borderRadius: BorderRadius.circular(6),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text(
                    _fmt(values[i]),
                    textAlign: TextAlign.right,
                    style: context.text.bodySmall?.copyWith(color: p.ink),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  static String _fmt(double v) => v == v.roundToDouble() ? '${v.toInt()}' : v.toStringAsFixed(1);
}

class _Timeline extends StatelessWidget {
  const _Timeline(this.data);
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final items = (data['items'] as List? ?? const []).cast<Map>();
    if (items.isEmpty) return Text('Nothing scheduled.', style: context.text.bodySmall);
    return Column(
      children: [
        for (var i = 0; i < items.length; i++)
          IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 18,
                  child: Column(
                    children: [
                      const SizedBox(height: 6),
                      Dot(color: p.ink, size: 7),
                      if (i < items.length - 1) Expanded(child: Container(width: 1, color: p.hairline)),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('${items[i]['time']}', style: context.text.labelMedium),
                        if ('${items[i]['text']}'.isNotEmpty)
                          Text('${items[i]['text']}', style: context.text.bodyMedium),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _FileCard extends StatelessWidget {
  const _FileCard(this.data);
  final Map<String, dynamic> data;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final path = data['path'] as String?;
    final preview = data['preview'] as String?;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            DoodleIcon(data['kind'] == 'audio' ? Doodle.wave : Doodle.doc, size: 18, color: p.pencil),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                path?.split('/').last ?? 'Not saved in preview mode',
                style: context.text.bodyMedium,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        if (preview != null) ...[
          const SizedBox(height: 8),
          Container(
            width: double.infinity,
            constraints: const BoxConstraints(maxHeight: 140),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: p.smudge, borderRadius: BorderRadius.circular(radius)),
            child: SingleChildScrollView(
              child: Text(
                preview,
                style: context.text.bodySmall?.copyWith(fontFamily: 'monospace', color: p.ink),
              ),
            ),
          ),
          Align(
            alignment: Alignment.centerRight,
            child: HandLink(
              'copy',
              onTap: () {
                Clipboard.setData(ClipboardData(text: preview));
                toast(context, 'copied');
              },
            ),
          ),
        ],
      ],
    );
  }
}

/// A pencil line that draws itself through a ticked item.
class _StrikeThrough extends StatelessWidget {
  const _StrikeThrough({super.key, required this.width, required this.color, required this.seed});
  final double width;
  final Color color;
  final int seed;

  @override
  Widget build(BuildContext context) => TweenAnimationBuilder<double>(
    tween: Tween(begin: 0, end: 1),
    duration: const Duration(milliseconds: 320),
    curve: Curves.easeOutCubic,
    builder: (_, t, _) => CustomPaint(painter: _StrikePainter(width * t, color, seed)),
  );
}

class _StrikePainter extends CustomPainter {
  _StrikePainter(this.width, this.color, this.seed);
  final double width;
  final Color color;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    if (width <= 0) return;
    final y = size.height * 0.55;
    canvas.drawPath(
      handLinePath(Offset(0, y), Offset(width, y - 1), seed),
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round,
    );
  }

  @override
  bool shouldRepaint(_StrikePainter o) => o.width != width;
}

/// A shared link as PhoneDots read it: platform, title, author, description.
class _LinkCard extends StatelessWidget {
  const _LinkCard(this.data);
  final Map<String, dynamic> data;

  static Doodle _doodle(String platform) => switch (platform) {
    'youtube' || 'tiktok' => Doodle.play,
    'instagram' => Doodle.camera,
    'github' => Doodle.curl,
    'medium' => Doodle.book,
    'linkedin' => Doodle.person,
    'threads' || 'x' => Doodle.bubble,
    _ => Doodle.share,
  };

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final rich = data['rich'] == true;
    final desc = '${data['description'] ?? ''}'.trim();
    final services = AppScope.services(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            DoodleIcon(_doodle('${data['platform']}'), size: 18, color: p.pencil),
            const SizedBox(width: 8),
            Expanded(
              child: Meta(
                '${data['platform']} · ${data['kind']}${data['author'] != null ? ' · ${data['author']}' : ''}',
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '${data['title']}',
          style: Hand.label.copyWith(fontSize: 23, color: p.ink),
          maxLines: 3,
          overflow: TextOverflow.ellipsis,
        ),
        if (desc.isNotEmpty) Meta(desc, maxLines: 4),
        if (!rich)
          const Meta(
            'The site shared no details, so this name comes from the link. A screenshot lets PhoneDots read it.',
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: HandLink('open', onTap: () => services.device.invoke('url.open', {'url': '${data['url']}'})),
        ),
      ],
    );
  }
}
