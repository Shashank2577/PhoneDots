import '../skill.dart';
import 'json_extract.dart';

const _text = SkillParam('text', ParamType.string, 'The text to work on.');

FnSkill _gemmaText({
  required String id,
  required String name,
  required String description,
  required String system,
  List<SkillParam> extra = const [],
  List<String> examples = const [],
  String Function(Map<String, dynamic> args)? systemFor,
}) =>
    FnSkill(
      id: id,
      name: name,
      description: description,
      kind: SkillKind.text,
      category: SkillCategory.text,
      params: [_text, ...extra],
      examples: examples,
      handler: (args, ctx) async {
        final out = await ctx.ask(system: systemFor?.call(args) ?? system, prompt: args.str('text'));
        return SkillResult({'result': out}, cards: [UiCard('text', title: name, data: {'text': out, 'copy': true})]);
      },
    );

List<Skill> textSkills() => [
      _gemmaText(
        id: 'summarize',
        name: 'Summarize',
        description: 'Summarize text into short bullet points.',
        system: 'Summarize the text in at most 5 short bullet points. Output only the bullets.',
        examples: const ['Summarize this article'],
      ),
      _gemmaText(
        id: 'rewrite',
        name: 'Rewrite',
        description: 'Rewrite text in a different tone (friendly, formal, concise, confident, playful).',
        system: '',
        extra: const [SkillParam('tone', ParamType.string, 'Target tone, e.g. formal or friendly.', required: false)],
        systemFor: (a) => 'Rewrite the text in a ${a.str('tone', 'clear')} tone. Keep the meaning. Output only the rewrite.',
      ),
      _gemmaText(
        id: 'translate',
        name: 'Translate',
        description: 'Translate text into another language.',
        system: '',
        extra: const [SkillParam('language', ParamType.string, 'Target language, e.g. Spanish.')],
        systemFor: (a) => 'Translate the text into ${a.str('language', 'English')}. Output only the translation.',
        examples: const ['Translate this to Spanish'],
      ),
      _gemmaText(
        id: 'proofread',
        name: 'Proofread',
        description: 'Fix spelling, grammar and punctuation without changing the style.',
        system: 'Correct spelling, grammar and punctuation. Keep the style. Output only the corrected text.',
      ),
      _gemmaText(
        id: 'draft_reply',
        name: 'Draft a reply',
        description: 'Draft a reply to a message or email, following optional instructions.',
        system: '',
        extra: const [SkillParam('instructions', ParamType.string, 'What the reply should say.', required: false)],
        systemFor: (a) => 'Draft a short reply to the message. ${a.str('instructions')} Output only the reply.',
      ),
      _gemmaText(
        id: 'check_tone',
        name: 'Check tone',
        description: 'Judge how a message will come across (tone, clarity, risk of offence) and suggest fixes.',
        system: 'Assess the tone of the message in 2 sentences, then list up to 3 concrete improvements.',
      ),
      FnSkill(
        id: 'extract_fields',
        name: 'Extract fields',
        description: 'Pull structured fields (e.g. name, date, amount, address) out of text as JSON.',
        kind: SkillKind.text,
        category: SkillCategory.text,
        params: const [
          _text,
          SkillParam('fields', ParamType.stringList, 'Field names to extract.'),
        ],
        handler: (args, ctx) async {
          final fields = args.strings('fields');
          final raw = await ctx.ask(
            system: 'Extract these fields from the text: ${fields.join(', ')}. '
                'Reply with a single JSON object using exactly those keys; use null when missing.',
            prompt: args.str('text'),
          );
          final r = extractJson(raw) ?? {'raw': raw};
          return SkillResult(r, cards: [
            UiCard('kv', title: 'Extracted', data: {for (final e in r.entries) e.key: '${e.value ?? '—'}'}),
          ]);
        },
      ),
      FnSkill(
        id: 'redact_pii',
        name: 'Redact personal info',
        description: 'Replace names, emails, phone numbers, addresses, card numbers and other PII with placeholders (Redact).',
        kind: SkillKind.model,
        category: SkillCategory.text,
        params: const [_text],
        requiresModels: const ['desertant.redact'],
        examples: const ['Redact this before I share it'],
        handler: (args, ctx) async {
          final r = await ctx.specialist('desertant.redact', 'redact', {'text': args.str('text')});
          if (r['error'] != null) return SkillResult.error('${r['error']}');
          final items = (r['items'] as List? ?? const []).cast<Map>();
          return SkillResult({
            'redacted_text': r['redactedText'],
            'found': items.length,
            'summary': 'Redacted ${items.length} item${items.length == 1 ? '' : 's'}:\n\n${r['redactedText']}',
          }, cards: [
            UiCard('text', title: 'Redacted', data: {'text': r['redactedText'], 'copy': true}),
            if (items.isNotEmpty)
              UiCard('table', title: 'Found', data: {
                'columns': ['Type', 'Placeholder'],
                'rows': [
                  for (final i in items) ['${i['label']}', '${i['placeholder']}'],
                ],
              }),
          ]);
        },
      ),
      FnSkill(
        id: 'detect_language',
        name: 'Detect language',
        description: 'Identify the language of a short piece of text (84 languages, Tongue).',
        kind: SkillKind.model,
        category: SkillCategory.text,
        params: const [_text],
        requiresModels: const ['desertant.tongue'],
        handler: (args, ctx) async {
          final r = await ctx.specialist('desertant.tongue', 'detect', {'text': args.str('text')});
          if (r['error'] != null) return SkillResult.error('${r['error']}');
          return SkillResult({'language': r['language'], 'confidence': r['confidence']});
        },
      ),
      FnSkill(
        id: 'suggest_emoji',
        name: 'Suggest emoji',
        description: 'Suggest emoji that fit a message (Emo).',
        kind: SkillKind.model,
        category: SkillCategory.text,
        params: const [_text],
        requiresModels: const ['desertant.emo'],
        handler: (args, ctx) async {
          final r = await ctx.specialist('desertant.emo', 'suggest', {'text': args.str('text'), 'limit': 5});
          if (r['error'] != null) return SkillResult.error('${r['error']}');
          final emoji = (r['suggestions'] as List? ?? const []).map((s) => '${(s as Map)['emoji']}').toList();
          return SkillResult({'emoji': emoji, 'summary': emoji.join(' ')}, cards: [
            UiCard('tags', title: 'Emoji', data: {'tags': emoji, 'large': true}),
          ]);
        },
      ),
      FnSkill(
        id: 'classify_topics',
        name: 'Topics & tags',
        description: 'Tag text with topics from a 36-topic taxonomy (Gist).',
        kind: SkillKind.model,
        category: SkillCategory.text,
        params: const [_text],
        requiresModels: const ['desertant.gist'],
        handler: (args, ctx) async {
          final r = await ctx.specialist('desertant.gist', 'classify', {'text': args.str('text')});
          if (r['error'] != null) return SkillResult.error('${r['error']}');
          final topics = (r['topics'] as List? ?? const []).cast<Map>();
          return SkillResult({'topics': topics.map((t) => t['name']).toList()}, cards: [
            UiCard('tags', title: 'Topics', data: {'tags': topics.map((t) => '${t['name']}').toList()}),
          ]);
        },
      ),
      FnSkill(
        id: 'suggest_title',
        name: 'Suggest a title',
        description: 'Write a short factual title and a one-sentence description for a passage.',
        kind: SkillKind.text,
        category: SkillCategory.text,
        params: const [_text],
        handler: (args, ctx) async {
          Map<String, dynamic>? r;
          if (ctx.platform == 'ios') {
            r = await ctx.specialist('desertant.title', 'describe', {'text': args.str('text')});
            if (r['error'] != null) r = null;
          }
          r ??= extractJson(await ctx.ask(
            system: 'Reply with JSON only: {"title": string (max 8 words), "description": string (1 sentence)}',
            prompt: args.str('text'),
          ));
          if (r == null) return SkillResult.error('Could not write a title.');
          return SkillResult(r, cards: [
            UiCard('kv', title: 'Title', data: {'Title': '${r['title']}', 'Description': '${r['description']}'}),
          ]);
        },
      ),
    ];
