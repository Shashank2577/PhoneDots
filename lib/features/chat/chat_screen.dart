import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../agent/agent.dart';
import '../../agent/conversation.dart';
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
import '../../core/app_log.dart';
import '../models/models_screen.dart';
import '../settings/diagnostics_screen.dart';
import '../skills/skills_screen.dart';
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
      WidgetsBinding.instance.addPostFrameCallback((_) => _crashNotice());
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

  /// After a crash, say so once, with a way to the details.
  void _crashNotice() {
    if (!mounted || appLog.lastCrash == null || appLog.crashNoticeShown) return;
    appLog.crashNoticeShown = true;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        duration: const Duration(seconds: 8),
        content: const Text('PhoneDots closed unexpectedly last time.'),
        action: SnackBarAction(
          label: 'details',
          onPressed: () =>
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const DiagnosticsScreen())),
        ),
      ),
    );
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

  void _talk() => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VoiceScreen()));

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final chat = state.chat;
    final s = state.services;
    final typing = _keyboard(context) > 0;
    return HandPage(
      wordmark: true,
      actions: [
        DoodleButton(Doodle.history, tooltip: 'Past chats', onTap: () => showPastChats(context)),
        DoodleButton(Doodle.newChat, tooltip: 'New chat', onTap: chat.messages.isEmpty ? null : state.newChat),
      ],
      body: Column(
        children: [
          ListenableBuilder(
            listenable: s.conversations,
            builder: (context, _) {
              final err = s.conversations.saveError;
              if (err == null) return const SizedBox.shrink();
              return Column0(
                child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Warning(err)),
              );
            },
          ),
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
                              onOpenModels: () => openModels(context),
                            ),
                          ),
                        );
                      },
                    ),
            ),
          ),
          // While typing, or on a short screen with attachments waiting, every line goes to the conversation.
          if (!typing && (_pending.isEmpty || MediaQuery.sizeOf(context).height >= 700))
            Column0(child: _ModelLine(services: s)),
          Column0(
            child: _Composer(
              controller: _input,
              pending: _pending,
              busy: chat.busy,
              onSend: _send,
              onStop: chat.stop,
              onAttach: _attach,
              onTalk: _talk,
              onRemove: (a) => setState(() => _pending.remove(a)),
            ),
          ),
        ],
      ),
    );
  }
}

/// Every saved chat with a preview of where it left off. Pick one to carry on.
void showPastChats(BuildContext context) {
  final state = AppScope.of(context);
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (c) => DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      builder: (_, controller) => ListenableBuilder(
        listenable: state.services.conversations,
        builder: (context, _) {
          final list = state.services.conversations.summaries;
          return ListView(
            controller: controller,
            padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 24),
            children: [
              const PageIntro(
                'past chats',
                'Pick one to carry on where you left off. All of them are stored on this phone.',
              ),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  PillButton(
                    'start a new chat',
                    leading: Doodle.newChat,
                    onTap: () {
                      Navigator.pop(c);
                      state.newChat();
                      state.goTo(AppState.chatTab);
                    },
                  ),
                  if (state.chat.messages.isNotEmpty)
                    HandLink(
                      'copy this chat',
                      onTap: () {
                        Clipboard.setData(ClipboardData(text: ConversationStore.transcript(state.chat.conversation)));
                        Navigator.pop(c);
                        toast(context, 'chat copied');
                      },
                    ),
                ],
              ),
              const SizedBox(height: 8),
              if (list.isEmpty)
                const HandEmpty(title: 'nothing yet', body: 'Your chats will show up here.', doodle: Doodle.bubble),
              for (final s in list)
                ChatRow(
                  s,
                  open: s.id == state.chat.conversation.id,
                  onTap: () {
                    Navigator.pop(c);
                    state.open(s.id);
                  },
                  onDelete: () => state.services.conversations.delete(s.id),
                ),
            ],
          );
        },
      ),
    ),
  );
}

