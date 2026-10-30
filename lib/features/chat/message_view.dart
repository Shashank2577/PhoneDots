import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../agent/conversation.dart';
import '../../app_state.dart';
import '../../core/models/model_catalog.dart';
import '../../core/util/format.dart';
import '../../skills/skill.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/local_image.dart';
import '../../widgets/rich_text.dart';
import 'cards.dart';

class MessageView extends StatelessWidget {
  const MessageView({super.key, required this.message, this.onRetry, this.onOpenModels, this.isLast = false});

  final ChatMessage message;
  final VoidCallback? onRetry;
  final VoidCallback? onOpenModels;
  final bool isLast;

  @override
  Widget build(BuildContext context) => message.isUser ? _UserMessage(message) : _AssistantMessage(this);
}

class AttachmentChip extends StatelessWidget {
  const AttachmentChip(this.a, {super.key, this.onRemove});
  final Attachment a;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    if (a.kind == 'image') {
      return Stack(children: [
        ClipRRect(borderRadius: BorderRadius.circular(10), child: localImage(a.path, width: 64, height: 64)),
        if (onRemove != null) Positioned(right: 2, top: 2, child: _RemoveButton(onRemove!)),
      ]);
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
      decoration: BoxDecoration(color: p.surface, border: Border.all(color: p.hairline), borderRadius: BorderRadius.circular(10)),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        Icon(a.kind == 'audio' ? Icons.graphic_eq_rounded : Icons.description_outlined, size: 16, color: p.muted),
        const SizedBox(width: 6),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 150),
          child: Text(a.name, style: context.text.bodySmall?.copyWith(color: p.ink), overflow: TextOverflow.ellipsis),
        ),
        const SizedBox(width: 4),
        if (onRemove != null) _RemoveButton(onRemove!) else const SizedBox(width: 4),
      ]),
    );
  }
}

class _RemoveButton extends StatelessWidget {
  const _RemoveButton(this.onTap);
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        customBorder: const CircleBorder(),
        child: Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(color: context.pal.ink.withValues(alpha: 0.7), shape: BoxShape.circle),
          child: Icon(Icons.close_rounded, size: 12, color: context.pal.bg),
        ),
      );
}

class _UserMessage extends StatelessWidget {
  const _UserMessage(this.m);
  final ChatMessage m;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.fromLTRB(56, 12, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (m.attachments.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Wrap(spacing: 6, runSpacing: 6, alignment: WrapAlignment.end, children: [for (final a in m.attachments) AttachmentChip(a)]),
          ),
        if (m.text.isNotEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(color: p.surfaceAlt, borderRadius: BorderRadius.circular(18)),
            child: SelectableText(m.text, style: context.text.bodyLarge),
          ),
      ]),
    );
  }
}

class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage(this.v);
  final MessageView v;

  @override
  Widget build(BuildContext context) {
    final m = v.message;
    final p = context.pal;
    final waiting = m.streaming && m.text.isEmpty && m.steps.isEmpty && m.thinking.isEmpty;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (m.thinking.isNotEmpty) _Thinking(m.thinking),
        for (final s in m.steps) StepTile(s),
        if (waiting) const _Typing(),
        if (m.text.isNotEmpty)
          Padding(padding: EdgeInsets.only(top: m.steps.isEmpty ? 0 : 8), child: LiteMarkdown(m.text)),
        for (final c in m.cards) ResultCard(c),
        if (m.error != null)
          Panel(
            margin: const EdgeInsets.only(top: 8),
            color: p.danger.withValues(alpha: 0.06),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.error!, style: context.text.bodyMedium),
              if (m.error!.contains('Models') && v.onOpenModels != null) ...[
                const SizedBox(height: 10),
                FilledButton(onPressed: v.onOpenModels, child: const Text('Open Models')),
              ],
            ]),
          ),
        if (!m.streaming) _Footer(v),
      ]),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer(this.v);
  final MessageView v;

  @override
  Widget build(BuildContext context) {
    final m = v.message;
    final p = context.pal;
    final demo = AppScope.services(context).isDemo;
    final model = m.modelId == null ? null : modelById(m.modelId!);
    final tps = demo ? 0 : m.stats?.effectiveTokensPerSec ?? 0;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(children: [
        if (demo)
          Text('Demo engine', style: context.text.bodySmall?.copyWith(color: p.faint))
        else if (model != null) ...[
          Text(model.name, style: context.text.bodySmall?.copyWith(color: p.faint)),
          if (tps > 0) Text(' · ${tps.toStringAsFixed(1)} tok/s', style: context.text.bodySmall?.copyWith(color: p.faint)),
        ],
        const Spacer(),
        if (m.text.isNotEmpty)
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            color: p.muted,
            tooltip: 'Copy',
            onPressed: () {
              Clipboard.setData(ClipboardData(text: m.text));
              toast(context, 'Copied');
            },
            icon: const Icon(Icons.copy_rounded),
          ),
        if (v.isLast && v.onRetry != null)
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            color: p.muted,
            tooltip: 'Retry',
            onPressed: v.onRetry,
            icon: const Icon(Icons.refresh_rounded),
          ),
      ]),
    );
  }
}

