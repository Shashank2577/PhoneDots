import '../skill.dart';

List<Skill> linkSkills() => [
  FnSkill(
    id: 'read_link',
    name: 'Read link',
    description: 'Read the public preview of a web link (YouTube, TikTok, Instagram, Threads, LinkedIn, GitHub, Medium, any site): title, author and description.',
    kind: SkillKind.knowledge,
    category: SkillCategory.knowledge,
    params: const [SkillParam('url', ParamType.string, 'The link.')],
    examples: const ['What is this link about?'],
    handler: (args, ctx) async {
      final url = args.str('url').trim();
      if (url.isEmpty) return SkillResult.error('No link given.');
      final r = await ctx.previewLink(url);
      return SkillResult(
        {...r, 'summary': r['rich'] == true ? '${r['title']}' : 'Only the URL was available for ${r['url']}.'},
        cards: [UiCard('link', data: r)],
      );
    },
  ),
];
