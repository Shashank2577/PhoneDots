import '../../core/util/calculator.dart';
import '../../core/util/units.dart';
import '../skill.dart';

List<Skill> knowledgeSkills() => [
  FnSkill(
    id: 'search_my_files',
    name: 'Search my files',
    description:
        'Search the user\'s saved documents, notes, transcripts and expenses. Returns matching passages with sources.',
    kind: SkillKind.knowledge,
    category: SkillCategory.knowledge,
    params: const [SkillParam('query', ParamType.string, 'What to look for.')],
    examples: const ['What did the landlord say about the deposit?'],
    handler: (args, ctx) async {
      final hits = await ctx.searchKnowledge(args.str('query'));
      if (hits.isEmpty) return const SkillResult({'results': [], 'summary': 'Nothing in your files matches that.'});
      return SkillResult(
        {
          'results': [
            for (final h in hits) {'source': h['title'], 'passage': h['text']},
          ],
        },
        cards: [
          UiCard(
            'table',
            title: 'Sources',
            data: {
              'columns': ['Source', 'Match'],
              'rows': [
                for (final h in hits) ['${h['title']}', '${((h['score'] as num) * 100).round()}%'],
              ],
            },
          ),
        ],
      );
    },
  ),
  FnSkill(
    id: 'add_to_knowledge',
    examples: const ['Save this to my files'],
    name: 'Save to my files',
    description: 'Save text or an attached document into the searchable personal knowledge base.',
    kind: SkillKind.knowledge,
    category: SkillCategory.knowledge,
    params: const [
      SkillParam('title', ParamType.string, 'A short title.'),
      SkillParam('text', ParamType.string, 'Text to save. Omit when saving an attachment.', required: false),
      SkillParam('document', ParamType.attachment, 'A text document to save.', required: false),
    ],
    handler: (args, ctx) async {
      var text = args.str('text');
      final doc = ctx.attachment(args['document']);
      if (text.isEmpty && doc != null) {
        final r = await ctx.device('file.readText', {'path': doc.path});
        text = '${r['text'] ?? ''}';
      }
      if (text.trim().isEmpty) return SkillResult.error('Nothing to save.');
      final chunks = await ctx.addKnowledge(args.str('title', 'Note'), text);
      return SkillResult({'summary': 'Saved "${args.str('title', 'Note')}" ($chunks passages).'});
    },
  ),
  FnSkill(
    id: 'remember_fact',
    name: 'Remember',
    description: 'Remember a fact or preference about the user for future conversations.',
    kind: SkillKind.knowledge,
    category: SkillCategory.knowledge,
    params: const [
      SkillParam('fact', ParamType.string, 'The fact, phrased in third person, e.g. "Prefers metric units".'),
    ],
    examples: const ['Remember that I am vegetarian'],
    handler: (args, ctx) async {
      final fact = args.str('fact').trim();
      if (fact.isEmpty) return SkillResult.error('There is nothing to remember: the fact is empty.');
      await ctx.remember(fact);
      return SkillResult({'summary': 'Got it. I will remember: $fact'});
    },
  ),
  FnSkill(
    id: 'recall_memory',
    examples: const ['What do you remember about my diet?'],
    name: 'Recall',
    description: 'Look up what the user previously asked to be remembered.',
    kind: SkillKind.knowledge,
    category: SkillCategory.knowledge,
    params: const [SkillParam('query', ParamType.string, 'Topic to recall.')],
    handler: (args, ctx) async {
      final facts = await ctx.recall(args.str('query'));
      return SkillResult({
        'facts': facts,
        'summary': facts.isEmpty ? 'I have nothing saved about that.' : facts.map((f) => '- $f').join('\n'),
      });
    },
  ),
  FnSkill(
    id: 'forget_memory',
    examples: const ['Forget that I live in Leeds'],
    name: 'Forget',
    description: 'Delete a remembered fact.',
    kind: SkillKind.knowledge,
    category: SkillCategory.knowledge,
    params: const [SkillParam('fact', ParamType.string, 'The fact to forget.')],
    handler: (args, ctx) async {
      final ok = await ctx.forget(args.str('fact'));
      return SkillResult({'summary': ok ? 'Forgotten.' : 'I could not find that memory.'});
    },
  ),
  FnSkill(
    id: 'calculate',
    name: 'Calculate',
    description: 'Evaluate an arithmetic expression exactly. Use for any maths instead of guessing. Supports + - * / ^ % sqrt sin cos log.',
    kind: SkillKind.knowledge,
    category: SkillCategory.knowledge,
    params: const [SkillParam('expression', ParamType.string, 'Expression such as (1200*0.18)+45.')],
    examples: const ['What is 18% of 2450?'],
    handler: (args, ctx) async {
      try {
        final raw = Calculator.evaluate(args.str('expression'));
        if (!raw.isFinite) {
          return SkillResult.error('No finite answer: ${args.str('expression')} is undefined or too large.');
        }
        final v = Calculator.format(raw);
        return SkillResult({'result': v, 'summary': '${args.str('expression')} = **$v**'});
      } on FormatException catch (e) {
        return SkillResult.error('Invalid expression: ${e.message}');
      } on StackOverflowError {
        return SkillResult.error('Invalid expression: too deeply nested');
      }
    },
  ),
  FnSkill(
    id: 'convert_units',
    name: 'Convert units',
    description: 'Convert between units of length, mass, volume, speed, temperature, data and time.',
    kind: SkillKind.knowledge,
    category: SkillCategory.knowledge,
    params: const [
      SkillParam('value', ParamType.number, 'The amount.'),
      SkillParam('from', ParamType.string, 'Unit to convert from, e.g. km, lb, °F.'),
      SkillParam('to', ParamType.string, 'Unit to convert to.'),
    ],
    examples: const ['Convert 5 miles to km'],
    handler: (args, ctx) async {
      final value = num.tryParse('${args['value'] ?? ''}'.trim());
      if (value == null || !value.isFinite) return SkillResult.error('The value to convert must be a number.');
      try {
        final v = Units.convert(value.toDouble(), args.str('from'), args.str('to'));
        final out = Calculator.format(double.parse(v.toStringAsPrecision(6)));
        return SkillResult({
          'result': out,
          'summary': '${Calculator.format(args.number('value'))} ${args.str('from')} = **$out ${args.str('to')}**',
        });
      } on ArgumentError catch (e) {
        return SkillResult.error('${e.message}');
      }
    },
  ),
  FnSkill(
    id: 'date_calc',
    examples: const ['How many days until 25 December?'],
    name: 'Date maths',
    description: 'Add days to a date, or count the days between two dates.',
    kind: SkillKind.knowledge,
    category: SkillCategory.knowledge,
    params: const [
      SkillParam('start', ParamType.string, 'Start date YYYY-MM-DD; defaults to today.', required: false),
      SkillParam('add_days', ParamType.integer, 'Days to add (negative to subtract).', required: false),
      SkillParam('end', ParamType.string, 'End date YYYY-MM-DD to count days until.', required: false),
    ],
    handler: (args, ctx) async {
      // Calendar dates in UTC, so a daylight-saving change never shifts a day.
      DateTime? day(String raw) {
        final m = RegExp(r'^(\d{4})-(\d{1,2})-(\d{1,2})').firstMatch(raw.trim());
        if (m == null) return null;
        final y = int.parse(m.group(1)!), mo = int.parse(m.group(2)!), d = int.parse(m.group(3)!);
        final dt = DateTime.utc(y, mo, d);
        return dt.year == y && dt.month == mo && dt.day == d ? dt : null; // rejects 2026-02-30
      }

      final now = DateTime.now();
      final startRaw = args.str('start').trim();
      final start = startRaw.isEmpty ? DateTime.utc(now.year, now.month, now.day) : day(startRaw);
      if (start == null) return SkillResult.error('Start date must look like YYYY-MM-DD, got "$startRaw".');
      String fmt(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      const weekdays = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday', 'Sunday'];
      final endRaw = args.str('end').trim();
      if (endRaw.isNotEmpty) {
        final end = day(endRaw);
        if (end == null) return SkillResult.error('End date must look like YYYY-MM-DD, got "$endRaw".');
        final days = end.difference(start).inDays;
        return SkillResult({'days': days, 'summary': '$days days from ${fmt(start)} to ${fmt(end)}.'});
      }
      final add = args.integer('add_days');
      if (add.abs() > 3650000) return SkillResult.error('That is too many days to add (max about 10,000 years).');
      final d = start.add(Duration(days: add));
      return SkillResult({
        'date': fmt(d),
        'weekday': weekdays[d.weekday - 1],
        'summary': '${weekdays[d.weekday - 1]}, ${fmt(d)}.',
      });
    },
  ),
];
