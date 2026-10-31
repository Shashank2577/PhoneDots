import 'dart:async';

import '../skill.dart';

class RecipeStep {
  const RecipeStep(this.skillId, this.args);

  final String skillId;

  /// Values may use {{input}}, {{prev.field}} or {{steps.N.field}}.
  final Map<String, String> args;

  Map<String, dynamic> toJson() => {'skill': skillId, 'args': args};

  factory RecipeStep.fromJson(Map<String, dynamic> j) =>
      RecipeStep(j['skill'] as String, Map<String, String>.from(j['args'] as Map? ?? const {}));
}

/// A saved chain of skills that is itself exposed as a skill.
class Recipe {
  const Recipe({
    required this.id,
    required this.name,
    required this.description,
    required this.steps,
    this.input = 'text',
    this.builtIn = false,
  });

  final String id;
  final String name;
  final String description;

  /// text | audio | image | none
  final String input;
  final List<RecipeStep> steps;
  final bool builtIn;

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'description': description,
    'input': input,
    'steps': steps.map((s) => s.toJson()).toList(),
  };

  factory Recipe.fromJson(Map<String, dynamic> j, {bool builtIn = false}) => Recipe(
    id: j['id'] as String,
    name: j['name'] as String,
    description: j['description'] as String? ?? '',
    input: j['input'] as String? ?? 'text',
    steps: (j['steps'] as List).map((s) => RecipeStep.fromJson(Map<String, dynamic>.from(s as Map))).toList(),
    builtIn: builtIn,
  );

  Recipe copyWith({String? name, String? description, String? input, List<RecipeStep>? steps}) => Recipe(
    id: id,
    name: name ?? this.name,
    description: description ?? this.description,
    input: input ?? this.input,
    steps: steps ?? this.steps,
  );
}

/// Fills {{...}} placeholders from the run state.
String fillTemplate(String template, String input, List<Map<String, dynamic>> results) {
  return template.replaceAllMapped(RegExp(r'\{\{\s*([\w.-]+)\s*\}\}'), (m) {
    final path = m.group(1)!.split('.');
    if (path.first == 'input') return input;
    Map<String, dynamic>? source;
    var rest = path.skip(1);
    if (path.first == 'prev') {
      source = results.isEmpty ? null : results.last;
    } else if (path.first == 'steps' && path.length > 1) {
      final i = int.tryParse(path[1]);
      source = i != null && i >= 1 && i <= results.length ? results[i - 1] : null;
      rest = path.skip(2);
    }
    Object? value = source;
    for (final key in rest) {
      value = value is Map ? value[key] : null;
    }
    if (value == null) return '';
    if (value is List) return value.join('\n');
    return '$value';
  });
}

class RecipeSkill extends Skill {
  RecipeSkill(this.recipe);

  final Recipe recipe;

  @override
  String get id => 'recipe_${recipe.id}';
  @override
  String get name => recipe.name;
  @override
  String get description => 'Recipe: ${recipe.description}';
  @override
  SkillKind get kind => SkillKind.recipe;
  @override
  SkillCategory get category => SkillCategory.recipes;

  @override
  List<SkillParam> get params => switch (recipe.input) {
    'audio' => const [SkillParam('input', ParamType.attachment, 'The audio recording.')],
    'image' => const [SkillParam('input', ParamType.attachment, 'The image.')],
    'none' => const [],
    _ => const [SkillParam('input', ParamType.string, 'The text to start from.')],
  };

  /// Recipes may call other recipes, but not without end (a recipe that
  /// calls itself, directly or through another).
  static const maxNesting = 4;
  static const _depthKey = #phonedotsRecipeDepth;

  @override
  Future<SkillResult> run(Map<String, dynamic> args, SkillContext ctx) async {
    final depth = (Zone.current[_depthKey] as int?) ?? 0;
    if (depth >= maxNesting || recipe.steps.any((s) => s.skillId == id) && depth > 0) {
      return SkillResult.error('"${recipe.name}" calls itself (or nests recipes more than $maxNesting deep).');
    }
    return runZoned(() => _run(args, ctx), zoneValues: {_depthKey: depth + 1});
  }

  Future<SkillResult> _run(Map<String, dynamic> args, SkillContext ctx) async {
    final input = args.str('input');
    final results = <Map<String, dynamic>>[];
    final cards = <UiCard>[];
    for (var i = 0; i < recipe.steps.length; i++) {
      final step = recipe.steps[i];
      ctx.progress('Step ${i + 1}/${recipe.steps.length}: ${step.skillId}');
      final filled = {for (final e in step.args.entries) e.key: fillTemplate(e.value, input, results)};
      final r = await ctx.callSkill(step.skillId, filled);
      if (r.isError) return SkillResult.error('Step ${i + 1} (${step.skillId}) failed: ${r.data['error']}');
      results.add(r.data);
      cards.addAll(r.cards);
    }
    final last = results.isEmpty ? <String, dynamic>{} : results.last;
    return SkillResult({
      'summary': 'Ran "${recipe.name}" (${recipe.steps.length} steps).',
      'result': last,
    }, cards: cards);
  }
}

const builtInRecipes = <Recipe>[
  Recipe(
    id: 'private_share',
    name: 'Private share',
    description: 'Redact personal info from text, then copy the safe version.',
    builtIn: true,
    steps: [
      RecipeStep('redact_pii', {'text': '{{input}}'}),
      RecipeStep('copy_to_clipboard', {'text': '{{prev.redacted_text}}'}),
    ],
  ),
  Recipe(
    id: 'voice_memo_note',
    name: 'Voice memo to note',
    description: 'Transcribe a voice memo, summarize it and save it as a searchable note.',
    input: 'audio',
    builtIn: true,
    steps: [
      RecipeStep('transcribe_audio', {'audio': '{{input}}'}),
      RecipeStep('summarize', {'text': '{{prev.text}}'}),
      RecipeStep('save_note', {'title': 'Voice memo', 'content': '{{prev.result}}\n\n---\n{{steps.1.text}}'}),
    ],
  ),
  Recipe(
    id: 'post_kit',
    name: 'Post kit',
    description: 'Title, topics and emoji for a post or caption.',
    builtIn: true,
    steps: [
      RecipeStep('suggest_title', {'text': '{{input}}'}),
      RecipeStep('classify_topics', {'text': '{{input}}'}),
      RecipeStep('suggest_emoji', {'text': '{{input}}'}),
    ],
  ),
  Recipe(
    id: 'translate_share',
    name: 'Translate & share',
    description: 'Translate text to Spanish and open the share sheet.',
    builtIn: true,
    steps: [
      RecipeStep('translate', {'text': '{{input}}', 'language': 'Spanish'}),
      RecipeStep('share_text', {'text': '{{prev.result}}'}),
    ],
  ),
  Recipe(
    id: 'document_digest',
    name: 'Document digest',
    description: 'Read a photographed document, summarize it and save it to your files.',
    input: 'image',
    builtIn: true,
    steps: [
      RecipeStep('read_text_in_image', {'image': '{{input}}'}),
      RecipeStep('summarize', {'text': '{{prev.text}}'}),
      RecipeStep('add_to_knowledge', {'title': 'Scanned document', 'text': '{{steps.1.text}}'}),
    ],
  ),
];
