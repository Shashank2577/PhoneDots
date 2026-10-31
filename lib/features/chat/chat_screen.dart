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
import '../../widgets/hand.dart';
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
      title: 'allow ${skill.name.toLowerCase()}?',
      body:
          '${skill.description}\n\n$shown${skill.confirm == ConfirmPolicy.firstTime ? '\n\nYou will not be asked again for this skill.' : ''}',
      confirm: 'allow',
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
    return HandPage(
      wordmark: true,
      actions: [
        _ModelChip(services: s),
        DoodleButton(
          Doodle.mic,
          tooltip: 'Talk',
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VoiceScreen())),
        ),
        DoodleButton(Doodle.history, tooltip: 'Past chats', onTap: () => _history(context)),
        DoodleButton(Doodle.newChat, tooltip: 'New chat', onTap: chat.messages.isEmpty ? null : state.newChat),
      ],
      body: Column(
        children: [
          if (s.isDemo) const DemoBanner(),
          Expanded(
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 260),
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
                        return Enter(
                          key: ValueKey(m.id),
                          from: Offset(m.isUser ? 24 : 0, 10),
                          child: Column0(
                            child: MessageView(
                              message: m,
                              isLast: i == chat.messages.length - 1,
                              onRetry: chat.busy ? null : chat.retry,
                              onOpenModels: () => state.goTo(2),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          Column0(
            child: _Composer(
              controller: _input,
              pending: _pending,
              busy: chat.busy,
              onSend: _send,
              onStop: chat.stop,
              onAttach: _attach,
              onRemove: (a) => setState(() => _pending.remove(a)),
            ),
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
          builder: (context, _) {
            final list = state.services.conversations.summaries;
            return ListView(
              controller: controller,
              padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 24),
              children: [
                const PageIntro('past chats', 'Pick one to carry on. Everything here is stored on this phone only.'),
                if (list.isEmpty)
                  const HandEmpty(title: 'nothing yet', body: 'Your chats will show up here.', doodle: Doodle.bubble),
                for (final s in list)
                  Door(
                    s.title,
                    style: Hand.label.copyWith(fontSize: 24),
                    meta: timeAgo(s.updated) + (s.id == state.chat.conversation.id ? ' · open now' : ''),
                    onTap: () {
                      Navigator.pop(c);
                      state.open(s.id);
                    },
                    // No hidden swipe: delete is a visible button.
                    trailing: DoodleButton(
                      Doodle.trash,
                      tooltip: 'Delete chat',
                      color: context.pal.redPen,
                      size: 22,
                      onTap: () => state.services.conversations.delete(s.id),
                    ),
                  ),
              ],
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
        final name = services.isDemo ? 'demo' : (planner?.name.replaceFirst('Gemma ', '').toLowerCase() ?? 'no model');
        return Pressable(
          onTap: () => _pick(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (m.loadingModel != null)
                  const Scribbling(size: 12)
                else
                  Dot(size: 6, color: loaded ? p.ink : p.graphite),
                const SizedBox(width: 6),
                HandUnderline(
                  seed: 11,
                  color: p.pencil,
                  child: Text(name, style: Hand.small.copyWith(color: p.ink)),
                ),
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
        builder: (context, _) {
          final planners = gemmaModels.where((g) => g.role == ModelRole.planner).toList();
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const PageIntro('the brain', 'Which Gemma answers you. Bigger is smarter and slower.'),
                  for (final g in planners)
                    Door(
                      g.name,
                      style: Hand.label.copyWith(fontSize: 25),
                      mark: services.settings.plannerId == g.id ? g.name : null,
                      meta: services.models.isReady(g.id)
                          ? g.summary
                          : 'not downloaded · ${formatBytes(g.approxBytes)}',
                      onTap: services.models.state(g.id).status == ModelStatus.ready || services.isDemo
                          ? () {
                              services.settings.update((s) => s.plannerId = g.id);
                              Navigator.pop(c);
                            }
                          : null,
                    ),
                  const SizedBox(height: 8),
                  PillButton(
                    'manage models',
                    leading: Doodle.chip,
                    onTap: () {
                      Navigator.pop(c);
                      state.goTo(2);
                    },
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Suggestion {
  const _Suggestion(this.doodle, this.title, this.meta, this.prompt, {this.attach, this.send = true});
  final Doodle doodle;
  final String title;
  final String meta;
  final String prompt;

  /// record | photo
  final String? attach;
  final bool send;
}

const _suggestions = [
  _Suggestion(
    Doodle.mic,
    'record a meeting',
    'notes, who spoke, and follow-ups',
    'Make minutes from this meeting',
    attach: 'record',
  ),
  _Suggestion(
    Doodle.camera,
    'ask about a photo',
    'Gemma looks at it right here',
    'What is in this photo?',
    attach: 'photo',
  ),
  _Suggestion(
    Doodle.mask,
    'mask before you share',
    'names and numbers swapped out',
    'Redact my email bob@acme.com and phone +1 415 555 0100',
    send: false,
  ),
  _Suggestion(Doodle.timer, 'set a timer', 'the quick model does it instantly', 'Set a timer for 10 minutes'),
  _Suggestion(Doodle.calc, 'exact maths', 'no guessing, a real calculator', 'What is 18% of 2450?'),
  _Suggestion(Doodle.search, 'search my files', 'notes, receipts, transcripts', 'Search my notes for ', send: false),
];

class _Welcome extends StatelessWidget {
  const _Welcome({super.key, required this.onSuggestion});
  final void Function(_Suggestion s) onSuggestion;

  static String _greeting() {
    final h = DateTime.now().hour;
    return h < 12
        ? 'good morning.'
        : h < 18
        ? 'good afternoon.'
        : 'good evening.';
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.services(context);
    return ListView(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      padding: const EdgeInsets.only(top: 8, bottom: 16),
      children: [
        Column0(
          child: Enter(
            child: PageIntro(
              _greeting(),
              'Ask anything, or pick a door below. Every model runs on this phone, and nothing you say leaves it.',
              doodle: Doodle.sun,
            ),
          ),
        ),
        for (var i = 0; i < _suggestions.length; i++)
          Column0(
            child: Enter(
              index: i + 1,
              child: Door(
                _suggestions[i].title,
                leading: _suggestions[i].doodle,
                meta: _suggestions[i].meta,
                onTap: () => onSuggestion(_suggestions[i]),
              ),
            ),
          ),
        const SizedBox(height: 12),
        Column0(
          child: ListenableBuilder(
            listenable: services.skills,
            builder: (_, _) => Row(
              children: [
                const OnDeviceStamp(),
                const Spacer(),
                Meta('${services.skills.enabled.length} skills · ${services.models.visibleModels.length} models'),
              ],
            ),
          ),
        ),
      ],
    );
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
  });

  final TextEditingController controller;
  final List<Attachment> pending;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onAttach;
  final void Function(Attachment a) onRemove;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 10),
        // The smudge well: the only filled shape on the page.
        child: DecoratedBox(
          decoration: BoxDecoration(color: p.smudge, borderRadius: BorderRadius.circular(24)),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                child: pending.isEmpty
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final a in pending) Enter(child: AttachmentChip(a, onRemove: () => onRemove(a))),
                            ],
                          ),
                        ),
                      ),
              ),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(left: 2, bottom: 4),
                    child: DoodleButton(Doodle.clip, tooltip: 'Attach', size: 22, onTap: busy ? null : onAttach),
                  ),
                  Expanded(
                    child: CallbackShortcuts(
                      // Hardware keyboards: Enter sends, Shift+Enter adds a line.
                      bindings: {const SingleActivator(LogicalKeyboardKey.enter): () => busy ? null : onSend()},
                      child: TextField(
                        controller: controller,
                        minLines: 1,
                        maxLines: 6,
                        textCapitalization: TextCapitalization.sentences,
                        onSubmitted: (_) => onSend(),
                        decoration: const InputDecoration(
                          hintText: 'ask anything…',
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
                    padding: const EdgeInsets.all(6),
                    child: ListenableBuilder(
                      listenable: controller,
                      builder: (_, _) {
                        final canSend = controller.text.trim().isNotEmpty || pending.isNotEmpty;
                        final active = busy || canSend;
                        return Pressable(
                          onTap: busy ? onStop : (canSend ? onSend : null),
                          scale: 0.86,
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 180),
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: active ? p.ink : Colors.transparent,
                              border: Border.all(color: active ? p.ink : p.graphite, width: 1.6),
                            ),
                            child: Center(
                              child: AnimatedSwitcher(
                                duration: const Duration(milliseconds: 180),
                                transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                                child: DoodleIcon(
                                  busy ? Doodle.stop : Doodle.arrow,
                                  key: ValueKey(busy),
                                  size: 22,
                                  color: active ? p.paper : p.graphite,
                                  semanticLabel: busy ? 'Stop' : 'Send',
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
    );
  }
}
