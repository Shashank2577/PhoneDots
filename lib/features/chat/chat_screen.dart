import 'package:flutter/material.dart';

import '../../agent/agent.dart';
import '../../app_services.dart';
import '../../app_state.dart';
import '../../core/models/model_catalog.dart';
import '../../core/models/model_manager.dart';
import '../../core/models/model_spec.dart';
import '../../core/util/format.dart';
import '../../skills/skill.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../voice/voice_screen.dart';
import 'attach.dart';
import 'message_view.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final List<Attachment> _pending = [];
  ChatController? _bound;
  AppServices? _services;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final state = AppScope.of(context);
    if (_services == null) {
      _services = state.services;
      _services!.intake.addListener(_onIntake);
      WidgetsBinding.instance.addPostFrameCallback((_) => _onIntake());
    }
    if (_bound != state.chat) {
      _bound?.removeListener(_onChat);
      _bound = state.chat..addListener(_onChat);
      _bound!.onConfirm = _confirm;
    }
  }

  @override
  void dispose() {
    _bound?.removeListener(_onChat);
    _services?.intake.removeListener(_onIntake);
    _input.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _onIntake() {
    final shared = _services!.intake.value;
    if (shared == null || !mounted) return;
    _services!.intake.value = null;
    AppScope.of(context).newChat();
    setState(() {
      _input.text = shared.text;
      _pending
        ..clear()
        ..addAll(shared.attachments);
    });
  }

  void _onChat() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
      }
    });
  }

  Future<bool> _confirm(Skill skill, Map<String, dynamic> args) async {
    if (!mounted) return false;
    final shown = args.entries.where((e) => '${e.value}'.isNotEmpty).map((e) => '${e.key}: ${e.value}').join('\n');
    return confirmDialog(
      context,
      title: 'Allow ${skill.name}?',
      body: '${skill.description}\n\n$shown${skill.confirm == ConfirmPolicy.firstTime ? '\n\nYou will not be asked again for this skill.' : ''}',
      confirm: 'Allow',
    );
  }

  Future<void> _send([String? override]) async {
    final chat = AppScope.of(context).chat;
    final text = override ?? _input.text;
    final attachments = [..._pending];
    if (text.trim().isEmpty && attachments.isEmpty) return;
    _input.clear();
    setState(_pending.clear);
    await chat.send(text, attachments: attachments);
  }

  Future<void> _attach() async {
    final chat = AppScope.of(context).chat;
    final a = await Attach.chooseAndPick(context, _services!, chat.nextAttachmentId(_pending.length));
    if (a != null) setState(() => _pending.add(a));
  }

  Future<void> _suggest(_Suggestion s) async {
    final chat = AppScope.of(context).chat;
    if (s.attach != null) {
      final id = chat.nextAttachmentId(_pending.length);
      final a = s.attach == 'record'
          ? await Attach.record(context, _services!, id)
          : await Attach.image(_services!, id).catchError((Object _) => null);
      if (a == null) return;
      setState(() => _pending.add(a));
    }
    if (s.send) {
      await _send(s.prompt);
    } else {
      _input.text = s.prompt;
    }
  }

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final chat = state.chat;
    final s = state.services;
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 12,
        title: _ModelChip(services: s),
        actions: [
          IconButton(
            tooltip: 'Voice',
            icon: const Icon(Icons.graphic_eq_rounded),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VoiceScreen())),
          ),
          IconButton(tooltip: 'History', icon: const Icon(Icons.history_rounded), onPressed: () => _history(context)),
          IconButton(tooltip: 'New chat', icon: const Icon(Icons.edit_square), onPressed: state.newChat),
          const SizedBox(width: 4),
        ],
      ),
      body: Column(children: [
        if (s.isDemo) const DemoBanner(),
        Expanded(
          child: chat.messages.isEmpty
              ? _Welcome(onSuggestion: _suggest)
              : ListView.builder(
                  controller: _scroll,
                  padding: const EdgeInsets.only(bottom: 16),
                  itemCount: chat.messages.length,
                  itemBuilder: (_, i) => MessageView(
                    message: chat.messages[i],
                    isLast: i == chat.messages.length - 1,
                    onRetry: chat.busy ? null : chat.retry,
                    onOpenModels: () => state.goTo(2),
                  ),
                ),
        ),
        _Composer(
          controller: _input,
          pending: _pending,
          busy: chat.busy,
          onSend: _send,
          onStop: chat.stop,
          onAttach: _attach,
          onRemove: (a) => setState(() => _pending.remove(a)),
          hairline: p.hairline,
        ),
      ]),
    );
  }

  void _history(BuildContext context) {
    final state = AppScope.of(context);
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, controller) => ListenableBuilder(
          listenable: state.services.conversations,
          builder: (_, _) {
            final list = state.services.conversations.summaries;
            if (list.isEmpty) {
              return const EmptyState(icon: Icons.chat_bubble_outline_rounded, title: 'No conversations yet');
            }
            return ListView.builder(
              controller: controller,
              itemCount: list.length + 1,
              itemBuilder: (_, i) {
                if (i == 0) return const SectionLabel('History', padding: EdgeInsets.fromLTRB(20, 0, 20, 8));
                final s = list[i - 1];
                return Dismissible(
                  key: ValueKey(s.id),
                  direction: DismissDirection.endToStart,
                  background: Container(
                    color: context.pal.danger,
                    alignment: Alignment.centerRight,
                    padding: const EdgeInsets.only(right: 24),
                    child: const Icon(Icons.delete_outline_rounded, color: Colors.white),
                  ),
                  onDismissed: (_) => state.services.conversations.delete(s.id),
                  child: ListTile(
                    title: Text(s.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                    subtitle: Text(timeAgo(s.updated)),
                    selected: s.id == state.chat.conversation.id,
                    onTap: () {
                      Navigator.pop(c);
                      state.open(s.id);
                    },
                  ),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ModelChip extends StatelessWidget {
  const _ModelChip({required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return ListenableBuilder(
      listenable: Listenable.merge([services.models, services.settings]),
      builder: (context, _) {
        final m = services.models;
        final planner = modelById(services.settings.plannerId);
        final loaded = m.loadedPlanner == services.settings.plannerId;
        final ready = m.isReady(services.settings.plannerId);
        final loading = m.loadingModel != null;
        return InkWell(
          borderRadius: BorderRadius.circular(999),
          onTap: () => _pick(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (loading)
                const SizedBox(width: 8, height: 8, child: CircularProgressIndicator(strokeWidth: 1.5))
              else
                Dot(color: services.isDemo ? p.warn : loaded ? p.dot : ready ? p.faint : p.danger),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  services.isDemo ? 'Demo engine' : planner?.name ?? 'No model',
                  style: context.text.titleMedium,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 2),
              Icon(Icons.expand_more_rounded, size: 18, color: p.muted),
            ]),
          ),
        );
      },
    );
  }

  void _pick(BuildContext context) {
    final state = AppScope.of(context);
    showModalBottomSheet<void>(
      context: context,
      builder: (c) => ListenableBuilder(
        listenable: services.models,
        builder: (_, _) {
          final planners = gemmaModels.where((g) => g.role == ModelRole.planner).toList();
          return SafeArea(
            child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SectionLabel('Brain', padding: EdgeInsets.fromLTRB(20, 0, 20, 8)),
              for (final g in planners)
                ListTile(
                  title: Text(g.name),
                  subtitle: Text(services.models.isReady(g.id) ? g.summary : 'Not downloaded · ${formatBytes(g.approxBytes)}'),
                  trailing: services.settings.plannerId == g.id ? const Icon(Icons.check_rounded) : null,
                  enabled: services.models.state(g.id).status == ModelStatus.ready || services.isDemo,
                  onTap: () {
                    services.settings.update((s) => s.plannerId = g.id);
                    Navigator.pop(c);
                  },
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
                child: OutlinedButton(
                  onPressed: () {
                    Navigator.pop(c);
                    state.goTo(2);
                  },
                  child: const Text('Manage models'),
                ),
              ),
            ]),
          );
        },
      ),
    );
  }
}

class _Suggestion {
  const _Suggestion(this.icon, this.title, this.prompt, {this.attach, this.send = true});
  final IconData icon;
  final String title;
  final String prompt;

  /// record | photo
  final String? attach;
  final bool send;
}

const _suggestions = [
  _Suggestion(Icons.mic_none_rounded, 'Meeting minutes', 'Make minutes from this meeting', attach: 'record'),
  _Suggestion(Icons.image_outlined, 'Ask about a photo', 'What is in this photo?', attach: 'photo'),
  _Suggestion(Icons.shield_outlined, 'Redact before sharing', 'Redact my email bob@acme.com and phone +1 415 555 0100', send: false),
  _Suggestion(Icons.timer_outlined, 'Set a timer', 'Set a timer for 10 minutes'),
  _Suggestion(Icons.calculate_outlined, 'Exact maths', 'What is 18% of 2450?'),
  _Suggestion(Icons.search_rounded, 'Search my files', 'Search my notes for ', send: false),
];

class _Welcome extends StatelessWidget {
  const _Welcome({required this.onSuggestion});
  final void Function(_Suggestion s) onSuggestion;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final services = AppScope.services(context);
    return ListView(padding: const EdgeInsets.fromLTRB(20, 24, 20, 20), children: [
      Row(children: [
        Dot(size: 10, color: p.ink),
        const SizedBox(width: 6),
        Dot(size: 10, color: p.dot),
      ]),
      const SizedBox(height: 20),
      Text('What can I do\nfor you?', style: context.text.headlineMedium?.copyWith(fontSize: 30, height: 1.15)),
      const SizedBox(height: 8),
      Text('Private by design. Every model runs on this phone, and nothing you say leaves it.', style: context.text.bodyMedium?.copyWith(color: p.muted)),
      const SizedBox(height: 28),
      LayoutBuilder(builder: (context, c) {
        final w = (c.maxWidth - 10) / 2;
        return Wrap(spacing: 10, runSpacing: 10, children: [
          for (final s in _suggestions)
            SizedBox(
              width: w,
              child: Panel(
                onTap: () => onSuggestion(s),
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Icon(s.icon, size: 20, color: p.ink),
                  const SizedBox(height: 18),
                  Text(s.title, style: context.text.titleMedium),
                ]),
              ),
            ),
        ]);
      }),
      const SizedBox(height: 20),
      ListenableBuilder(
        listenable: services.skills,
        builder: (_, _) => Text(
          '${services.skills.enabled.length} skills ready · ${services.models.visibleModels.length} on-device models',
          style: context.text.bodySmall,
          textAlign: TextAlign.center,
        ),
      ),
    ]);
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.pending,
    required this.busy,
    required this.onSend,
    required this.onStop,
    required this.onAttach,
    required this.onRemove,
    required this.hairline,
  });

  final TextEditingController controller;
  final List<Attachment> pending;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onAttach;
  final void Function(Attachment a) onRemove;
  final Color hairline;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return SafeArea(
      top: false,
      child: Container(
        margin: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        decoration: BoxDecoration(
          color: p.surface,
          border: Border.all(color: hairline),
          borderRadius: BorderRadius.circular(24),
        ),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          if (pending.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Wrap(spacing: 6, runSpacing: 6, children: [
                  for (final a in pending) AttachmentChip(a, onRemove: () => onRemove(a)),
                ]),
              ),
            ),
          Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            IconButton(onPressed: busy ? null : onAttach, icon: const Icon(Icons.add_rounded), tooltip: 'Attach'),
            Expanded(
              child: TextField(
                controller: controller,
                minLines: 1,
                maxLines: 6,
                textCapitalization: TextCapitalization.sentences,
                onSubmitted: (_) => onSend(),
                decoration: const InputDecoration(
                  hintText: 'Ask anything',
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.symmetric(vertical: 14),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(6),
              child: ListenableBuilder(
                listenable: controller,
                builder: (_, _) {
                  final canSend = controller.text.trim().isNotEmpty || pending.isNotEmpty;
                  return IconButton.filled(
                    style: IconButton.styleFrom(
                      backgroundColor: busy || canSend ? p.ink : p.surfaceAlt,
                      foregroundColor: busy || canSend ? p.bg : p.faint,
                    ),
                    onPressed: busy ? onStop : canSend ? onSend : null,
                    icon: Icon(busy ? Icons.stop_rounded : Icons.arrow_upward_rounded, size: 20),
                    tooltip: busy ? 'Stop' : 'Send',
                  );
                },
              ),
            ),
          ]),
        ]),
      ),
    );
  }
}
