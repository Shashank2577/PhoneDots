import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../app_services.dart';
import '../core/models/model_catalog.dart';
import '../core/models/model_spec.dart';
import '../core/runtime/engine_types.dart';
import '../core/util/files.dart';
import '../skills/skill.dart';
import 'conversation.dart';
import 'prompts.dart';
import 'tool_call_parser.dart';

const _uuid = Uuid();

/// Asks the user to approve a side-effecting skill call.
typedef ConfirmCallback = Future<bool> Function(Skill skill, Map<String, dynamic> args);

/// Runs one conversation: routes each turn through FunctionGemma (fast path)
/// or Gemma 4 (planner), executes skills in a bounded tool loop, and streams
/// everything into the message list.
class ChatController extends ChangeNotifier {
  ChatController(this.services, {Conversation? conversation})
      : conversation = conversation ?? Conversation(id: _uuid.v4());

  final AppServices services;
  final Conversation conversation;
  ConfirmCallback? onConfirm;
  bool busy = false;
  bool _stopRequested = false;

  List<ChatMessage> get messages => conversation.messages;

  List<Attachment> get allAttachments => [for (final m in messages) ...m.attachments];

  /// Next free attachment id ("a3") so ids stay unique across turns.
  String nextAttachmentId(int offset) => 'a${allAttachments.length + offset + 1}';

  void refresh() => notifyListeners();

  Future<void> stop() async {
    _stopRequested = true;
    await services.llm.cancel();
  }

  Future<void> send(String text, {List<Attachment> attachments = const []}) async {
    if (busy || (text.trim().isEmpty && attachments.isEmpty)) return;
    busy = true;
    _stopRequested = false;
    final user = ChatMessage(id: _uuid.v4(), isUser: true, text: text.trim(), attachments: attachments);
    final reply = ChatMessage(id: _uuid.v4(), isUser: false, streaming: true);
    messages
      ..add(user)
      ..add(reply);
    if (conversation.title == 'New chat') {
      final t = text.trim().isEmpty ? attachments.first.name : text.trim();
      conversation.title = t.length > 48 ? '${t.substring(0, 48)}…' : t;
    }
    notifyListeners();
    try {
      final routed = await _tryRouter(user, reply);
      if (!routed) await _runPlanner(user, reply);
    } catch (e) {
      reply.error = '$e';
    } finally {
      reply.streaming = false;
      busy = false;
      notifyListeners();
      await services.conversations.save(conversation);
    }
  }

  /// Runs one skill directly (skill "Try it", recipe runs) without asking a
  /// model to pick it.
  Future<void> runSkill(Skill skill, Map<String, dynamic> args, {String? label, List<Attachment> attachments = const []}) async {
    if (busy) return;
    busy = true;
    final user = ChatMessage(id: _uuid.v4(), isUser: true, text: label ?? skill.name, attachments: attachments);
    final reply = ChatMessage(id: _uuid.v4(), isUser: false, streaming: true);
    messages
      ..add(user)
      ..add(reply);
    if (conversation.title == 'New chat') conversation.title = label ?? skill.name;
    notifyListeners();
    try {
      final call = ToolCallRequest(id: _uuid.v4(), name: skill.id, arguments: args);
      final step = await _execute(call, reply, via: skill.kind == SkillKind.recipe ? 'recipe' : 'direct');
      reply.text = step.status == StepStatus.done
          ? '${step.result['summary'] ?? (step.cards.isEmpty ? 'Done.' : '')}'
          : '';
      if (step.status != StepStatus.done) reply.error = '${step.result['error'] ?? 'Failed'}';
      reply.turns.addAll([
        EngineTurn(role: TurnRole.model, toolCalls: [call]),
        EngineTurn(role: TurnRole.tool, toolResponses: [ToolResponse(callId: call.id, name: call.name, response: _compact(step.result))]),
        if (reply.text.isNotEmpty) EngineTurn(role: TurnRole.model, text: reply.text),
      ]);
    } finally {
      reply.streaming = false;
      busy = false;
      notifyListeners();
      await services.conversations.save(conversation);
    }
  }

