import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/models/model_catalog.dart';
import '../../skills/community/community_skill.dart';
import '../../skills/recipes/recipe.dart';
import '../../skills/skill.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/hand.dart';
import '../chat/attach.dart';
import 'recipe_editor.dart';

const categoryLabels = {
  SkillCategory.audio: 'Voice & audio',
  SkillCategory.vision: 'Camera & photos',
  SkillCategory.text: 'Writing',
  SkillCategory.phone: 'Phone actions',
  SkillCategory.knowledge: 'Knowledge & memory',
  SkillCategory.output: 'Presentation',
  SkillCategory.recipes: 'Recipes',
  SkillCategory.community: 'Community',
};

Doodle categoryDoodle(SkillCategory c) => switch (c) {
  SkillCategory.audio => Doodle.wave,
  SkillCategory.vision => Doodle.camera,
  SkillCategory.text => Doodle.pen,
  SkillCategory.phone => Doodle.phone,
  SkillCategory.knowledge => Doodle.book,
  SkillCategory.output => Doodle.squiggle,
  SkillCategory.recipes => Doodle.curl,
  SkillCategory.community => Doodle.people,
};

class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key});

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  int _segment = 0;
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    return HandPage(
      wordmark: true,
      body: ListenableBuilder(
        listenable: Listenable.merge([s.skills, s.settings, s.models]),
        builder: (context, _) => ListView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            Column0(
              child: PageIntro(
                'skills',
                switch (_segment) {
                  0 => 'Everything the assistant can do. Switch any of them off, or tap one to try it.',
                  1 => 'Recipes chain skills into one tap. The assistant can run them by name too.',
                  _ => 'Skills other people wrote, as plain JSON. They can\'t run code.',
                },
                mark: _segment == 0 ? '${s.skills.enabled.length}' : null,
                doodle: Doodle.spark,
              ),
            ),
            Column0(
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final (i, label) in ['skills', 'recipes', 'community'].indexed)
                    ChoicePill(label, selected: _segment == i, onTap: () => setState(() => _segment = i)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              child: KeyedSubtree(
                key: ValueKey(_segment),
                child: switch (_segment) {
                  0 => _skillList(context),
                  1 => const _Recipes(),
                  _ => const _Community(),
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _skillList(BuildContext context) {
    final s = AppScope.services(context);
    final q = _query.toLowerCase();
    final skills = s.skills.builtIns
        .where((k) => s.skills.availableHere(k))
        .where((k) => q.isEmpty || '${k.name} ${k.description}'.toLowerCase().contains(q))
        .toList();
    final groups = <SkillCategory, List<Skill>>{};
    for (final k in skills) {
      groups.putIfAbsent(k.category, () => []).add(k);
    }
    return Column(
      children: [
        Column0(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: TextField(
              onChanged: (v) => setState(() => _query = v),
              decoration: InputDecoration(
                hintText: 'search every skill…',
                prefixIcon: Padding(
                  padding: const EdgeInsets.all(12),
                  child: DoodleIcon(Doodle.search, size: 20, color: context.pal.pencil),
                ),
              ),
            ),
          ),
        ),
        for (final e in groups.entries) ...[
          Column0(child: SectionHead(categoryLabels[e.key]!.toLowerCase(), note: '${e.value.length}')),
          for (var i = 0; i < e.value.length; i++)
            Column0(
              child: Enter(
                index: i,
                child: SkillTile(skill: e.value[i]),
              ),
            ),
        ],
      ],
    );
  }
}

class SkillTile extends StatelessWidget {
  const SkillTile({super.key, required this.skill});
  final Skill skill;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final p = context.pal;
    final missing = skill.requiresModels.where((m) => !s.models.isReady(m)).toList();
    return Pressable(
      onTap: () => showSkillSheet(context, skill),
      scale: 0.985,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            DoodleIcon(categoryDoodle(skill.category), color: p.pencil),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(skill.name.toLowerCase(), style: Hand.label.copyWith(fontSize: 23, color: p.ink)),
                      ),
                      const SizedBox(width: 6),
                      DoodleIcon(Doodle.arrow, size: 16, color: p.graphite),
                    ],
                  ),
                  Meta(
                    missing.isEmpty
                        ? skill.description
                        : 'needs ${missing.map((m) => modelById(m)?.name ?? m).join(', ')}',
                    maxLines: 2,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            HandSwitch(
              value: s.skills.isEnabled(skill),
              label: 'use ${skill.name}',
              onChanged: (v) => s.skills.setEnabled(skill, v),
            ),
          ],
        ),
      ),
    );
  }
}

