import 'package:flutter/foundation.dart';

import '../core/runtime/engine_types.dart';
import '../core/storage/json_store.dart';
import '../skills/skill.dart';

enum StepStatus { running, done, failed, declined }

/// One skill call, shown inline in the chat and in the trace.
class AgentStep {
  AgentStep({
    required this.skillId,
    required this.skillName,
    required this.args,
    this.via = 'planner',
    this.status = StepStatus.running,
    this.progress,
    this.result = const {},
    this.cards = const [],
    this.ms = 0,
  });

  final String skillId;
  final String skillName;
  final Map<String, dynamic> args;

  /// router | planner | recipe
  final String via;
  StepStatus status;
  String? progress;
  Map<String, dynamic> result;
  List<UiCard> cards;
  int ms;

  Map<String, dynamic> toJson() => {
    'skillId': skillId,
    'skillName': skillName,
    'args': args,
    'via': via,
    'status': status.name,
    'result': result,
    'cards': cards.map((c) => c.toJson()).toList(),
    'ms': ms,
  };

  factory AgentStep.fromJson(Map<String, dynamic> j) => AgentStep(
    skillId: j['skillId'] as String,
    skillName: j['skillName'] as String,
    args: Map<String, dynamic>.from(j['args'] as Map),
    via: j['via'] as String? ?? 'planner',
    status: StepStatus.values.byName(j['status'] as String),
    result: Map<String, dynamic>.from(j['result'] as Map? ?? const {}),
    cards: (j['cards'] as List? ?? const []).map((c) => UiCard.fromJson(Map<String, dynamic>.from(c as Map))).toList(),
    ms: j['ms'] as int? ?? 0,
  );
}

class ChatMessage {
  ChatMessage({
    required this.id,
    required this.isUser,
    this.text = '',
    this.thinking = '',
    this.attachments = const [],
    List<AgentStep>? steps,
    List<EngineTurn>? turns,
    DateTime? created,
    this.modelId,
    this.stats,
    this.error,
    this.streaming = false,
  }) : steps = steps ?? [],
       turns = turns ?? [],
       created = created ?? DateTime.now();

  final String id;
  final bool isUser;
  String text;
  String thinking;
  final List<Attachment> attachments;
  final List<AgentStep> steps;

  /// The exact engine transcript for an assistant reply (tool calls, tool
  /// responses, final text), so later turns replay it faithfully.
  final List<EngineTurn> turns;
  final DateTime created;
  String? modelId;
  GenerationStats? stats;
  String? error;
  bool streaming;

  List<UiCard> get cards => [for (final s in steps) ...s.cards];

  Map<String, dynamic> toJson() => {
    'id': id,
    'user': isUser,
    'text': text,
    'thinking': thinking,
    'attachments': attachments.map((a) => a.toJson()).toList(),
    'steps': steps.map((s) => s.toJson()).toList(),
    'turns': turns.map((t) => t.toJson()).toList(),
    'created': created.toIso8601String(),
    'modelId': modelId,
    if (stats != null)
      'stats': {
        'ttftMs': stats!.timeToFirstTokenMs,
        'totalMs': stats!.totalMs,
        'outputTokens': stats!.outputTokens,
        'decodeTps': stats!.decodeTokensPerSec,
      },
    'error': error,
  };

  factory ChatMessage.fromJson(Map<String, dynamic> j) => ChatMessage(
    id: j['id'] as String,
    isUser: j['user'] as bool,
    text: j['text'] as String? ?? '',
    thinking: j['thinking'] as String? ?? '',
    attachments: (j['attachments'] as List? ?? const [])
        .map((a) => Attachment.fromJson(Map<String, dynamic>.from(a as Map)))
        .toList(),
    steps: (j['steps'] as List? ?? const [])
        .map((s) => AgentStep.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList(),
    turns: (j['turns'] as List? ?? const [])
        .map((t) => EngineTurn.fromJson(Map<String, dynamic>.from(t as Map)))
        .toList(),
    created: DateTime.parse(j['created'] as String),
    modelId: j['modelId'] as String?,
    stats: j['stats'] == null ? null : GenerationStats.fromJson(Map<String, dynamic>.from(j['stats'] as Map)),
    error: j['error'] as String?,
  );
}

class Conversation {
  Conversation({required this.id, this.title = 'New chat', DateTime? updated, List<ChatMessage>? messages})
    : updated = updated ?? DateTime.now(),
      messages = messages ?? [];

  final String id;
  String title;
  DateTime updated;
  final List<ChatMessage> messages;

  Map<String, dynamic> toJson() => {
    'id': id,
    'title': title,
    'updated': updated.toIso8601String(),
    'messages': messages.map((m) => m.toJson()).toList(),
  };

  factory Conversation.fromJson(Map<String, dynamic> j) => Conversation(
    id: j['id'] as String,
    title: j['title'] as String,
    updated: DateTime.parse(j['updated'] as String),
    messages: (j['messages'] as List).map((m) => ChatMessage.fromJson(Map<String, dynamic>.from(m as Map))).toList(),
  );
}

class ConversationSummary {
  const ConversationSummary(this.id, this.title, this.updated);
  final String id;
  final String title;
  final DateTime updated;
}

class ConversationStore extends ChangeNotifier {
  ConversationStore(this._store);

  final JsonStore _store;
  static const _index = 'conversations';
  final List<ConversationSummary> summaries = [];

  Future<void> load() async {
    final raw = (await _store.read(_index) as List?) ?? const [];
    summaries
      ..clear()
      ..addAll(
        raw.map((e) {
          final m = Map<String, dynamic>.from(e as Map);
          return ConversationSummary(m['id'] as String, m['title'] as String, DateTime.parse(m['updated'] as String));
        }),
      );
    notifyListeners();
  }

  Future<Conversation?> open(String id) async {
    final j = await _store.read('conv/$id') as Map?;
    return j == null ? null : Conversation.fromJson(Map<String, dynamic>.from(j));
  }

  Future<void> save(Conversation c) async {
    if (c.messages.isEmpty) return;
    c.updated = DateTime.now();
    await _store.write('conv/${c.id}', c.toJson());
    summaries
      ..removeWhere((s) => s.id == c.id)
      ..insert(0, ConversationSummary(c.id, c.title, c.updated));
    await _writeIndex();
  }

  Future<void> delete(String id) async {
    await _store.delete('conv/$id');
    summaries.removeWhere((s) => s.id == id);
    await _writeIndex();
  }

  Future<void> deleteAll() async {
    for (final s in [...summaries]) {
      await _store.delete('conv/${s.id}');
    }
    summaries.clear();
    await _writeIndex();
  }

  Future<void> _writeIndex() async {
    notifyListeners();
    await _store.write(_index, [
      for (final s in summaries) {'id': s.id, 'title': s.title, 'updated': s.updated.toIso8601String()},
    ]);
  }
}
