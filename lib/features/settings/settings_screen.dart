import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/models/model_catalog.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../lab/lab_screen.dart';
import '../memory/memory_screen.dart';
import '../privacy/privacy_screen.dart';

/// The "You" tab: everything that is not chat, skills or models.
class YouScreen extends StatelessWidget {
  const YouScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    return Scaffold(
      appBar: AppBar(title: const Text('You')),
      body: ListenableBuilder(
        listenable: Listenable.merge([s.memory, s.knowledge, s.ledger]),
        builder: (context, _) => ListView(children: [
          const SectionLabel('Your data'),
          _NavTile(Icons.bookmark_border_rounded, 'Memory', '${s.memory.facts.length} facts', () => push(const MemoryScreen())),
          _NavTile(Icons.folder_open_rounded, 'My files', '${s.knowledge.docs.length} documents', () => push(const KnowledgeScreen())),
          _NavTile(Icons.shield_outlined, 'Privacy', '${s.ledger.networkEvents} network events, all downloads', () => push(const PrivacyScreen())),
          const SectionLabel('Tools'),
          _NavTile(Icons.science_outlined, 'Lab', 'Prompt Lab and on-device benchmark', () => push(const LabScreen())),
          _NavTile(Icons.tune_rounded, 'Settings', 'Models, behaviour, appearance', () => push(const SettingsScreen())),
          _NavTile(Icons.info_outline_rounded, 'About & licences', 'Gemma, Desert Ant, open source', () => push(const AboutScreen())),
        ]),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile(this.icon, this.title, this.subtitle, this.onTap);
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
        leading: Icon(icon, size: 22),
        title: Text(title),
        subtitle: Text(subtitle),
        trailing: Icon(Icons.chevron_right_rounded, color: context.pal.faint),
        onTap: onTap,
      );
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
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListenableBuilder(
        listenable: st,
        builder: (context, _) => ListView(padding: const EdgeInsets.only(bottom: 40), children: [
          const SectionLabel('Appearance'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: SegmentedButton<ThemeMode>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: ThemeMode.system, label: Text('System')),
                ButtonSegment(value: ThemeMode.light, label: Text('Light')),
                ButtonSegment(value: ThemeMode.dark, label: Text('Dark')),
              ],
              selected: {st.themeMode},
              onSelectionChanged: (v) => st.update((x) => x.themeMode = v.first),
            ),
          ),
          const SectionLabel('Agent'),
          SwitchListTile(
            title: const Text('Fast path'),
            subtitle: Text('Let ${modelById(st.routerId)?.name ?? 'FunctionGemma'} handle simple phone commands instantly'),
            value: st.useRouter,
            onChanged: (v) => st.update((x) => x.useRouter = v),
          ),
          SwitchListTile(
            title: const Text('Thinking'),
            subtitle: const Text('Reason step by step before answering. Slower, better for hard questions.'),
            value: st.thinking,
            onChanged: (v) => st.update((x) => x.thinking = v),
          ),
          SwitchListTile(
            title: const Text('Use GPU'),
            subtitle: const Text('Faster on most phones. Turn off if a model fails to load.'),
            value: st.useGpu,
            onChanged: (v) => st.update((x) => x.useGpu = v),
          ),
          ListTile(
            title: const Text('Creativity'),
            subtitle: Slider(
              value: st.temperature,
              max: 1.2,
              divisions: 12,
              label: st.temperature.toStringAsFixed(1),
              onChanged: (v) => st.update((x) => x.temperature = v),
            ),
            trailing: Text(st.temperature.toStringAsFixed(1)),
          ),
          ListTile(
            title: const Text('Max tool steps per answer'),
            subtitle: Slider(
              value: st.maxSteps.toDouble(),
              min: 1,
              max: 12,
              divisions: 11,
              onChanged: (v) => st.update((x) => x.maxSteps = v.round()),
            ),
            trailing: Text('${st.maxSteps}'),
          ),
          const SectionLabel('Hugging Face'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              controller: _token,
              obscureText: !_showToken,
              onChanged: (v) => st.update((x) => x.hfToken = v.trim()),
              decoration: InputDecoration(
                labelText: 'Access token (optional)',
                helperText: 'Only needed for gated models. Stored on this device only.',
                suffixIcon: IconButton(
                  icon: Icon(_showToken ? Icons.visibility_off_outlined : Icons.visibility_outlined, size: 18),
                  onPressed: () => setState(() => _showToken = !_showToken),
                ),
              ),
            ),
          ),
          const SectionLabel('Setup'),
          ListTile(
            title: const Text('Show welcome again'),
            onTap: () => st.update((x) => x.onboarded = false),
          ),
        ]),
      ),
    );
  }
}

class AboutScreen extends StatelessWidget {
  const AboutScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    Widget block(String title, String body) => Panel(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: context.text.titleMedium),
            const SizedBox(height: 6),
            Text(body, style: context.text.bodySmall),
          ]),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('About')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          child: Row(children: [
            Dot(size: 12, color: p.ink),
            const SizedBox(width: 6),
            Dot(size: 12, color: p.dot),
            const SizedBox(width: 12),
            Text('PhoneDots 0.1', style: context.text.titleLarge),
          ]),
        ),
        block('Gemma', 'Gemma 4, FunctionGemma and EmbeddingGemma are provided under the Gemma Terms of Use (ai.google.dev/gemma/terms). '
            'Run with LiteRT-LM (Apache 2.0).'),
        block('Desert Ant', 'Specialist models by Desert Ant Labs, free up to 100k monthly active devices. '
            'Voz uses NVIDIA Parakeet TDT 0.6B v3 weights under CC BY 4.0.'),
        block('Inspiration', 'Built in the spirit of Google AI Edge Gallery (Apache 2.0): ask image, audio scribe, prompt lab, agent skills and mobile actions, combined into one assistant.'),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
          child: OutlinedButton(onPressed: () => showLicensePage(context: context, applicationName: 'PhoneDots'), child: const Text('Open-source licences')),
        ),
      ]),
    );
  }
}
