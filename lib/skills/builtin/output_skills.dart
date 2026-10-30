import '../skill.dart';

/// UI skills: the model chooses how to present an answer as a card instead
/// of plain text.
List<Skill> outputSkills() => [
      FnSkill(
        id: 'show_table',
        name: 'Show a table',
        description: 'Present structured data as a table. Each row is cells separated by " | ".',
        kind: SkillKind.ui,
        category: SkillCategory.output,
        params: const [
          SkillParam('title', ParamType.string, 'Table title.'),
          SkillParam('columns', ParamType.stringList, 'Column headers.'),
          SkillParam('rows', ParamType.stringList, 'Rows, cells separated by " | ".'),
        ],
        handler: (args, ctx) async {
          final columns = args.strings('columns');
          final rows = [
            for (final r in args.strings('rows')) r.split('|').map((c) => c.trim()).toList(),
          ];
          return SkillResult({'shown': true, 'rows': rows.length},
              cards: [UiCard('table', title: args.str('title'), data: {'columns': columns, 'rows': rows})]);
        },
      ),
      FnSkill(
        id: 'show_checklist',
        name: 'Show a checklist',
        description: 'Present steps or to-dos as a tickable checklist.',
        kind: SkillKind.ui,
        category: SkillCategory.output,
        params: const [
          SkillParam('title', ParamType.string, 'Checklist title.'),
          SkillParam('items', ParamType.stringList, 'Items.'),
        ],
        examples: const ['Make me a packing checklist'],
        handler: (args, ctx) async => SkillResult({'shown': true},
            cards: [UiCard('checklist', title: args.str('title'), data: {'items': args.strings('items')})]),
      ),
      FnSkill(
        id: 'show_chart',
        name: 'Show a chart',
        description: 'Present numbers as a bar chart.',
        kind: SkillKind.ui,
        category: SkillCategory.output,
        params: const [
          SkillParam('title', ParamType.string, 'Chart title.'),
          SkillParam('labels', ParamType.stringList, 'Bar labels.'),
          SkillParam('values', ParamType.stringList, 'Numeric values, same order as labels.'),
        ],
        handler: (args, ctx) async {
          final values = args.strings('values').map((v) => double.tryParse(v.replaceAll(RegExp(r'[^\d.\-]'), '')) ?? 0).toList();
          return SkillResult({'shown': true},
              cards: [UiCard('bars', title: args.str('title'), data: {'labels': args.strings('labels'), 'values': values})]);
        },
      ),
      FnSkill(
        id: 'show_timeline',
        name: 'Show a timeline',
        description: 'Present a schedule or sequence of events. Each item is "time — text".',
        kind: SkillKind.ui,
        category: SkillCategory.output,
        params: const [
          SkillParam('title', ParamType.string, 'Timeline title.'),
          SkillParam('items', ParamType.stringList, 'Items as "time — text".'),
        ],
        handler: (args, ctx) async {
          final items = [
            for (final i in args.strings('items'))
              () {
                final parts = i.split(RegExp(r'\s+[—–-]\s+'));
                return {'time': parts.first, 'text': parts.length > 1 ? parts.sublist(1).join(' — ') : ''};
              }(),
          ];
          return SkillResult({'shown': true}, cards: [UiCard('timeline', title: args.str('title'), data: {'items': items})]);
        },
      ),
      FnSkill(
        id: 'save_note',
        name: 'Save a note',
        description: 'Save text as a note file and add it to the searchable knowledge base.',
        kind: SkillKind.ui,
        category: SkillCategory.output,
        params: const [
          SkillParam('title', ParamType.string, 'Note title.'),
          SkillParam('content', ParamType.string, 'Note body (markdown).'),
        ],
        handler: (args, ctx) async {
          final title = args.str('title', 'Note');
          final path = await ctx.saveTextFile('${title.replaceAll(RegExp(r'[^\w\- ]'), '')}.md', args.str('content'));
          await ctx.addKnowledge(title, args.str('content'), source: 'notes');
          return SkillResult({'summary': 'Saved note "$title".', 'path': path},
              cards: [UiCard('file', title: title, data: {'path': path, 'kind': 'document', 'preview': args.str('content')})]);
        },
      ),
    ];
