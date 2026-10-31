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
import '../../widgets/hand.dart';
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

/// An attachment: photos are small tilted snapshots, files are pills.
class AttachmentChip extends StatelessWidget {
  const AttachmentChip(this.a, {super.key, this.onRemove});
  final Attachment a;
  final VoidCallback? onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final remove = onRemove == null ? null : DoodleButton(Doodle.close, tooltip: 'Remove', size: 16, onTap: onRemove);
    if (a.kind == 'image') {
      return Stack(
        clipBehavior: Clip.none,
        children: [
          Transform.rotate(
            angle: -0.035,
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: p.paper,
                borderRadius: BorderRadius.circular(2),
                boxShadow: [
                  BoxShadow(color: Colors.black.withValues(alpha: 0.18), blurRadius: 2, offset: const Offset(0, 1)),
                ],
              ),
              child: localImage(a.path, width: 64, height: 64),
            ),
          ),
          if (remove != null) Positioned(right: -18, top: -18, child: remove),
        ],
      );
    }
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 2, 4),
      decoration: ShapeDecoration(
        shape: StadiumBorder(side: BorderSide(color: p.rule, width: 1.2)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DoodleIcon(a.kind == 'audio' ? Doodle.wave : Doodle.doc, size: 16, color: p.pencil),
          const SizedBox(width: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 150),
            child: Text(
              a.name,
              style: Hand.small.copyWith(color: p.ink),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (remove != null) SizedBox(height: 32, child: remove) else const SizedBox(width: 10),
        ],
      ),
    );
  }
}

class _UserMessage extends StatelessWidget {
  const _UserMessage(this.m);
  final ChatMessage m;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.only(left: 48, top: 14, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (m.attachments.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: [for (final a in m.attachments) AttachmentChip(a)],
              ),
            ),
          if (m.text.isNotEmpty)
            DecoratedBox(
              decoration: BoxDecoration(color: p.smudge, borderRadius: BorderRadius.circular(18)),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                child: SelectableText(m.text, style: context.text.bodyLarge),
              ),
            ),
        ],
      ),
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
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (m.thinking.isNotEmpty) _Thinking(m.thinking),
          for (final s in m.steps) StepTile(s),
          if (waiting)
            Row(
              children: [
                const HoppingDots(),
                if (m.phase != null) ...[const SizedBox(width: 10), Expanded(child: Meta(m.phase!, maxLines: 2))],
              ],
            ),
          if (m.text.isNotEmpty)
            Padding(
              padding: EdgeInsets.only(top: m.steps.isEmpty ? 0 : 8),
              child: LiteMarkdown(m.text),
            ),
          for (final c in m.cards) ResultCard(c),
          if (m.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      DoodleIcon(Doodle.exclaim, size: 22, color: p.redPen, stroke: 2.6),
                      const SizedBox(width: 6),
                      Expanded(child: Body(m.error!)),
                    ],
                  ),
                  if (m.error!.contains('Models') && v.onOpenModels != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: InkButton('open models', trailing: Doodle.arrow, onTap: v.onOpenModels),
                    ),
                ],
              ),
            ),
          if (!m.streaming) _Footer(v),
        ],
      ),
    );
  }
}

class _Footer extends StatelessWidget {
  const _Footer(this.v);
  final MessageView v;

  @override
  Widget build(BuildContext context) {
    final m = v.message;
    final demo = AppScope.services(context).isDemo;
    final model = m.modelId == null ? null : modelById(m.modelId!);
    final tps = demo ? 0 : m.stats?.effectiveTokensPerSec ?? 0;
    final who = demo ? 'demo engine' : model?.name.toLowerCase();
    return Row(
      children: [
        if (who != null)
          Meta('$who${tps > 0 ? ' · ${tps.toStringAsFixed(1)} tok/s' : ''}', color: context.pal.graphite),
        const Spacer(),
        if (m.text.isNotEmpty)
          DoodleButton(
            Doodle.share,
            tooltip: 'Copy',
            size: 18,
            color: context.pal.pencil,
            onTap: () {
              Clipboard.setData(ClipboardData(text: m.text));
              toast(context, 'copied');
            },
          ),
        if (v.isLast && v.onRetry != null)
          DoodleButton(Doodle.curl, tooltip: 'Try again', size: 18, color: context.pal.pencil, onTap: v.onRetry),
      ],
    );
  }
}

class _Thinking extends StatelessWidget {
  const _Thinking(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Theme(
    data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
    child: ExpansionTile(
      tilePadding: EdgeInsets.zero,
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Text('thinking', style: Hand.small.copyWith(color: context.pal.pencil)),
      leading: DoodleIcon(Doodle.squiggle, size: 18, color: context.pal.pencil),
      childrenPadding: const EdgeInsets.only(left: 8, bottom: 8),
      children: [Meta(text)],
    ),
  );
}

/// One skill call, pencilled into the reply: a drawn tick when done.
class StepTile extends StatelessWidget {
  const StepTile(this.step, {super.key});
  final AgentStep step;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final label = switch (step.status) {
      StepStatus.running => step.progress ?? 'working…',
      StepStatus.done => formatMs(step.ms),
      StepStatus.failed => '${step.result['error'] ?? 'failed'}',
      StepStatus.declined => 'you said no',
    };
    final marker = switch (step.status) {
      StepStatus.running => const Scribbling(size: 16),
      StepStatus.done => const DrawnDoodle(Doodle.tick, size: 18),
      StepStatus.failed => DoodleIcon(Doodle.close, size: 16, color: p.redPen),
      StepStatus.declined => DoodleIcon(Doodle.close, size: 16, color: p.graphite),
    };
    return Pressable(
      onTap: () => _showDetails(context),
      scale: 0.98,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              SizedBox(
                width: 22,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 200),
                  child: KeyedSubtree(key: ValueKey(step.status), child: marker),
                ),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  step.skillName.toLowerCase(),
                  style: Hand.label.copyWith(color: p.ink),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (step.via == 'router') ...[const SizedBox(width: 8), const HandTag('fast path')],
              const SizedBox(width: 8),
              Expanded(child: Meta(label, maxLines: 2, color: step.status == StepStatus.failed ? p.redPen : null)),
            ],
          ),
        ),
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
        builder: (_, controller) => ListView(
          controller: controller,
          padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 32),
          children: [
            PageIntro(
              step.skillName.toLowerCase(),
              '${step.skillId} · via ${step.via} · ${formatMs(step.ms)} · ${step.status.name}',
            ),
            const SectionHead('what went in', padding: EdgeInsets.only(bottom: 6)),
            _Code(enc.convert(step.args)),
            const SectionHead('what came out'),
            _Code(enc.convert(step.result)),
          ],
        ),
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
    decoration: BoxDecoration(color: context.pal.smudge, borderRadius: BorderRadius.circular(radius)),
    child: SelectableText(
      text,
      style: const TextStyle(fontFamily: 'monospace', fontSize: 12).copyWith(color: context.pal.ink),
    ),
  );
}
