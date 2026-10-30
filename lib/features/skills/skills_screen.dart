import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/models/model_catalog.dart';
import '../../skills/community/community_skill.dart';
import '../../skills/recipes/recipe.dart';
import '../../skills/skill.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/sketch.dart';
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

IconData categoryIcon(SkillCategory c) => switch (c) {
  SkillCategory.audio => Icons.graphic_eq_rounded,
  SkillCategory.vision => Icons.photo_camera_outlined,
  SkillCategory.text => Icons.edit_note_rounded,
  SkillCategory.phone => Icons.smartphone_rounded,
  SkillCategory.knowledge => Icons.auto_stories_outlined,
  SkillCategory.output => Icons.dashboard_outlined,
  SkillCategory.recipes => Icons.account_tree_outlined,
  SkillCategory.community => Icons.public_rounded,
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
    return DoodlePage(
      title: 'Skills',
      bottom: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 10),
        child: SizedBox(
          width: double.infinity,
          child: SegmentedButton<int>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 0, label: Text('Skills')),
              ButtonSegment(value: 1, label: Text('Recipes')),
              ButtonSegment(value: 2, label: Text('Community')),
            ],
            selected: {_segment},
            onSelectionChanged: (v) => setState(() => _segment = v.first),
          ),
        ),
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([s.skills, s.settings, s.models]),
        builder: (context, _) => AnimatedSwitcher(
          duration: const Duration(milliseconds: 260),
          child: KeyedSubtree(
            key: ValueKey(_segment),
            child: switch (_segment) {
              0 => _skillList(context),
              1 => const _Recipes(),
              _ => const _Community(),
            },
          ),
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
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          child: TextField(
            onChanged: (v) => setState(() => _query = v),
            decoration: const InputDecoration(
              hintText: 'Search skills',
              prefixIcon: Icon(Icons.search_rounded, size: 20),
            ),
          ),
        ),
        for (final e in groups.entries) ...[
          SectionLabel('${categoryLabels[e.key]} · ${e.value.length}'),
          for (var i = 0; i < e.value.length; i++)
            Enter(
              index: i,
              child: SkillTile(skill: e.value[i]),
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
    return ListTile(
      leading: Icon(categoryIcon(skill.category), size: 20, color: p.muted),
      title: Text(skill.name),
      subtitle: Text(
        missing.isEmpty ? skill.description : 'Needs ${missing.map((m) => modelById(m)?.name ?? m).join(', ')}',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: missing.isEmpty ? null : context.text.bodySmall?.copyWith(color: p.warn),
      ),
      trailing: SketchSwitch(value: s.skills.isEnabled(skill), onChanged: (v) => s.skills.setEnabled(skill, v)),
      onTap: () => showSkillSheet(context, skill),
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
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Row(
          children: [
            Icon(categoryIcon(k.category), size: 22),
            const SizedBox(width: 10),
            Expanded(child: Text(k.name, style: context.text.titleLarge)),
          ],
        ),
        const SizedBox(height: 8),
        Text(k.description, style: context.text.bodyMedium?.copyWith(color: p.muted)),
        const SizedBox(height: 12),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            Tag(k.id, icon: Icons.code_rounded),
            Tag(switch (k.confirm) {
              ConfirmPolicy.never => 'Runs without asking',
              ConfirmPolicy.firstTime => 'Asks once',
              ConfirmPolicy.always => 'Asks every time',
            }),
            if (k.platforms.isNotEmpty) Tag('${k.platforms.join(', ')} only'),
          ],
        ),
        if (k.requiresModels.isNotEmpty) ...[
          const SectionLabel('Models', padding: EdgeInsets.only(top: 20, bottom: 6)),
          for (final id in k.requiresModels)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Dot(color: s.models.isReady(id) ? p.dot : p.faint),
                  const SizedBox(width: 10),
                  Expanded(child: Text(modelById(id)?.name ?? id)),
                  Text(s.models.isReady(id) ? 'Ready' : 'Not downloaded', style: context.text.bodySmall),
                ],
              ),
            ),
        ],
        if (k.examples.isNotEmpty) ...[
          const SectionLabel('Say', padding: EdgeInsets.only(top: 20, bottom: 6)),
          for (final e in k.examples) Text('“$e”', style: context.text.bodyMedium),
        ],
        if (k.params.isNotEmpty) ...[
          const SectionLabel('Try it', padding: EdgeInsets.only(top: 20, bottom: 8)),
          for (final param in k.params)
            Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: param.type == ParamType.attachment
                  ? OutlinedButton.icon(
                      onPressed: () => _pick(param),
                      icon: Icon(_attachments.isEmpty ? Icons.attach_file_rounded : Icons.check_rounded, size: 18),
                      label: Text(_attachments.isEmpty ? 'Attach ${param.name}' : _attachments.last.name),
                    )
                  : TextField(
                      controller: _field(param.name),
                      maxLines: param.type == ParamType.string || param.type == ParamType.stringList ? null : 1,
                      keyboardType: param.type == ParamType.integer || param.type == ParamType.number
                          ? TextInputType.number
                          : null,
                      decoration: InputDecoration(
                        labelText: '${param.name}${param.required ? '' : ' (optional)'}',
                        helperText: param.description,
                        helperMaxLines: 2,
                      ),
                    ),
            ),
        ],
        const SizedBox(height: 12),
        FilledButton(onPressed: _run, child: const Text('Run in chat')),
      ],
    );
  }
}