void showSkillSheet(BuildContext context, Skill skill) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (_) =>
        DraggableScrollableSheet(expand: false, initialChildSize: 0.75, builder: (_, c) => _SkillDetail(skill, c)),
  );
}

class _SkillDetail extends StatefulWidget {
  const _SkillDetail(this.skill, this.scroll);
  final Skill skill;
  final ScrollController scroll;

  @override
  State<_SkillDetail> createState() => _SkillDetailState();
}

class _SkillDetailState extends State<_SkillDetail> {
  final Map<String, TextEditingController> _fields = {};
  final List<Attachment> _attachments = [];

  @override
  void dispose() {
    for (final c in _fields.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _field(String name) => _fields.putIfAbsent(name, TextEditingController.new);

  Future<void> _run() async {
    final state = AppScope.of(context);
    final k = widget.skill;
    final args = <String, dynamic>{};
    for (final p in k.params) {
      if (p.type == ParamType.attachment) {
        if (_attachments.isNotEmpty) args[p.name] = _attachments.last.id;
        continue;
      }
      final v = _field(p.name).text.trim();
      if (v.isEmpty) continue;
      args[p.name] = switch (p.type) {
        ParamType.integer => int.tryParse(v) ?? v,
        ParamType.number => double.tryParse(v) ?? v,
        ParamType.boolean => v.toLowerCase() == 'true' || v.toLowerCase() == 'yes',
        ParamType.stringList => v.split(RegExp(r'\s*[\n,;]\s*')).where((x) => x.isNotEmpty).toList(),
        _ => v,
      };
    }
    Navigator.pop(context);
    state.startChat((chat) => chat.runSkill(k, args, label: k.name, attachments: [..._attachments]));
  }

  Future<void> _pick(SkillParam p) async {
    final s = AppScope.services(context);
    final id = 'a${_attachments.length + 1}';
    final a = p.description.contains('audio')
        ? await Attach.record(context, s, id)
        : await Attach.chooseAndPick(context, s, id);
    if (a != null) setState(() => _attachments.add(a));
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final k = widget.skill;
    final p = context.pal;
    return ListView(
      controller: widget.scroll,
      padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 32),
      children: [
        PageIntro(k.name.toLowerCase(), k.description, doodle: categoryDoodle(k.category)),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            HandTag(k.id),
            HandTag(switch (k.confirm) {
              ConfirmPolicy.never => 'runs without asking',
              ConfirmPolicy.firstTime => 'asks once',
              ConfirmPolicy.always => 'asks every time',
            }),
            if (k.platforms.isNotEmpty) HandTag('${k.platforms.join(', ')} only'),
          ],
        ),
        if (k.requiresModels.isNotEmpty) ...[
          const SectionHead('models it uses'),
          for (final id in k.requiresModels)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  if (s.models.isReady(id))
                    const DoodleIcon(Doodle.tick, size: 18)
                  else
                    DoodleIcon(Doodle.close, size: 16, color: p.graphite),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text((modelById(id)?.name ?? id).toLowerCase(), style: Hand.label.copyWith(color: p.ink)),
                  ),
                  Meta(s.models.isReady(id) ? 'on this phone' : 'not downloaded yet'),
                ],
              ),
            ),
        ],
        if (k.examples.isNotEmpty) ...[
          const SectionHead('say'),
          for (final e in k.examples) Body('“$e”', color: p.pencil),
        ],
        if (k.params.isNotEmpty) ...[
          const SectionHead('try it'),
          for (final param in k.params)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: param.type == ParamType.attachment
                  ? Align(
                      alignment: Alignment.centerLeft,
                      child: PillButton(
                        _attachments.isEmpty ? 'attach ${param.name}' : _attachments.last.name,
                        leading: _attachments.isEmpty ? Doodle.clip : Doodle.tick,
                        onTap: () => _pick(param),
                      ),
                    )
                  : TextField(
                      controller: _field(param.name),
                      maxLines: param.type == ParamType.string || param.type == ParamType.stringList ? null : 1,
                      keyboardType: param.type == ParamType.integer || param.type == ParamType.number
                          ? TextInputType.number
                          : null,
                      decoration: InputDecoration(
                        hintText: '${param.name}${param.required ? '' : ' (optional)'}',
                        helperText: param.description,
                        helperMaxLines: 2,
                      ),
                    ),
            ),
        ],
        const SizedBox(height: 16),
        InkButton('run it in chat', trailing: Doodle.arrow, expand: true, onTap: _run),
      ],
    );
  }
}

class _Recipes extends StatelessWidget {
  const _Recipes();

