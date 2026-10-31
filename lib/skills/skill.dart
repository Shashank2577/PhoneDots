import '../core/runtime/engine_types.dart';

enum SkillKind { model, device, knowledge, text, ui, recipe, community }

enum SkillCategory { audio, vision, text, phone, knowledge, output, recipes, community }

/// When the user must approve a call before it runs.
enum ConfirmPolicy { never, firstTime, always }

enum ParamType { string, integer, number, boolean, stringList, attachment }

class SkillParam {
  const SkillParam(this.name, this.type, this.description, {this.required = true, this.options});

  final String name;
  final ParamType type;
  final String description;
  final bool required;
  final List<String>? options;

  Map<String, dynamic> toSchema() => {
    ...switch (type) {
      ParamType.string || ParamType.attachment => {'type': 'string'},
      ParamType.integer => {'type': 'integer'},
      ParamType.number => {'type': 'number'},
      ParamType.boolean => {'type': 'boolean'},
      ParamType.stringList => {
        'type': 'array',
        'items': {'type': 'string'},
      },
    },
    'description': type == ParamType.attachment ? '$description Use an attachment id such as "a1".' : description,
    if (options != null) 'enum': options,
  };
}

/// A rich block rendered under the assistant's reply. JSON so it persists
/// with the conversation.
class UiCard {
  const UiCard(this.type, {this.title, this.data = const {}});

  /// kv | table | checklist | transcript | tags | bars | timeline | text | image | file
  final String type;
  final String? title;
  final Map<String, dynamic> data;

  Map<String, dynamic> toJson() => {'type': type, 'title': title, 'data': data};

  factory UiCard.fromJson(Map<String, dynamic> j) =>
      UiCard(j['type'] as String, title: j['title'] as String?, data: Map<String, dynamic>.from(j['data'] as Map));
}

class SkillResult {
  const SkillResult(this.data, {this.cards = const [], this.isError = false});

  factory SkillResult.error(String message) => SkillResult({'error': message}, isError: true);

  /// Sent back to the model. Keep it compact; long payloads go in [cards].
  final Map<String, dynamic> data;
  final List<UiCard> cards;
  final bool isError;
}

class Attachment {
  const Attachment({required this.id, required this.kind, required this.path, required this.name});

  final String id;

  /// image | audio | document
  final String kind;
  final String path;
  final String name;

  Map<String, dynamic> toJson() => {'id': id, 'kind': kind, 'path': path, 'name': name};

  factory Attachment.fromJson(Map<String, dynamic> j) => Attachment(
    id: j['id'] as String,
    kind: j['kind'] as String,
    path: j['path'] as String,
    name: j['name'] as String,
  );
}

abstract class Skill {
  String get id;
  String get name;
  String get description;
  SkillKind get kind;
  SkillCategory get category;
  List<SkillParam> get params => const [];

  /// Model ids that must be downloaded first.
  List<String> get requiresModels => const [];
  ConfirmPolicy get confirm => ConfirmPolicy.never;

  /// Platforms this runs on; empty means all.
  Set<String> get platforms => const {};

  /// Short phrases shown as "try" examples and used by the skill selector.
  List<String> get examples => const [];

  Future<SkillResult> run(Map<String, dynamic> args, SkillContext ctx);

  ToolSpec toToolSpec() => ToolSpec(
    name: id,
    description: description,
    parameters: {
      'type': 'object',
      'properties': {for (final p in params) p.name: p.toSchema()},
      'required': [
        for (final p in params)
          if (p.required) p.name,
      ],
    },
  );
}

/// Everything a skill may touch. Implemented by the app services so skills
/// never import Flutter or platform code directly.
abstract class SkillContext {
  String get platform;
  bool get isDemo;

  List<Attachment> get attachments;

  /// Resolves "a1", a file name or a path to an attachment.
  Attachment? attachment(Object? ref);

  /// One-shot generation with the planner model (no tools), for text skills.
  Future<String> ask({
    required String system,
    required String prompt,
    List<String> imagePaths = const [],
    List<String> audioPaths = const [],
  });

  Future<Map<String, dynamic>> specialist(String modelId, String task, Map<String, dynamic> input);

  Future<Map<String, dynamic>> device(String action, Map<String, dynamic> args);

  Future<List<Map<String, dynamic>>> searchKnowledge(String query, {int limit = 5});

  Future<int> addKnowledge(String title, String text, {String source = 'chat'});

  Future<void> remember(String fact);

  Future<List<String>> recall(String query);

  Future<bool> forget(String fact);

  /// Runs another skill (used by recipes and composite skills).
  Future<SkillResult> callSkill(String id, Map<String, dynamic> args);

  Future<String?> saveTextFile(String name, String content);

  /// Reads a link's public preview (title, author, description). Logged as network use.
  Future<Map<String, dynamic>> previewLink(String url);

  void progress(String message);
}

/// Concise declaration for most built-in skills.
class FnSkill extends Skill {
  FnSkill({
    required this.id,
    required this.name,
    required this.description,
    required this.kind,
    required this.category,
    required this.handler,
    this.params = const [],
    this.requiresModels = const [],
    this.confirm = ConfirmPolicy.never,
    this.platforms = const {},
    this.examples = const [],
  });

  @override
  final String id;
  @override
  final String name;
  @override
  final String description;
  @override
  final SkillKind kind;
  @override
  final SkillCategory category;
  @override
  final List<SkillParam> params;
  @override
  final List<String> requiresModels;
  @override
  final ConfirmPolicy confirm;
  @override
  final Set<String> platforms;
  @override
  final List<String> examples;

  final Future<SkillResult> Function(Map<String, dynamic> args, SkillContext ctx) handler;

  @override
  Future<SkillResult> run(Map<String, dynamic> args, SkillContext ctx) => handler(args, ctx);
}

extension ArgReaders on Map<String, dynamic> {
  String str(String k, [String fallback = '']) => (this[k] ?? fallback).toString();

  int integer(String k, [int fallback = 0]) {
    final v = this[k];
    if (v is num) return v.toInt();
    return int.tryParse('$v') ?? fallback;
  }

  double number(String k, [double fallback = 0]) {
    final v = this[k];
    if (v is num) return v.toDouble();
    return double.tryParse('$v') ?? fallback;
  }

  bool boolean(String k, [bool fallback = false]) {
    final v = this[k];
    if (v is bool) return v;
    if (v is String) return v.toLowerCase() == 'true';
    return fallback;
  }

  List<String> strings(String k) {
    final v = this[k];
    if (v is List) return v.map((e) => '$e').toList();
    if (v is String && v.isNotEmpty) return v.split(RegExp(r'\s*[\n;]\s*')).where((s) => s.isNotEmpty).toList();
    return const [];
  }
}
