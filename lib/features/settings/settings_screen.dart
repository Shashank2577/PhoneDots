import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/models/model_catalog.dart';
import '../../theme/theme.dart';
import '../../widgets/hand.dart';
import '../lab/lab_screen.dart';
import '../memory/memory_screen.dart';
import '../privacy/privacy_screen.dart';

/// The "you" tab: everything that is not chat, skills or models.
class YouScreen extends StatelessWidget {
  const YouScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    return ListenableBuilder(
      listenable: Listenable.merge([s.memory, s.knowledge, s.ledger]),
      builder: (context, _) => HandPage(
        wordmark: true,
        children: [
          const PageIntro(
            'you',
            'What PhoneDots remembers, what it has done, and how it behaves. All of it stays here.',
            doodle: Doodle.person,
          ),
          for (final (i, d) in [
            (
              Doodle.heart,
              'memory',
              '${s.memory.facts.length} things you asked it to remember',
              () => push(const MemoryScreen()),
            ),
            (
              Doodle.folder,
              'my files',
              '${s.knowledge.docs.length} documents it can search',
              () => push(const KnowledgeScreen()),
            ),
            (
              Doodle.lock,
              'privacy',
              '${s.ledger.networkEvents} network events, all model downloads',
              () => push(const PrivacyScreen()),
            ),
            (Doodle.flask, 'lab', 'try prompts, measure speed', () => push(const LabScreen())),
            (
              Doodle.gear,
              'settings',
              'light or dark, handwriting, how the assistant works',
              () => push(const SettingsScreen()),
            ),
            (Doodle.book, 'about', 'Gemma, Desert Ant and the licences', () => push(const AboutScreen())),
          ].indexed)
            Enter(
              index: i,
              child: Door(d.$2, leading: d.$1, meta: d.$3, onTap: d.$4),
            ),
        ],
      ),
    );
  }
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  late final _token = TextEditingController(text: AppScope.services(context).settings.hfToken);
  bool _showToken = false;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final st = s.settings;
    final p = context.pal;
    return ListenableBuilder(
      listenable: st,
      builder: (context, _) => HandPage(
        children: [
          const PageIntro(
            'settings',
            'How PhoneDots looks and how the assistant works. Changes apply straight away.',
            doodle: Doodle.gear,
          ),
          const SectionHead('light or dark'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final (mode, label, d) in [
                (ThemeMode.system, 'like the phone', Doodle.phone),
                (ThemeMode.light, 'light', Doodle.sun),
                (ThemeMode.dark, 'dark', Doodle.moon),
              ])
                ChoicePill(
                  label,
                  leading: d,
                  selected: st.themeMode == mode,
                  onTap: () => st.update((x) => x.themeMode = mode),
                ),
            ],
          ),
          const SectionHead('handwriting'),
          const Meta('Headlines are always hand-lettered. Pick how the quieter text underneath reads.'),
          const SizedBox(height: 8),
          for (final v in Voice.values)
            Pressable(
              onTap: () => st.update((x) => x.voice = v.name),
              scale: 0.99,
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(width: 26, child: st.voice == v.name ? const DrawnDoodle(Doodle.tick, size: 20) : null),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          MarkedText(
                            v.label,
                            mark: st.voice == v.name ? v.label : null,
                            style: Hand.label.copyWith(fontSize: 23),
                          ),
                          Text(
                            'Nothing you say leaves this phone.',
                            style: TextStyle(
                              fontFamily: v.family,
                              fontVariations: v.variations,
                              fontSize: 15 * v.scale,
                              color: p.pencil,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Meta(v.note.split(',').first),
                  ],
                ),
              ),
            ),
          const SectionHead('the assistant'),
          SwitchRow(
            title: 'fast path',
            body: 'Let ${modelById(st.routerId)?.name ?? 'FunctionGemma'} handle simple phone commands instantly.',
            value: st.useRouter,
            onChanged: (v) => st.update((x) => x.useRouter = v),
          ),
          SwitchRow(
            title: 'read shared links',
            body: 'Fetch the public title and description of links you paste, straight from the site. Each one is logged under privacy.',
            value: st.readLinks,
            onChanged: (v) => st.update((x) => x.readLinks = v),
          ),
          SwitchRow(
            title: 'think first',
            body: 'Reason step by step before answering. Slower, better for hard questions.',
            value: st.thinking,
            onChanged: (v) => st.update((x) => x.thinking = v),
          ),
          SwitchRow(
            title: 'use the graphics chip',
            body: 'Faster on most phones. Turn off if a model won\'t load.',
            value: st.useGpu,
            onChanged: (v) => st.update((x) => x.useGpu = v),
          ),
          const SizedBox(height: 8),
          Text(
            'creativity · ${st.temperature.toStringAsFixed(1)}',
            style: Hand.label.copyWith(fontSize: 23, color: p.ink),
          ),
          Slider(value: st.temperature, max: 1.2, divisions: 12, onChanged: (v) => st.update((x) => x.temperature = v)),
          Text('steps per answer · ${st.maxSteps}', style: Hand.label.copyWith(fontSize: 23, color: p.ink)),
          const Meta('How many skills it may chain before it has to answer.'),
          Slider(
            value: st.maxSteps.toDouble(),
            min: 1,
            max: 12,
            divisions: 11,
            onChanged: (v) => st.update((x) => x.maxSteps = v.round()),
          ),
          const SectionHead('hugging face'),
          const Meta('Only needed for gated models. Stored on this phone only.'),
          const SizedBox(height: 8),
          TextField(
            controller: _token,
            obscureText: !_showToken,
            onChanged: (v) => st.update((x) => x.hfToken = v.trim()),
            decoration: InputDecoration(
              hintText: 'access token (optional)',
              suffixIcon: DoodleButton(
                _showToken ? Doodle.eyeOff : Doodle.eye,
                tooltip: _showToken ? 'Hide' : 'Show',
                size: 20,
                color: p.pencil,
                onTap: () => setState(() => _showToken = !_showToken),
              ),
            ),
          ),
          const SizedBox(height: 16),
          HandLink('show the welcome again', color: p.pencil, onTap: () => st.update((x) => x.onboarded = false)),
        ],
      ),
    );
  }
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) => HandPage(
    children: [
      const PageIntro('about', 'PhoneDots 0.3. An assistant that lives on your phone.', doodle: Doodle.book),
      for (final (title, body) in [
        (
          'gemma',
          'Gemma 4, FunctionGemma and EmbeddingGemma, under the Gemma Terms of Use (ai.google.dev/gemma/terms). Run with LiteRT-LM (Apache 2.0).',
        ),
        (
          'desert ant',
          'Specialist models by Desert Ant Labs, free up to 100k monthly active devices. Voz uses NVIDIA Parakeet TDT 0.6B v3 weights under CC BY 4.0.',
        ),
        (
          'the look',
          'The hand-drawn minimal design system from Burrow (Android-Showcase). Caveat, Inter, Nunito, Shantell Sans and Patrick Hand under the SIL Open Font License.',
        ),
        (
          'inspiration',
          'Google AI Edge Gallery (Apache 2.0): ask image, audio scribe, prompt lab, agent skills and mobile actions in one assistant.',
        ),
      ]) ...[SectionHead(title), Body(body, color: context.pal.pencil)],
      const SizedBox(height: 20),
      Align(
        alignment: Alignment.centerLeft,
        child: PillButton(
          'open-source licences',
          onTap: () => showLicensePage(context: context, applicationName: 'PhoneDots'),
        ),
      ),
    ],
  );
}