  // Rebuilds whenever recipes are saved or deleted (it's const, so the parent alone won't).
  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: AppScope.services(context).skills, builder: (context, _) => _list(context));

  Widget _list(BuildContext context) {
    final s = AppScope.services(context);
    final p = context.pal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column0(
          child: Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: PillButton(
                'new recipe',
                leading: Doodle.plus,
                onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RecipeEditor())),
              ),
            ),
          ),
        ),
        for (final (i, r) in s.skills.recipes.indexed)
          Column0(
            child: Enter(
              index: i,
              child: Panel(
                child: Door(
                  r.name.toLowerCase(),
                  style: Hand.label.copyWith(fontSize: 25),
                  meta:
                      '${r.description}\n${[for (final st in r.steps) (s.skills.byId(st.skillId)?.name ?? st.skillId).toLowerCase()].join('  →  ')}',
                  onTap: () => showSkillSheet(context, RecipeSkill(r)),
                  trailing: r.builtIn
                      ? null
                      : Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            DoodleButton(
                              Doodle.pen,
                              tooltip: 'Edit',
                              size: 20,
                              onTap: () =>
                                  Navigator.of(context)
                                      .push(MaterialPageRoute<void>(builder: (_) => RecipeEditor(recipe: r))),
                            ),
                            DoodleButton(
                              Doodle.trash,
                              tooltip: 'Delete',
                              size: 20,
                              color: p.redPen,
                              onTap: () => s.skills.deleteRecipe(r),
                            ),
                          ],
                        ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class _Community extends StatefulWidget {
  const _Community();

  @override
  State<_Community> createState() => _CommunityState();
}

class _CommunityState extends State<_Community> {
  final _url = TextEditingController();
  bool _loading = false;

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  Future<void> _review(CommunitySkill skill) async {
    final s = AppScope.services(context);
    final ok = await confirmDialog(
      context,
      title: 'Install ${skill.name}?',
      body:
          '${skill.description}\n\nBy ${skill.author} · v${skill.version}'
          '${skill.calls.isEmpty ? '\nRuns a prompt on Gemma. It cannot access anything else.' : '\nCalls: ${skill.calls.join(', ')}. Each keeps its own permission prompt.'}'
          '${skill.sourceUrl == null ? '' : '\n\nFrom ${skill.sourceUrl}'}',
      confirm: 'Install',
    );
    if (!ok) return;
    await s.skills.install(skill);
    await s.ledger.record('skill', 'Installed community skill ${skill.name}');
    if (mounted) toast(context, 'Installed ${skill.name}');
  }

  Future<void> _fetch() async {
    final s = AppScope.services(context);
    setState(() => _loading = true);
    try {
      await s.ledger.record('community', 'Fetched ${_url.text.trim()}', network: true);
      final skill = await s.skills.fetchCommunity(_url.text);
      if (mounted) await _review(skill);
    } catch (e) {
      if (mounted) toast(context, 'Could not install: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) =>
      ListenableBuilder(listenable: AppScope.services(context).skills, builder: (context, _) => _list(context));

  Widget _list(BuildContext context) {
    final s = AppScope.services(context);
    final installed = s.skills.community;
    final featured = sampleCommunitySkills
        .map(CommunitySkill.parse)
        .where((c) => !installed.any((i) => i.id == c.id))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column0(
          child: Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _url,
                    keyboardType: TextInputType.url,
                    decoration: const InputDecoration(hintText: 'https://…/skill.json'),
                  ),
                ),
                const SizedBox(width: 10),
                PillButton(_loading ? 'checking…' : 'add', onTap: _loading ? null : _fetch),
              ],
            ),
          ),
        ),
        if (installed.isNotEmpty) ...[
          const Column0(child: SectionHead('installed')),
          for (final c in installed)
            Column0(
              child: Door(
                c.name.toLowerCase(),
                style: Hand.label.copyWith(fontSize: 25),
                meta: '${c.description} · by ${c.author}',
                onTap: () => showSkillSheet(context, c),
                trailing: DoodleButton(
                  Doodle.trash,
                  tooltip: 'Remove',
                  size: 20,
                  color: context.pal.redPen,
                  onTap: () => s.skills.uninstall(c),
                ),
              ),
            ),
        ],
        if (featured.isNotEmpty) ...[
          const Column0(child: SectionHead('worth trying')),
          for (final c in featured)
            Column0(
              child: Door(
                c.name.toLowerCase(),
                style: Hand.label.copyWith(fontSize: 25),
                meta: c.description,
                onTap: () => _review(c),
                trailing: PillButton('install', onTap: () => _review(c)),
              ),
            ),
        ],
      ],
    );
  }
}