/// One past chat: title, where it left off, when, and a visible delete.
class ChatRow extends StatelessWidget {
  const ChatRow(this.summary, {super.key, required this.onTap, this.onDelete, this.open = false});
  final ConversationSummary summary;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  final bool open;

  @override
  Widget build(BuildContext context) => ItemRow(
    title: summary.title,
    titleLines: 1,
    meta: summary.preview,
    caption: [
      timeAgo(summary.updated),
      if (summary.count > 0) '${summary.count} ${summary.count == 1 ? 'message' : 'messages'}',
      if (open) 'open now',
    ].join(' · '),
    leading: DoodleIcon(Doodle.bubble, size: 20, color: context.pal.pencil),
    onTap: onTap,
    trailing: onDelete == null
        ? null
        : DoodleButton(Doodle.trash, tooltip: 'Delete chat', color: context.pal.pencil, size: 20, onTap: onDelete),
  );
}

/// "Gemma 4 E2B · on this phone", just above the composer; tap to pick the brain.
class _ModelLine extends StatelessWidget {
  const _ModelLine({required this.services});
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return ListenableBuilder(
      listenable: Listenable.merge([services.models, services.settings]),
      builder: (context, _) {
        final m = services.models;
        final planner = modelById(services.settings.plannerId);
        final name = planner?.name ?? 'No model';
        final line = services.isDemo
            ? 'Demo engine · nothing leaves this device'
            : m.loadingModel != null
            ? '$name · loading'
            : m.isReady(services.settings.plannerId)
            ? '$name · on this phone'
            : '$name · not downloaded yet';
        return Semantics(
          button: true,
          label: 'Model: $line. Change',
          excludeSemantics: true,
          child: Pressable(
            onTap: () => _pick(context),
            scale: 0.99,
            child: ConstrainedBox(
              constraints: const BoxConstraints(minHeight: minTap),
              child: Row(
                children: [
                  if (m.loadingModel != null) ...[const Scribbling(size: 12), const SizedBox(width: 8)],
                  Flexible(child: Caption(line, maxLines: 1)),
                  const SizedBox(width: 4),
                  Transform.rotate(
                    angle: 1.5708,
                    child: DoodleIcon(Doodle.arrow, size: 14, color: p.pencil, stroke: 1.8),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  void _pick(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.9),
      builder: (c) => ListenableBuilder(
        listenable: services.models,
        builder: (context, _) {
          final planners = gemmaModels.where((g) => g.role == ModelRole.planner).toList();
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const PageIntro('the brain', 'Which Gemma answers you. Bigger is smarter and slower.'),
                  for (final g in planners)
                    ItemRow(
                      title: g.name,
                      meta: g.summary,
                      caption: services.models.isReady(g.id) || services.isDemo
                          ? formatBytes(g.approxBytes)
                          : 'Not downloaded · ${formatBytes(g.approxBytes)}',
                      leading: SizedBox(
                        width: 22,
                        child: services.settings.plannerId == g.id ? const DrawnDoodle(Doodle.tick, size: 22) : null,
                      ),
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
                      openModels(context);
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
  const _Suggestion(this.doodle, this.title, this.prompt, {this.attach, this.send = true});
  final Doodle doodle;
  final String title;
  final String prompt;

  /// record | photo
  final String? attach;
  final bool send;
}

// Four ways in; everything else is under skills ("what else can it do?").
const _suggestions = [
  _Suggestion(Doodle.mic, 'record a meeting', 'Make minutes from this meeting', attach: 'record'),
  _Suggestion(Doodle.camera, 'ask about a photo', 'What is in this photo?', attach: 'photo'),
  _Suggestion(
    Doodle.mask,
    'mask before you share',
    'Redact my email bob@acme.com and phone +1 415 555 0100',
    send: false,
  ),
  _Suggestion(Doodle.search, 'search my files', 'Search my notes for ', send: false),
];

class _Welcome extends StatelessWidget {
  const _Welcome({super.key, required this.onSuggestion});
  final void Function(_Suggestion s) onSuggestion;

  static String _greeting() {
    final h = DateTime.now().hour;
    return h < 12
        ? 'good morning'
        : h < 18
        ? 'good afternoon'
        : 'good evening';
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.services(context);
    return ListenableBuilder(listenable: services.settings, builder: (context, _) => _list(context, services));
  }

  Widget _list(BuildContext context, AppServices services) => ListView(
    physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
    padding: const EdgeInsets.only(top: 16, bottom: 16),
    children: [
      Column0(
        child: Enter(child: PageIntro(_greeting(), 'Ask anything. It runs on this phone.')),
      ),
      // Said once in the preview; after that the model line says "Demo engine".
      if (services.isDemo && !services.settings.demoNoteSeen)
        Column0(
          child: Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: DemoNote(onDone: () => services.settings.update((x) => x.demoNoteSeen = true)),
          ),
        ),
      Column0(
        child: Wrap(
          spacing: 8,
          runSpacing: 10,
          children: [
            for (var i = 0; i < _suggestions.length; i++)
              Enter(
                index: i + 1,
                child: PillButton(
                  _suggestions[i].title,
                  leading: _suggestions[i].doodle,
                  onTap: () => onSuggestion(_suggestions[i]),
                ),
              ),
          ],
        ),
      ),
      const SizedBox(height: 16),
      Column0(
        child: Enter(
          index: 6,
          child: HandLink('what else can it do?', onTap: () => openSkills(context)),
        ),
      ),
    ],
  );
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.pending,
    required this.busy,
    required this.onSend,
    required this.onStop,
    required this.onAttach,
    required this.onTalk,
    required this.onRemove,
  });

  final TextEditingController controller;
  final List<Attachment> pending;
  final bool busy;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onAttach;
  final VoidCallback onTalk;
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
                        // One scrolling row, so many attachments never push the chat off screen.
                        child: SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Row(
                            children: [
                              for (final a in pending)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: Enter(child: AttachmentChip(a, onRemove: () => onRemove(a))),
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
                        // Short screens (or a big keyboard) keep the draft to a few lines; it scrolls inside.
                        maxLines: _draftLines(context),
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
                        // Mic while empty (talk to it), send once there is something, stop while it works.
                        final (doodle, label, onTap) = busy
                            ? (Doodle.stop, 'Stop', onStop)
                            : canSend
                            ? (Doodle.send, 'Send', onSend)
                            : (Doodle.mic, 'Talk', onTalk);
                        final filled = busy || canSend;
                        return Semantics(
                          button: true,
                          label: label,
                          excludeSemantics: true,
                          child: Pressable(
                            onTap: onTap,
                            scale: 0.86,
                            child: AnimatedContainer(
                              duration: const Duration(milliseconds: 180),
                              width: 48,
                              height: 48,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: filled ? p.ink : Colors.transparent,
                              ),
                              child: Center(
                                child: AnimatedSwitcher(
                                  duration: const Duration(milliseconds: 180),
                                  transitionBuilder: (c, a) => ScaleTransition(scale: a, child: c),
                                  child: DoodleIcon(
                                    doodle,
                                    key: ValueKey(doodle),
                                    size: 22,
                                    color: filled ? p.paper : p.ink,
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
    );
  }
}

/// How many lines the draft may grow to: about a third of the room left above
/// the keyboard, so the conversation never disappears (big text included).
int _draftLines(BuildContext context) {
  final room = MediaQuery.sizeOf(context).height - _keyboard(context) - 160;
  final line = MediaQuery.textScalerOf(context).scale(22);
  return (room * 0.33 / line).floor().clamp(1, 6);
}

/// The on-screen keyboard's height. Read from the window, because the page's
/// Scaffold has already taken it out of MediaQuery by the time we build.
double _keyboard(BuildContext context) {
  final v = View.of(context);
  return v.viewInsets.bottom / v.devicePixelRatio;
}