  /// Retries the last user message.
  Future<void> retry() async {
    if (busy || messages.length < 2) return;
    final reply = messages.removeLast();
    final user = messages.removeLast();
    if (!user.isUser) {
      messages.addAll([user, reply]);
      return;
    }
    await services.llm.resetSession(conversation.id);
    await send(user.text, attachments: user.attachments);
  }

  // Fast path ---------------------------------------------------------------

  static const _routerSkills = {
    'set_timer', 'set_alarm', 'toggle_flashlight', 'open_settings', 'set_volume', 'battery_status',
    'get_datetime', 'navigate_to', 'open_app', 'create_event', 'calculate', 'convert_units',
  };

  Future<bool> _tryRouter(ChatMessage user, ChatMessage reply) async {
    final s = services.settings;
    if (!s.useRouter || services.isDemo || user.attachments.isNotEmpty || user.text.length > 160) return false;
    if (!services.models.isReady(s.routerId) || !await services.models.ensureRouter()) return false;
    final tools = services.skills.enabled.where((k) => _routerSkills.contains(k.id)).toList();
    final req = GenerationRequest(
      modelId: s.routerId,
      sessionId: 'router-${_uuid.v4()}',
      systemPrompt: Prompts.router,
      history: [EngineTurn(role: TurnRole.user, text: user.text)],
      tools: tools.map((t) => t.toToolSpec()).toList(),
      sampler: const SamplerSettings(temperature: 0, topK: 1, maxTokens: 128),
    );
    final calls = <ToolCallRequest>[];
    var text = '';
    await for (final e in services.llm.generate(req)) {
      if (e is ToolCallsEvent) calls.addAll(e.calls);
      if (e is TokenEvent) text += e.text;
      if (e is ErrorEvent) return false;
    }
    if (calls.isEmpty) {
      calls.addAll(ToolCallParser.parse(text, tools.map((t) => t.id).toSet()).calls);
    }
    if (calls.length != 1) return false;
    final step = await _execute(calls.single, reply, via: 'router');
    if (step.status == StepStatus.done) {
      reply
        ..modelId = s.routerId
        ..text = '${step.result['summary'] ?? step.result['message'] ?? 'Done.'}';
      reply.turns.addAll([
        EngineTurn(role: TurnRole.model, toolCalls: calls),
        EngineTurn(role: TurnRole.tool, toolResponses: [ToolResponse(callId: calls.single.id, name: calls.single.name, response: step.result)]),
        EngineTurn(role: TurnRole.model, text: reply.text),
      ]);
      return true;
    }
    // A failed fast-path call falls back to the planner for a better answer.
    reply.steps.clear();
    return false;
  }

  // Planner loop --------------------------------------------------------------

  List<EngineTurn> _history() {
    final out = <EngineTurn>[];
    final planner = modelById(services.settings.plannerId);
    final seesImages = planner?.has(ModelCapability.image) ?? false;
    final hearsAudio = planner?.has(ModelCapability.audio) ?? false;
    for (final m in messages) {
      if (m.isUser) {
        out.add(EngineTurn(
          role: TurnRole.user,
          text: m.text.isEmpty ? 'See attachment.' : m.text,
          imagePaths: seesImages ? [for (final a in m.attachments) if (a.kind == 'image') a.path] : const [],
          // Long recordings go to Voz instead; short clips Gemma can hear directly.
          audioPaths: hearsAudio
              ? [for (final a in m.attachments) if (a.kind == 'audio' && fileLength(a.path) < 1500000) a.path]
              : const [],
        ));
      } else if (m.turns.isNotEmpty) {
        out.addAll(m.turns);
      } else if (m.text.isNotEmpty) {
        out.add(EngineTurn(role: TurnRole.model, text: m.text));
      }
    }
    return out;
  }