class _Typing extends StatefulWidget {
  const _Typing();

  @override
  State<_Typing> createState() => _TypingState();
}

class _TypingState extends State<_Typing> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Row(children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.only(right: 5, top: 8, bottom: 8),
              child: Opacity(
                opacity: 0.25 + 0.75 * (((_c.value * 3 - i) % 3) < 1 ? 1 - ((_c.value * 3 - i) % 1) : 0),
                child: Dot(color: context.pal.ink, size: 6),
              ),
            ),
        ]),
      );
}

class _Thinking extends StatelessWidget {
  const _Thinking(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        dense: true,
        visualDensity: VisualDensity.compact,
        title: Text('Thinking', style: context.text.labelMedium),
        leading: Icon(Icons.blur_on_rounded, size: 16, color: p.muted),
        childrenPadding: const EdgeInsets.only(left: 8, bottom: 8),
        children: [
          Container(
            decoration: BoxDecoration(border: Border(left: BorderSide(color: p.hairline, width: 2))),
            padding: const EdgeInsets.only(left: 10),
            child: Text(text, style: context.text.bodySmall),
          ),
        ],
      ),
    );
  }
}

/// One skill call: status dot, name, timing; tap to see inputs and output.
class StepTile extends StatelessWidget {
  const StepTile(this.step, {super.key});
  final AgentStep step;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final color = switch (step.status) {
      StepStatus.running => p.warn,
      StepStatus.done => p.dot,
      StepStatus.failed => p.danger,
      StepStatus.declined => p.faint,
    };
    final label = switch (step.status) {
      StepStatus.running => step.progress ?? 'Running',
      StepStatus.done => formatMs(step.ms),
      StepStatus.failed => '${step.result['error'] ?? 'Failed'}',
      StepStatus.declined => 'Declined',
    };
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => _showDetails(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.only(top: 6), child: Dot(color: color, size: 6)),
          const SizedBox(width: 10),
          Text(step.skillName, style: context.text.bodyMedium?.copyWith(fontWeight: FontWeight.w600)),
          if (step.via == 'router') ...[const SizedBox(width: 6), const Tag('fast path')],
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: context.text.bodySmall, maxLines: 2, overflow: TextOverflow.ellipsis),
          ),
          if (step.status == StepStatus.running)
            const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5)),
        ]),
      ),
    );
  }

  void _showDetails(BuildContext context) {
    const enc = JsonEncoder.withIndent('  ');
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.6,
        builder: (_, controller) => ListView(controller: controller, padding: const EdgeInsets.fromLTRB(20, 0, 20, 32), children: [
          Text(step.skillName, style: context.text.titleLarge),
          const SizedBox(height: 4),
          Text('${step.skillId} · via ${step.via} · ${formatMs(step.ms)} · ${step.status.name}', style: context.text.bodySmall),
          const SectionLabel('Input', padding: EdgeInsets.only(top: 20, bottom: 8)),
          _Code(enc.convert(step.args)),
          const SectionLabel('Output', padding: EdgeInsets.only(top: 20, bottom: 8)),
          _Code(enc.convert(step.result)),
        ]),
      ),
    );
  }
}

class _Code extends StatelessWidget {
  const _Code(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(color: context.pal.surfaceAlt, borderRadius: BorderRadius.circular(10)),
        child: SelectableText(text, style: context.text.bodySmall?.copyWith(fontFamily: 'monospace', color: context.pal.ink)),
      );
}