class _Recipes extends StatelessWidget {
  const _Recipes();

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final p = context.pal;
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 0),
          child: Text(
            'Recipes chain skills into one tap. The agent can also run them by name.',
            style: context.text.bodyMedium?.copyWith(color: p.muted),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: OutlinedButton.icon(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const RecipeEditor())),
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('New recipe'),
          ),
        ),
        const SectionLabel('Your recipes'),
        for (final r in s.skills.recipes)
          Panel(
            margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            onTap: () => showSkillSheet(context, RecipeSkill(r)),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(child: Text(r.name, style: context.text.titleMedium)),
                    if (r.builtIn) const Tag('Built in'),
                    if (!r.builtIn)
                      PopupMenuButton<String>(
                        icon: const Icon(Icons.more_horiz_rounded, size: 20),
                        onSelected: (v) {
                          if (v == 'edit') {
                            Navigator.of(context)
                                .push(MaterialPageRoute<void>(builder: (_) => RecipeEditor(recipe: r)));
                          } else {
                            s.skills.deleteRecipe(r);
                          }
                        },
                        itemBuilder: (_) => const [
                          PopupMenuItem(value: 'edit', child: Text('Edit')),
                          PopupMenuItem(value: 'delete', child: Text('Delete')),
                        ],
                      ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(r.description, style: context.text.bodySmall),
                const SizedBox(height: 12),
                Wrap(
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 4,
                  runSpacing: 6,
                  children: [
                    for (var i = 0; i < r.steps.length; i++) ...[
                      Tag(s.skills.byId(r.steps[i].skillId)?.name ?? r.steps[i].skillId),
                      if (i < r.steps.length - 1) Icon(Icons.arrow_forward_rounded, size: 14, color: p.faint),
                    ],
                  ],
                ),
              ],
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
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final installed = s.skills.community;
    final featured = sampleCommunitySkills
        .map(CommunitySkill.parse)
        .where((c) => !installed.any((i) => i.id == c.id))
        .toList();
    return ListView(
      padding: const EdgeInsets.only(bottom: 24),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _url,
                  keyboardType: TextInputType.url,
                  decoration: const InputDecoration(hintText: 'https://…/skill.json'),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: _loading ? null : _fetch,
                child: _loading
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('Add'),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
          child: Text(
            'Community skills are JSON: a prompt or a chain of existing skills. They cannot run code.',
            style: context.text.bodySmall,
          ),
        ),
        if (installed.isNotEmpty) ...[
          const SectionLabel('Installed'),
          for (final c in installed)
            ListTile(
              leading: const Icon(Icons.extension_outlined, size: 20),
              title: Text(c.name),
              subtitle: Text('${c.description}\nby ${c.author}', maxLines: 3),
              isThreeLine: true,
              onTap: () => showSkillSheet(context, c),
              trailing: IconButton(
                icon: const Icon(Icons.delete_outline_rounded),
                onPressed: () => s.skills.uninstall(c),
              ),
            ),
        ],
        if (featured.isNotEmpty) ...[
          const SectionLabel('Featured'),
          for (final c in featured)
            ListTile(
              leading: const Icon(Icons.extension_outlined, size: 20),
              title: Text(c.name),
              subtitle: Text(c.description),
              trailing: OutlinedButton(onPressed: () => _review(c), child: const Text('Install')),
            ),
        ],
      ],
    );
  }
}
