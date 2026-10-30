import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
import '../../widgets/sketch.dart';
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
        _scroll.animateTo(
          _scroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<bool> _confirm(Skill skill, Map<String, dynamic> args) async {
    if (!mounted) return false;
    final shown = args.entries.where((e) => '${e.value}'.isNotEmpty).map((e) => '${e.key}: ${e.value}').join('\n');
    return confirmDialog(
      context,
      title: 'Allow ${skill.name}?',
      body:
          '${skill.description}\n\n$shown${skill.confirm == ConfirmPolicy.firstTime ? '\n\nYou will not be asked again for this skill.' : ''}',
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
      body: Column(
        children: [
          if (s.isDemo) const DemoBanner(),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              child: chat.messages.isEmpty
                  ? _Welcome(key: const ValueKey('welcome'), onSuggestion: _suggest)
                  : ListView.builder(
                      key: const ValueKey('messages'),
                      controller: _scroll,
                      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                      padding: const EdgeInsets.only(bottom: 16),
                      itemCount: chat.messages.length,
                      itemBuilder: (_, i) {
                        final m = chat.messages[i];
                        // New messages fly in from their side: yours from the right, replies from the left.
                        return Enter(
                          key: ValueKey(m.id),
                          from: Offset(m.isUser ? 40 : -24, 12),
                          tilt: m.isUser ? -0.04 : 0.03,
                          child: MessageView(
                            message: m,
                            isLast: i == chat.messages.length - 1,
                            onRetry: chat.busy ? null : chat.retry,
                            onOpenModels: () => state.goTo(2),
                          ),
                        );
                      },
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
          ),
        ],
      ),
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
        return Pressable(
          onTap: () => _pick(context),
          child: SketchBox(
            seed: 301,
            radius: 18,
            fill: p.note(3),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (loading)
                  const Scribbling(size: 12)
                else
                  Dot(
                    color: services.isDemo
                        ? p.warn
                        : loaded
                        ? p.dot
                        : ready
                        ? p.faint
                        : p.danger,
                  ),
                const SizedBox(width: 8),
                Flexible(
                  child: Text(
                    services.isDemo ? 'Demo engine' : planner?.name ?? 'No model',
                    style: context.text.titleMedium?.copyWith(fontSize: 17),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(Icons.expand_more_rounded, size: 18, color: p.muted),
              ],
            ),
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SectionLabel('Brain', padding: EdgeInsets.fromLTRB(20, 0, 20, 8)),
                for (final g in planners)
                  ListTile(
                    title: Text(g.name),
                    subtitle: Text(
                      services.models.isReady(g.id) ? g.summary : 'Not downloaded · ${formatBytes(g.approxBytes)}',
                    ),
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
              ],
            ),
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
  _Suggestion(
    Icons.shield_outlined,
    'Redact before sharing',
    'Redact my email bob@acme.com and phone +1 415 555 0100',
    send: false,
  ),
  _Suggestion(Icons.timer_outlined, 'Set a timer', 'Set a timer for 10 minutes'),
  _Suggestion(Icons.calculate_outlined, 'Exact maths', 'What is 18% of 2450?'),
  _Suggestion(Icons.search_rounded, 'Search my files', 'Search my notes for ', send: false),
];

class _Welcome extends StatelessWidget {
  const _Welcome({super.key, required this.onSuggestion});
  final void Function(_Suggestion s) onSuggestion;

  static const _tilts = [-0.035, 0.025, 0.03, -0.02, -0.025, 0.035];

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final services = AppScope.services(context);
    return ListView(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
      children: [
        const Enter(child: Row(children: [_LogoDots()])),
        const SizedBox(height: 14),
        Enter(
          index: 1,
          child: Text('What can I do\nfor you?', style: context.text.displaySmall?.copyWith(height: 0.95)),
        ),
        Enter(index: 2, child: Underline(width: 190, seed: 4, delay: const Duration(milliseconds: 500))),
        const SizedBox(height: 6),
        Enter(
          index: 2,
          child: Text(
            'Private by design. Every model runs on this phone, and nothing you say leaves it.',
            style: context.text.bodyMedium?.copyWith(color: p.muted),
          ),
        ),
        const SizedBox(height: 26),
        LayoutBuilder(
          builder: (context, c) {
            final w = (c.maxWidth - 14) / 2;
            return Wrap(
              spacing: 14,
              runSpacing: 16,
              children: [
                for (var i = 0; i < _suggestions.length; i++)
                  Enter(
                    index: 3 + i,
                    tilt: _tilts[i] * 3,
                    child: Transform.rotate(
                      angle: _tilts[i],
                      child: SizedBox(
                        width: w,
                        child: Pressable(
                          onTap: () => onSuggestion(_suggestions[i]),
                          tilt: -_tilts[i],
                          child: SketchBox(
                            seed: 100 + i,
                            fill: p.note(i),
                            radius: 6,
                            shadow: 3,
                            padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Icon(_suggestions[i].icon, size: 24, color: p.ink),
                                const SizedBox(height: 16),
                                Text(_suggestions[i].title, style: context.text.titleMedium?.copyWith(fontSize: 19)),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            );
          },
        ),
        const SizedBox(height: 24),
        ListenableBuilder(
          listenable: services.skills,
          builder: (_, _) => Text(
            '${services.skills.enabled.length} skills ready · ${services.models.visibleModels.length} on-device models',
            style: context.text.bodySmall,
            textAlign: TextAlign.center,
          ),
        ),
      ],
    );
  }
}

/// The brand: ink dot and green dot that hop once on arrival, then idle.
class _LogoDots extends StatelessWidget {
  const _LogoDots();

  @override
  Widget build(BuildContext context) => const SizedBox(height: 26, child: HoppingDots(size: 11));
}

class _Composer extends StatefulWidget {
  const _Composer({
    required this.controller,
    required this.pending,
    required this.busy,
    required this.onSend,
    required this.onStop,
    required this.onAttach,
    required this.onRemove,
  });

  final TextEditingController controller;
  final List<Attachment> pending;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onAttach;
  final void Function(Attachment a) onRemove;

  @override
  State<_Composer> createState() => _ComposerState();
}

class _ComposerState extends State<_Composer> {
  int _nudge = 0;

  void _send() {
    final canSend = widget.controller.text.trim().isNotEmpty || widget.pending.isNotEmpty;
    if (!canSend) {
      setState(() => _nudge++);
      return;
    }
    widget.onSend();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        child: Wiggle(
          trigger: _nudge,
          child: SketchBox(
            seed: 201,
            radius: 22,
            shadow: 3,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedSize(
                  duration: const Duration(milliseconds: 260),
                  curve: Curves.easeOutBack,
                  child: widget.pending.isEmpty
                      ? const SizedBox(width: double.infinity)
                      : Padding(
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                          child: Align(
                            alignment: Alignment.centerLeft,
                            child: Wrap(
                              spacing: 6,
                              runSpacing: 6,
                              children: [
                                for (final a in widget.pending)
                                  Enter(
                                    from: const Offset(0, 10),
                                    child: AttachmentChip(a, onRemove: () => widget.onRemove(a)),
                                  ),
                              ],
                            ),
                          ),
                        ),
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Pressable(
                        onTap: widget.busy ? null : widget.onAttach,
                        scale: 0.85,
                        tilt: 0.2,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(Icons.attach_file_rounded, color: p.ink),
                        ),
                      ),
                    ),
                    Expanded(
                      child: CallbackShortcuts(
                        // Hardware keyboards: Enter sends, Shift+Enter adds a line.
                        bindings: {const SingleActivator(LogicalKeyboardKey.enter): () => widget.busy ? null : _send()},
                        child: TextField(
                          controller: widget.controller,
                          minLines: 1,
                          maxLines: 6,
                          textCapitalization: TextCapitalization.sentences,
                          onSubmitted: (_) => _send(),
                          style: context.text.bodyLarge,
                          decoration: const InputDecoration(
                            hintText: 'Ask anything…',
                            filled: false,
                            border: InputBorder.none,
                            enabledBorder: InputBorder.none,
                            focusedBorder: InputBorder.none,
                            contentPadding: EdgeInsets.symmetric(vertical: 16),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(7),
                      child: ListenableBuilder(
                        listenable: widget.controller,
                        builder: (_, _) {
                          final canSend = widget.controller.text.trim().isNotEmpty || widget.pending.isNotEmpty;
                          final active = widget.busy || canSend;
                          return Pressable(
                            onTap: widget.busy ? widget.onStop : _send,
                            scale: 0.8,
                            tilt: 0.3,
                            child: AnimatedRotation(
                              turns: canSend && !widget.busy ? -0.08 : 0,
                              duration: const Duration(milliseconds: 420),
                              curve: Curves.elasticOut,
                              child: SketchBox(
                                seed: 202,
                                radius: 20,
                                fill: active ? p.ink : p.surfaceAlt,
                                stroke: active ? p.ink : p.faint,
                                child: SizedBox.square(
                                  dimension: 42,
                                  child: AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 220),
                                    transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                                    child: Icon(
                                      widget.busy ? Icons.stop_rounded : Icons.send_rounded,
                                      key: ValueKey(widget.busy),
                                      size: 20,
                                      color: active ? p.bg : p.faint,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
