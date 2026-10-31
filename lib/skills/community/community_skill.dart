import '../builtin/json_extract.dart';
import '../recipes/recipe.dart';
import '../skill.dart';

/// Community skills are declarative JSON: a prompt template run by Gemma, or
/// a chain of existing skills. They cannot ship code, so installing one can
/// never grant more than the skills it calls (each keeps its own permission
/// gate). Schema: docs/COMMUNITY_SKILLS.md.
class CommunitySkill extends Skill {
  CommunitySkill(this.manifest, {this.sourceUrl});

  static const schema = 'phonedots.skill/v1';
  static final _idPattern = RegExp(r'^[a-z][a-z0-9_]{2,40}$');

  final Map<String, dynamic> manifest;
  final String? sourceUrl;

  /// Throws [FormatException] when the manifest is invalid.
  static CommunitySkill parse(Map<String, dynamic> j, {String? sourceUrl}) {
    if (j['schema'] != schema) throw const FormatException('Unknown schema; expected $schema');
    final id = j['id'];
    if (id is! String || !_idPattern.hasMatch(id)) {
      throw const FormatException('id must be lower_snake_case, 3-41 characters');
    }
    if (j['name'] is! String || j['description'] is! String) {
      throw const FormatException('name and description are required');
    }
    for (final key in const ['author', 'version']) {
      if (j[key] != null && j[key] is! String) throw FormatException('"$key" must be text');
    }
    final examples = j['examples'];
    if (examples != null && (examples is! List || examples.any((e) => e is! String))) {
      throw const FormatException('"examples" must be a list of text');
    }
    final hasPrompt = j['prompt'] is Map && (j['prompt'] as Map)['user'] is String;
    final hasSteps = j['steps'] is List;
    if (hasPrompt == hasSteps) throw const FormatException('Provide exactly one of "prompt" or "steps"');
    if (hasSteps) {
      final steps = j['steps'] as List;
      if (steps.isEmpty) throw const FormatException('"steps" needs at least one step');
      for (final st in steps) {
        if (st is! Map || st['skill'] is! String || (st['skill'] as String).isEmpty) {
          throw const FormatException('Each step needs a "skill"');
        }
        if (st['args'] != null && st['args'] is! Map) throw const FormatException('A step\'s "args" must be an object');
        // A chain that calls itself would never finish.
        if (st['skill'] == 'c_$id') throw const FormatException('A chain cannot call itself');
      }
    }
    final params = j['params'];
    if (params != null && params is! List) throw const FormatException('"params" must be a list');
    final names = <String>{};
    for (final p in (params as List? ?? const [])) {
      if (p is! Map || p['name'] is! String) throw const FormatException('Each param needs a name');
      if (!names.add(p['name'] as String)) throw FormatException('Param "${p['name']}" is listed twice');
      if (p['description'] != null && p['description'] is! String) {
        throw const FormatException('A param\'s "description" must be text');
      }
      if (p['required'] != null && p['required'] is! bool) {
        throw const FormatException('A param\'s "required" must be true or false');
      }
    }
    return CommunitySkill(j, sourceUrl: sourceUrl);
  }

  @override
  String get id => 'c_${manifest['id']}';
  @override
  String get name => manifest['name'] as String;
  @override
  String get description => manifest['description'] as String;
  @override
  SkillKind get kind => SkillKind.community;
  @override
  SkillCategory get category => SkillCategory.community;
  String get author => manifest['author'] as String? ?? 'Unknown';
  String get version => manifest['version'] as String? ?? '1.0';

  @override
  List<String> get examples => [for (final e in (manifest['examples'] as List? ?? const [])) '$e'];

  @override
  List<SkillParam> get params => [
    for (final p in (manifest['params'] as List? ?? const []).cast<Map>())
      SkillParam(
        p['name'] as String,
        switch (p['type']) {
          'number' => ParamType.number,
          'integer' => ParamType.integer,
          'boolean' => ParamType.boolean,
          'list' => ParamType.stringList,
          'image' || 'audio' || 'attachment' => ParamType.attachment,
          _ => ParamType.string,
        },
        p['description'] as String? ?? '',
        required: p['required'] as bool? ?? true,
      ),
  ];

