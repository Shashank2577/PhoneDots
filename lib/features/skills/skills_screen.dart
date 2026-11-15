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

/// Opens the skills page (it lives under "you").
void openSkills(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const SkillsScreen()));

class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key});

  @override
  State<SkillsScreen> createState() => _SkillsScreenState();
}

class _SkillsScreenState extends State<SkillsScreen> {
  int _segment = 0;
  String _query = '';

  /// Groups opened by hand; a search opens every group with a match.
  final Set<SkillCategory> _open = {};

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    return HandPage(
      body: ListenableBuilder(
        listenable: Listenable.merge([s.skills, s.settings, s.models]),
        builder: (context, _) => ListView(
          physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          children: [
            Column0(
              child: PageIntro(
                'skills',
                switch (_segment) {
                  0 => '${s.skills.enabled.length} of them are on. Switch any of them off, or tap one to try it.',
                  1 => 'Recipes chain skills into one tap. The assistant can run them by name too.',
                  _ => 'Skills other people wrote, as plain JSON. They can\'t run code.',
                },
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
          Column0(
            child: _GroupHead(
              '${categoryLabels[e.key]!.toLowerCase()} · ${e.value.length}',
              open: q.isNotEmpty || _open.contains(e.key),
              onTap: q.isNotEmpty
                  ? null
                  : () => setState(() => _open.contains(e.key) ? _open.remove(e.key) : _open.add(e.key)),
            ),
          ),
          if (q.isNotEmpty || _open.contains(e.key))
            for (var i = 0; i < e.value.length; i++)
              Column0(
                child: Enter(
                  index: i,
                  child: SkillTile(skill: e.value[i]),
                ),
              ),
        ],
        if (groups.isEmpty) const Column0(child: HandEmpty(title: 'nothing matches', doodle: Doodle.search)),
      ],
    );
  }
}

/// A group of skills, folded until tapped: "writing · 7".
class _GroupHead extends StatelessWidget {
  const _GroupHead(this.text, {required this.open, this.onTap});
  final String text;
  final bool open;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    expanded: open,
    child: Pressable(
      onTap: onTap,
      scale: 0.99,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 56),
        child: Padding(
          padding: const EdgeInsets.only(top: 16, bottom: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  text,
                  style: Hand.title.copyWith(color: context.pal.ink),
                  textScaler: Hand.scaler(context),
                ),
              ),
              if (onTap != null)
                AnimatedRotation(
                  turns: open ? 0.25 : 0,
                  duration: const Duration(milliseconds: 200),
                  child: DoodleIcon(Doodle.arrow, size: 22, color: context.pal.pencil),
                ),
            ],
          ),
        ),
      ),
    ),
  );
}

/// One skill: its name (tap to read about it and try it) and a switch.
class SkillTile extends StatelessWidget {
  const SkillTile({super.key, required this.skill});
  final Skill skill;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final missing = skill.requiresModels.where((m) => !s.models.isReady(m)).toList();
    return Row(
      children: [
        Expanded(
          child: Semantics(
            button: true,
            child: Pressable(
              onTap: () => showSkillSheet(context, skill),
              scale: 0.985,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      skill.name.toLowerCase(),
                      style: Hand.door.copyWith(color: context.pal.ink),
                      textScaler: Hand.scaler(context),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Meta(
                        missing.isEmpty
                            ? skill.description
                            : 'Needs ${missing.map((m) => modelById(m)?.name ?? m).join(', ')}',
                        maxLines: 2,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const SizedBox(width: 12),
        HandSwitch(
          value: s.skills.isEnabled(skill),
          label: 'use ${skill.name}',
          onChanged: (v) => s.skills.setEnabled(skill, v),
        ),
      ],
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
                    DoodleIcon(Doodle.close, size: 16, color: p.pencil),
                  const SizedBox(width: 10),
                  Expanded(child: Text(modelById(id)?.name ?? id, style: context.type.rowTitle)),
                  Caption(s.models.isReady(id) ? 'On this phone' : 'Not downloaded yet'),
                ],
              ),
            ),
        ],
        if (k.examples.isNotEmpty) ...[
          const SectionHead('say'),
          for (final e in k.examples) Padding(padding: const EdgeInsets.only(bottom: 4), child: Body('“$e”')),
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
                child: ItemRow(
                  title: r.name,
                  meta: r.description,
                  caption: [for (final st in r.steps) s.skills.byId(st.skillId)?.name ?? st.skillId].join('  →  '),
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
              child: ItemRow(
                title: c.name,
                meta: c.description,
                caption: 'By ${c.author}',
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
              child: ItemRow(
                title: c.name,
                meta: c.description,
                caption: 'By ${c.author}',
                onTap: () => _review(c),
                trailing: HandLink('install', onTap: () => _review(c)),
              ),
            ),
        ],
      ],
    );
  }
}