  Future<void> _runPlanner(ChatMessage user, ChatMessage reply) async {
    final s = services.settings;
    final ready = services.isDemo || await services.models.ensurePlanner();
    if (!ready) {
      reply.error = services.models.isReady(s.plannerId)
          ? services.models.loadError ?? 'The model failed to load.'
          : 'No language model yet. Download ${modelById(s.plannerId)?.name ?? 'Gemma'} in Models to start chatting.';
      return;
    }
    reply.modelId = s.plannerId;
    final skills = services.skills.selectFor(user.text, attachments: allAttachments);
    final tools = skills.map((k) => k.toToolSpec()).toList();
    final toolNames = tools.map((t) => t.name).toSet();
    final system = Prompts.system(
      now: DateTime.now(),
      attachments: allAttachments,
      memory: services.memory.promptBlock,
      tools: tools,
      nativeTools: services.llm.supportsNativeTools,
    );

    for (var round = 0; round <= s.maxSteps; round++) {
      // The reply's turns so far (tool calls and results) are part of the
      // history because the reply is already in [messages].
      final req = GenerationRequest(
        modelId: s.plannerId,
        sessionId: conversation.id,
        systemPrompt: system,
        history: _history(),
        tools: round == s.maxSteps ? const [] : tools,
        thinking: s.thinking,
        sampler: SamplerSettings(temperature: s.temperature, maxTokens: 1024),
      );
      final roundText = StringBuffer();
      final calls = <ToolCallRequest>[];
      final textBefore = reply.text;
      await for (final e in services.llm.generate(req)) {
        switch (e) {
          case TokenEvent(:final text):
            roundText.write(text);
            reply.text = textBefore + roundText.toString();
            notifyListeners();
          case ThinkingEvent(:final text):
            reply.thinking += text;
            notifyListeners();
          case ToolCallsEvent(calls: final c):
            calls.addAll(c);
          case DoneEvent(:final stats):
            reply.stats = stats;
          case ErrorEvent(:final message):
            reply.error = message;
        }
      }
      if (reply.error != null || _stopRequested) break;

      var text = roundText.toString();
      if (calls.isEmpty && !services.llm.supportsNativeTools) {
        final parsed = ToolCallParser.parse(text, toolNames);
        calls.addAll(parsed.calls);
        text = parsed.text;
        reply.text = textBefore + text;
      }
      if (calls.isEmpty) {
        reply.turns.add(EngineTurn(role: TurnRole.model, text: text));
        break;
      }
      reply.turns.add(EngineTurn(role: TurnRole.model, text: text, toolCalls: calls));
      final responses = <ToolResponse>[];
      for (final call in calls) {
        final step = await _execute(call, reply);
        responses.add(ToolResponse(callId: call.id, name: call.name, response: _compact(step.result)));
      }
      reply.turns.add(EngineTurn(role: TurnRole.tool, toolResponses: responses));
      if (reply.text.isNotEmpty && !reply.text.endsWith('\n')) reply.text += '\n\n';
      notifyListeners();
    }
    reply.text = reply.text.trim();
  }

  /// Keeps tool responses small enough for a 4k context.
  static Map<String, dynamic> _compact(Map<String, dynamic> r) {
    final out = <String, dynamic>{};
    for (final e in r.entries) {
      final v = e.value;
      if (v is String && v.length > 3000) {
        out[e.key] = '${v.substring(0, 3000)}…';
      } else if (v is List && v.length > 30) {
        out[e.key] = [...v.take(30), '…${v.length - 30} more'];
      } else {
        out[e.key] = v;
      }
    }
    return out;
  }

  // Skill execution ---------------------------------------------------------

  Future<AgentStep> _execute(ToolCallRequest call, ChatMessage reply, {String via = 'planner'}) async {
    final skill = services.skills.byId(call.name);
    final step = AgentStep(skillId: call.name, skillName: skill?.name ?? call.name, args: call.arguments, via: via);
    reply.steps.add(step);
    notifyListeners();
    final started = DateTime.now();
    try {
      if (skill == null || !services.skills.isEnabled(skill)) {
        step
          ..status = StepStatus.failed
          ..result = {'error': 'Unknown or disabled tool ${call.name}'};
        return step;
      }
      final missing = skill.requiresModels.where((m) => !services.models.isReady(m)).toList();
      if (missing.isNotEmpty && !services.isDemo) {
        final names = missing.map((m) => modelById(m)?.name ?? m).join(', ');
        step
          ..status = StepStatus.failed
          ..result = {'error': 'Needs $names. Download it in Models.', 'missing_models': missing};
        return step;
      }
      if (!await _approve(skill, call.arguments)) {
        step
          ..status = StepStatus.declined
          ..result = {'error': 'The user declined this action.'};
        return step;
      }
      final r = await skill.run(call.arguments, _RunContext(this, step));
      step
        ..status = r.isError ? StepStatus.failed : StepStatus.done
        ..result = r.data
        ..cards = r.cards;
      unawaited(services.ledger.record('skill', '${skill.name}${r.isError ? ' (failed)' : ''}'));
      return step;
    } catch (e) {
      step
        ..status = StepStatus.failed
        ..result = {'error': '$e'};
      return step;
    } finally {
      step
        ..ms = DateTime.now().difference(started).inMilliseconds
        ..progress = null;
      notifyListeners();
    }
  }