  /// Skills a chain may call, shown at install time.
  List<String> get calls => [for (final s in (manifest['steps'] as List? ?? const []).cast<Map>()) '${s['skill']}'];

  @override
  Future<SkillResult> run(Map<String, dynamic> args, SkillContext ctx) async {
    String fill(String t) => t.replaceAllMapped(RegExp(r'\{\{\s*(\w+)\s*\}\}'), (m) => '${args[m.group(1)] ?? ''}');

    if (manifest['steps'] != null) {
      final recipe = Recipe.fromJson({
        'id': manifest['id'],
        'name': name,
        'description': description,
        'steps': [
          for (final s in (manifest['steps'] as List).cast<Map>())
            {
              'skill': s['skill'],
              'args': {for (final e in (s['args'] as Map? ?? const {}).entries) '${e.key}': fill('${e.value}')},
            },
        ],
      });
      return RecipeSkill(recipe).run({'input': args.values.isEmpty ? '' : '${args.values.first}'}, ctx);
    }

    final prompt = Map<String, dynamic>.from(manifest['prompt'] as Map);
    final images = [
      for (final p in params.where((p) => p.type == ParamType.attachment))
        if (ctx.attachment(args[p.name])?.kind == 'image') ctx.attachment(args[p.name])!.path,
    ];
    final out = await ctx.ask(
      system: fill(prompt['system'] as String? ?? ''),
      prompt: fill(prompt['user'] as String),
      imagePaths: images,
    );
    switch (manifest['output']) {
      case 'json':
        final j = extractJson(out) ?? {'raw': out};
        return SkillResult(
          j,
          cards: [
            UiCard('kv', title: name, data: {for (final e in j.entries) e.key: '${e.value}'}),
          ],
        );
      case 'checklist':
        final items = out
            .split('\n')
            .map((l) => l.replaceFirst(RegExp(r'^\s*([-*•]|\d+[.)])\s*'), '').trim())
            .where((l) => l.isNotEmpty)
            .toList();
        return SkillResult(
          {'items': items},
          cards: [
            UiCard('checklist', title: name, data: {'items': items}),
          ],
        );
      default:
        return SkillResult(
          {'result': out},
          cards: [
            UiCard('text', title: name, data: {'text': out, 'copy': true}),
          ],
        );
    }
  }
}

/// A few examples bundled so the store is not empty offline.
const sampleCommunitySkills = <Map<String, dynamic>>[
  {
    'schema': CommunitySkill.schema,
    'id': 'recipe_from_fridge',
    'name': 'Fridge chef',
    'author': 'PhoneDots',
    'description': 'Suggest a recipe from a photo of your fridge or a list of ingredients.',
    'params': [
      {'name': 'photo', 'type': 'image', 'description': 'Photo of the fridge.', 'required': false},
      {'name': 'ingredients', 'type': 'string', 'description': 'Ingredients on hand.', 'required': false},
    ],
    'prompt': {
      'system':
          'You are a practical home cook. Suggest one recipe using mostly what is available. '
          'Give a title, a time estimate, ingredients and numbered steps.',
      'user': 'Ingredients: {{ingredients}}',
    },
    'output': 'text',
    'examples': ['What can I cook with this?'],
  },
  {
    'schema': CommunitySkill.schema,
    'id': 'explain_like_five',
    'name': 'Explain simply',
    'author': 'PhoneDots',
    'description': 'Explain a concept in plain words a ten-year-old would follow.',
    'params': [
      {'name': 'topic', 'type': 'string', 'description': 'What to explain.'},
    ],
    'prompt': {
      'system': 'Explain in at most 5 short sentences with one everyday analogy. No jargon.',
      'user': 'Explain: {{topic}}',
    },
    'output': 'text',
  },
  {
    'schema': CommunitySkill.schema,
    'id': 'packing_list',
    'name': 'Packing list',
    'author': 'PhoneDots',
    'description': 'Build a packing checklist for a trip.',
    'params': [
      {'name': 'trip', 'type': 'string', 'description': 'Destination, length and activities.'},
    ],
    'prompt': {
      'system': 'Write a packing list, one item per line, no headings, at most 25 items.',
      'user': 'Trip: {{trip}}',
    },
    'output': 'checklist',
  },
];
