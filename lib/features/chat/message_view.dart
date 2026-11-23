import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../agent/conversation.dart';
import '../../app_state.dart';
import '../../core/models/model_catalog.dart';
import '../../core/util/format.dart';
import '../../skills/skill.dart';
import '../../theme/theme.dart';
import '../../voice/speech_text.dart';
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
              style: context.type.chip,
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
                child: SelectableText(m.text, style: context.type.body),
              ),
            ),
        ],
      ),
    );
  }
}

/// The answer comes first, with no bubble. What it did on the way (thinking,
/// skills, timings) folds into one caption line under the answer; while it
/// works, that line is live above the growing answer.
class _AssistantMessage extends StatelessWidget {
  const _AssistantMessage(this.v);
  final MessageView v;

  @override
  Widget build(BuildContext context) {
    final m = v.message;
    final running = m.steps.where((s) => s.status == StepStatus.running).toList();
    final live = m.streaming
        ? (running.isNotEmpty
              ? '${running.last.skillName}: ${running.last.progress ?? 'working…'}'
              : m.text.isEmpty
              ? (m.phase ?? (m.thinking.isNotEmpty ? 'Thinking…' : null))
              : null)
        : null;
    final waiting = m.streaming && m.text.isEmpty;
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (waiting || live != null)
            Semantics(
              liveRegion: true,
              child: Pressable(
                onTap: m.steps.isEmpty && m.thinking.isEmpty ? null : () => showTrace(context, m),
                child: ConstrainedBox(
                  constraints: const BoxConstraints(minHeight: 40),
                  child: Row(
                    children: [
                      if (running.isNotEmpty) const Scribbling(size: 16) else const HoppingDots(),
                      if (live != null) ...[
                        const SizedBox(width: 10),
                        Expanded(child: Caption(live, maxLines: 2)),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          if (m.text.isNotEmpty) Prose(stripMoodTags(m.text)),
          for (final c in m.cards) ResultCard(c),
          if (m.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Warning(m.error!),
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

/// Under an answer: "2 steps · 1.7 s" (opens the trace), the model and its
/// speed, and copy, try again and share, each 48 to touch.
class _Footer extends StatelessWidget {
  const _Footer(this.v);
  final MessageView v;

  @override
  Widget build(BuildContext context) {
    final m = v.message;
    final p = context.pal;
    final s = AppScope.services(context);
    final demo = s.isDemo;
    final model = m.modelId == null ? null : modelById(m.modelId!);
    final tps = demo ? 0 : m.stats?.effectiveTokensPerSec ?? 0;
    final who = demo ? 'Demo engine' : model?.name;
    final failed = m.steps.where((x) => x.status == StepStatus.failed || x.status == StepStatus.declined).length;
    final ms = m.steps.fold<int>(0, (a, x) => a + x.ms) + (m.stats?.totalMs ?? 0);
    final trace = m.steps.isEmpty && m.thinking.isEmpty
        ? null
        : [
            if (m.steps.isNotEmpty) '${m.steps.length} ${m.steps.length == 1 ? 'step' : 'steps'}',
            if (m.steps.isEmpty) 'thought first',
            if (failed > 0) '$failed not done',
            if (ms > 0) formatMs(ms),
          ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (trace != null)
                  Semantics(
                    button: true,
                    label: '$trace. Show what it did',
                    excludeSemantics: true,
                    child: Pressable(
                      onTap: () => showTrace(context, m),
                      child: ConstrainedBox(
                        constraints: const BoxConstraints(minHeight: minTap),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DoodleIcon(
                              failed > 0 ? Doodle.exclaim : Doodle.tick,
                              size: 16,
                              color: failed > 0 ? p.redPen : p.pencil,
                            ),
                            const SizedBox(width: 6),
                            Flexible(
                              child: HandUnderline(
                                color: p.pencil,
                                seed: trace.length,
                                child: Caption(trace, maxLines: 1),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                if (who != null) Caption('$who${tps > 0 ? ' · ${tps.toStringAsFixed(1)} tok/s' : ''}', maxLines: 1),
              ],
            ),
          ),
          if (m.text.isNotEmpty)
            DoodleButton(
              Doodle.copy,
              tooltip: 'Copy',
              size: 20,
              color: p.pencil,
              onTap: () {
                Clipboard.setData(ClipboardData(text: m.text));
                toast(context, 'copied');
              },
            ),
          if (v.isLast && v.onRetry != null)
            DoodleButton(Doodle.curl, tooltip: 'Try again', size: 20, color: p.pencil, onTap: v.onRetry),
          if (m.text.isNotEmpty)
            DoodleButton(
              Doodle.share,
              tooltip: 'Share',
              size: 20,
              color: p.pencil,
              onTap: () => s.device.invoke('share.text', {'text': m.text}),
            ),
        ],
      ),
    );
  }
}

/// What the assistant did for one answer: its thinking and each skill call.
void showTrace(BuildContext context, ChatMessage m) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (c) => DraggableScrollableSheet(
    expand: false,
    initialChildSize: 0.6,
    builder: (_, controller) => ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 32),
      children: [
        const PageIntro('what it did', 'Every step ran on this phone. Tap a step to see what went in and out.'),
        if (m.thinking.isNotEmpty) ...[
          const SectionHead('thinking', first: true),
          Prose(m.thinking, style: c.type.body),
        ],
        if (m.steps.isNotEmpty) ...[
          SectionHead('steps', first: m.thinking.isEmpty),
          for (final s in m.steps) StepTile(s),
        ],
      ],
    ),
  ),
);

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
      StepStatus.declined => DoodleIcon(Doodle.close, size: 16, color: p.pencil),
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
                  step.skillName,
                  style: context.type.rowTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (step.via == 'router') ...[const SizedBox(width: 8), const HandTag('fast path')],
              const SizedBox(width: 8),
              Expanded(child: Caption(label, maxLines: 2, align: TextAlign.end)),
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
            Text(step.skillName, style: context.type.contentTitle),
            Caption('${step.skillId} · via ${step.via} · ${formatMs(step.ms)} · ${step.status.name}'),
            const SectionHead('what went in', first: true),
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
    child: SelectableText(text, style: context.type.mono),
  );
}