  Future<bool> _approve(Skill skill, Map<String, dynamic> args) async {
    final settings = services.settings;
    final needs = switch (skill.confirm) {
      ConfirmPolicy.never => false,
      ConfirmPolicy.firstTime => !settings.grantedSkills.contains(skill.id),
      ConfirmPolicy.always => true,
    };
    if (!needs) return true;
    final ok = await (onConfirm?.call(skill, args) ?? Future.value(false));
    if (ok && skill.confirm == ConfirmPolicy.firstTime) {
      await settings.update((s) => s.grantedSkills.add(skill.id));
    }
    return ok;
  }
}

class _RunContext implements SkillContext {
  _RunContext(this.c, this.step);

  final ChatController c;
  final AgentStep step;
  AppServices get s => c.services;

  @override
  String get platform => s.platform;

  @override
  bool get isDemo => s.isDemo;

  @override
  List<Attachment> get attachments => c.allAttachments;

  @override
  Attachment? attachment(Object? ref) {
    final all = attachments;
    if (all.isEmpty) return null;
    final r = '${ref ?? ''}'.trim();
    for (final a in all.reversed) {
      if (a.id == r || a.name == r || a.path == r) return a;
    }
    // Small models often omit the id when there is only one candidate.
    return r.isEmpty || all.length == 1 ? all.last : null;
  }

  @override
  Future<String> ask({required String system, required String prompt, List<String> imagePaths = const [], List<String> audioPaths = const []}) async {
    if (!s.isDemo && !await s.models.ensurePlanner()) {
      throw StateError('Download ${modelById(s.settings.plannerId)?.name ?? 'Gemma'} in Models first.');
    }
    final session = 'sub-${_uuid.v4()}';
    final out = StringBuffer();
    String? error;
    await for (final e in s.llm.generate(GenerationRequest(
      modelId: s.settings.plannerId,
      sessionId: session,
      systemPrompt: system,
      history: [EngineTurn(role: TurnRole.user, text: prompt, imagePaths: imagePaths, audioPaths: audioPaths)],
      sampler: const SamplerSettings(temperature: 0.3, maxTokens: 1024),
    ))) {
      if (e is TokenEvent) out.write(e.text);
      if (e is ErrorEvent) error = e.message;
    }
    await s.llm.resetSession(session);
    if (error != null) throw StateError(error);
    return out.toString().trim();
  }

  @override
  Future<Map<String, dynamic>> specialist(String modelId, String task, Map<String, dynamic> input) =>
      s.specialists.run(modelId, task, input);

  @override
  Future<Map<String, dynamic>> device(String action, Map<String, dynamic> args) => s.device.invoke(action, args);

  @override
  Future<List<Map<String, dynamic>>> searchKnowledge(String query, {int limit = 5}) =>
      s.knowledge.search(query, limit: limit);

  @override
  Future<int> addKnowledge(String title, String text, {String source = 'chat'}) =>
      s.knowledge.add(title, text, source: source);

  @override
  Future<void> remember(String fact) => s.memory.add(fact);

  @override
  Future<List<String>> recall(String query) async => s.memory.recall(query);

  @override
  Future<bool> forget(String fact) => s.memory.forget(fact);

  @override
  Future<SkillResult> callSkill(String id, Map<String, dynamic> args) async {
    final skill = s.skills.byId(id);
    if (skill == null) return SkillResult.error('No skill $id');
    if (!await c._approve(skill, args)) return SkillResult.error('Declined');
    return skill.run(args, this);
  }

  @override
  Future<String?> saveTextFile(String name, String content) => writeTextFile(s.store.filesDir, name, content);

  @override
  void progress(String message) {
    step.progress = message;
    c.refresh();
  }
}
