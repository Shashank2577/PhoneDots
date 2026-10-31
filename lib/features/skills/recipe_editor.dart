import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../skills/recipes/recipe.dart';
import '../../skills/skill.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/hand.dart';

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
          padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 24),
          children: [
            const PageIntro('add a step', 'Pick the skill this step runs.'),
            for (final k in choices)
              Door(
                k.name.toLowerCase(),
                style: Hand.label.copyWith(fontSize: 23),
                meta: k.description,
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
    return HandPage(
      bottom: InkButton('save the recipe', trailing: Doodle.tick, expand: true, onTap: _save),
      children: [
        PageIntro(
          widget.recipe == null ? 'new recipe' : 'edit recipe',
          'Chain skills so one tap runs them all. Pass results along with {{input}}, {{prev.field}} or {{steps.1.field}}.',
          doodle: Doodle.curl,
        ),
        TextField(
          controller: _name,
          decoration: const InputDecoration(hintText: 'name it'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _description,
          decoration: const InputDecoration(hintText: 'what it does'),
        ),
        const SectionHead('starts from'),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final (v, label) in [
              ('text', 'text'),
              ('audio', 'a recording'),
              ('image', 'a photo'),
              ('none', 'nothing'),
            ])
              ChoicePill(label, selected: _input == v, onTap: () => setState(() => _input = v)),
          ],
        ),
        const SectionHead('steps'),
        for (var i = 0; i < _steps.length; i++)
          Enter(
            child: Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text('${i + 1}.', style: Hand.title.copyWith(fontSize: 26, color: p.ink)),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _steps[i].skill.name.toLowerCase(),
                          style: Hand.label.copyWith(fontSize: 24, color: p.ink),
                        ),
                      ),
                      DoodleButton(
                        Doodle.close,
                        tooltip: 'Remove step',
                        size: 20,
                        color: p.redPen,
                        onTap: () => setState(() => _steps.removeAt(i)),
                      ),
                    ],
                  ),
                  for (final param in _steps[i].skill.params)
                    Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: TextField(
                        controller: _steps[i].fields[param.name],
                        decoration: InputDecoration(hintText: param.name, helperText: param.description, isDense: true),
                      ),
                    ),
                  const HandDivider(padding: EdgeInsets.only(top: 12)),
                ],
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: PillButton('add a step', leading: Doodle.plus, onTap: _addStep),
        ),
      ],
    );
  }
}
