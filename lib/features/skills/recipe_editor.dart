import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../skills/recipes/recipe.dart';
import '../../skills/skill.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

class _EditStep {
  _EditStep(this.skill, Map<String, String> args)
    : fields = {for (final p in skill.params) p.name: TextEditingController(text: args[p.name] ?? '')};
  final Skill skill;
  final Map<String, TextEditingController> fields;
}

class RecipeEditor extends StatefulWidget {
  const RecipeEditor({super.key, this.recipe});
  final Recipe? recipe;

  @override
  State<RecipeEditor> createState() => _RecipeEditorState();
}

class _RecipeEditorState extends State<RecipeEditor> {
  late final _name = TextEditingController(text: widget.recipe?.name ?? '');
  late final _description = TextEditingController(text: widget.recipe?.description ?? '');
  late String _input = widget.recipe?.input ?? 'text';
  final List<_EditStep> _steps = [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_steps.isEmpty && widget.recipe != null) {
      final reg = AppScope.services(context).skills;
      for (final s in widget.recipe!.steps) {
        final skill = reg.byId(s.skillId);
        if (skill != null) _steps.add(_EditStep(skill, s.args));
      }
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _description.dispose();
    for (final s in _steps) {
      for (final c in s.fields.values) {
        c.dispose();
      }
    }
    super.dispose();
  }

  Future<void> _addStep() async {
    final reg = AppScope.services(context).skills;
    final choices = reg.enabled.where((k) => k.kind != SkillKind.recipe).toList();
    final picked = await showModalBottomSheet<Skill>(
      context: context,
      isScrollControlled: true,
      builder: (c) => DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.7,
        builder: (_, scroll) => ListView(
          controller: scroll,
          children: [
            const SectionLabel('Add a step', padding: EdgeInsets.fromLTRB(20, 0, 20, 8)),
            for (final k in choices)
              ListTile(
                title: Text(k.name),
                subtitle: Text(k.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                onTap: () => Navigator.pop(c, k),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    final defaults = <String, String>{};
    for (final p in picked.params.where((p) => p.required)) {
      defaults[p.name] = _steps.isEmpty ? '{{input}}' : '{{prev.${_guessField(_steps.last.skill)}}}';
    }
    setState(() => _steps.add(_EditStep(picked, defaults)));
  }

  /// The output field most likely to feed the next step.
  static String _guessField(Skill s) => switch (s.id) {
    'transcribe_audio' || 'read_text_in_image' => 'text',
    'redact_pii' => 'redacted_text',
    'summarize' || 'rewrite' || 'translate' || 'proofread' || 'draft_reply' => 'result',
    _ => 'summary',
  };

  Future<void> _save() async {
    final name = _name.text.trim();
    if (name.isEmpty || _steps.isEmpty) {
      toast(context, 'Give the recipe a name and at least one step.');
      return;
    }
    final id =
        widget.recipe?.id ?? name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_').replaceAll(RegExp(r'^_|_$'), '');
    final recipe = Recipe(
      id: id.isEmpty ? 'recipe_${DateTime.now().millisecondsSinceEpoch}' : id,
      name: name,
      description: _description.text.trim().isEmpty ? name : _description.text.trim(),
      input: _input,
      steps: [
        for (final s in _steps)
          RecipeStep(s.skill.id, {
            for (final e in s.fields.entries)
              if (e.value.text.trim().isNotEmpty) e.key: e.value.text.trim(),
          }),
      ],
    );
    await AppScope.services(context).skills.saveRecipe(recipe);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.recipe == null ? 'New recipe' : 'Edit recipe'),
        actions: [
          TextButton(onPressed: _save, child: const Text('Save')),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(labelText: 'Name'),
          ),
          const SizedBox(height: 10),
          TextField(
            controller: _description,
            decoration: const InputDecoration(labelText: 'What it does'),
          ),
          const SectionLabel('Starts from', padding: EdgeInsets.only(top: 20, bottom: 8)),
          SegmentedButton<String>(
            showSelectedIcon: false,
            segments: const [
              ButtonSegment(value: 'text', label: Text('Text')),
              ButtonSegment(value: 'audio', label: Text('Audio')),
              ButtonSegment(value: 'image', label: Text('Image')),
              ButtonSegment(value: 'none', label: Text('Nothing')),
            ],
            selected: {_input},
            onSelectionChanged: (v) => setState(() => _input = v.first),
          ),
          const SectionLabel('Steps', padding: EdgeInsets.only(top: 20, bottom: 8)),
          Text(
            'Use {{input}}, {{prev.field}} or {{steps.1.field}} to pass results along.',
            style: context.text.bodySmall,
          ),
          const SizedBox(height: 10),
          for (var i = 0; i < _steps.length; i++)
            Panel(
              margin: const EdgeInsets.only(bottom: 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 22,
                        height: 22,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(color: p.ink, shape: BoxShape.circle),
                        child: Text(
                          '${i + 1}',
                          style: TextStyle(color: p.bg, fontSize: 12, fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(child: Text(_steps[i].skill.name, style: context.text.titleMedium)),
                      IconButton(
                        icon: const Icon(Icons.close_rounded, size: 18),
                        onPressed: () => setState(() => _steps.removeAt(i)),
                      ),
                    ],
                  ),
                  for (final param in _steps[i].skill.params)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: TextField(
                        controller: _steps[i].fields[param.name],
                        decoration: InputDecoration(
                          labelText: param.name,
                          helperText: param.description,
                          isDense: true,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          OutlinedButton.icon(
            onPressed: _addStep,
            icon: const Icon(Icons.add_rounded, size: 18),
            label: const Text('Add step'),
          ),
        ],
      ),
    );
  }
}
