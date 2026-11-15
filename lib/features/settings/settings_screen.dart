import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/app_log.dart';
import '../../core/crash_reporter.dart';
import '../../core/models/model_catalog.dart';
import '../../core/util/format.dart';
import '../../theme/theme.dart';
import '../../widgets/hand.dart';
import '../lab/lab_screen.dart';
import '../memory/memory_screen.dart';
import '../models/models_screen.dart';
import '../privacy/privacy_screen.dart';
import '../skills/skills_screen.dart';
import 'diagnostics_screen.dart';

/// The "you" tab: what it knows, what it can do, and the app itself.
class YouScreen extends StatelessWidget {
  const YouScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    String count(int n, String one, String many) => '$n ${n == 1 ? one : many}';
    return ListenableBuilder(
      listenable: Listenable.merge([s.memory, s.knowledge, s.ledger, s.skills, s.models, appLog]),
      builder: (context, _) => HandPage(
        wordmark: true,
        children: [
          const PageIntro('you', 'What it knows, what it can do, and how it behaves. All of it stays here.'),
          const SectionHead('what it knows', first: true),
          Door(
            'memory',
            meta: s.memory.facts.isEmpty
                ? 'Nothing yet'
                : '${count(s.memory.facts.length, 'thing', 'things')} you asked it to remember',
            onTap: () => push(const MemoryScreen()),
          ),
          Door(
            'my files',
            meta: '${count(s.knowledge.docs.length, 'document', 'documents')} it can search',
            onTap: () => push(const KnowledgeScreen()),
          ),
          const SectionHead('what it can do'),
          Door(
            'skills',
            meta: '${s.skills.enabled.length} on · recipes · community skills',
            onTap: () => openSkills(context),
          ),
          Door(
            'models',
            meta: '${formatBytes(s.models.storageUsed)} on this phone',
            onTap: () => openModels(context),
          ),
          const SectionHead('the app'),
          Door('settings', meta: 'Light or dark, handwriting, about', onTap: () => push(const SettingsScreen())),
          Door(
            'privacy',
            meta: '${count(s.ledger.networkEvents, 'network request', 'network requests')}, each one listed',
            onTap: () => push(const PrivacyScreen()),
          ),
          Door(
            'under the hood',
            meta: appLog.errorCount == 0
                ? 'Diagnostics and the lab'
                : '${count(appLog.errorCount, 'problem', 'problems')} logged · diagnostics and the lab',
            alert: appLog.errorCount > 0,
            onTap: () => push(const UnderTheHoodScreen()),
          ),
        ],
      ),
    );
  }
}

/// Diagnostics and the lab: for when something is wrong, or for the curious.
class UnderTheHoodScreen extends StatelessWidget {
  const UnderTheHoodScreen({super.key});

  @override
  Widget build(BuildContext context) {
    void push(Widget w) => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => w));
    return ListenableBuilder(
      listenable: appLog,
      builder: (context, _) => HandPage(
        children: [
          const PageIntro('under the hood', 'How PhoneDots works, step by step, and a bench to try the model on.'),
          Door(
            'diagnostics',
            meta: appLog.errorCount == 0
                ? 'What it did, step by step'
                : '${appLog.errorCount} problems logged · share the log',
            alert: appLog.errorCount > 0,
            onTap: () => push(const DiagnosticsScreen()),
          ),
          Door('lab', meta: 'Try prompts, measure speed', onTap: () => push(const LabScreen())),
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
  late final _yt = TextEditingController(text: AppScope.services(context).settings.youtubeKey);
  late final _jina = TextEditingController(text: AppScope.services(context).settings.jinaKey);
  bool _showToken = false;

  @override
  void dispose() {
    _token.dispose();
    _yt.dispose();
    _jina.dispose();
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
          ),
          if (st.typeNotice) ...[
            DoneNote(
              'Reading text is now a plain font. Change it under handwriting.',
              action: 'got it',
              onAction: () => st.update((x) => x.typeNotice = false),
            ),
            const SizedBox(height: 8),
          ],
          const SectionHead('light or dark', first: true),
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
          const SectionHead(
            'handwriting',
            note: 'Headlines and buttons stay hand-lettered. Pick how the text you read looks.',
          ),
          for (final v in Voice.values)
            Semantics(
              button: true,
              selected: Voice.byName(st.voice) == v,
              child: Pressable(
                onTap: () => st.update((x) => x.voice = v.name),
                scale: 0.99,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        width: 32,
                        child: Voice.byName(st.voice) == v ? const DrawnDoodle(Doodle.tick, size: 22) : null,
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(v.label, style: Hand.door.copyWith(color: p.ink), textScaler: Hand.scaler(context)),
                            Text(
                              'Nothing you say leaves this phone.',
                              style: context.type.body.copyWith(fontFamily: v.family, fontVariations: v.variations),
                            ),
                            Caption(v.note),
                          ],
                        ),
                      ),
                    ],
                  ),
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
          const SectionHead('saved posts'),
          SwitchRow(
            title: 'summarise when shared',
            body: 'Gemma summarises each post, reel or screenshot as soon as it arrives. Free, and on this phone.',
            value: st.autoSummarise,
            onChanged: (v) => st.update((x) => x.autoSummarise = v),
          ),
          SwitchRow(
            title: 'free web reader',
            body: 'When an open page only shares a line or two, ask Jina Reader for its full text. Free, but the link is sent to Jina. Never used on pages that ask you to log in. Logged under privacy.',
            value: st.webReader,
            onChanged: (v) => st.update((x) => x.webReader = v),
          ),
          const SizedBox(height: 8),
          const Body(
            'Optional free keys, stored on this phone only. Everything works without them.\n'
            '• YouTube Data API key: full video details even when YouTube rate-limits the page. '
            'Free at console.cloud.google.com (enable "YouTube Data API v3", create an API key). '
            '10,000 videos a day.\n'
            '• Jina key: raises the free web reader from about 20 to about 500 pages a minute. '
            'Free at jina.ai.',
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _yt,
            obscureText: true,
            onChanged: (v) => st.update((x) => x.youtubeKey = v.trim()),
            decoration: const InputDecoration(hintText: 'YouTube Data API key (optional)'),
          ),
          _KeyLinks(
            links: const [
              ('1 · turn on the API', 'https://console.cloud.google.com/apis/library/youtube.googleapis.com'),
              ('2 · create a key', 'https://console.cloud.google.com/apis/credentials'),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _jina,
            obscureText: true,
            onChanged: (v) => st.update((x) => x.jinaKey = v.trim()),
            decoration: const InputDecoration(hintText: 'Jina key (optional)'),
          ),
          const _KeyLinks(links: [('get a free Jina key', 'https://jina.ai/api-dashboard/key-manager')]),
          const SectionHead('more'),
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
            style: Hand.door.copyWith(color: p.ink),
            textScaler: Hand.scaler(context),
          ),
          Slider(value: st.temperature, max: 1.2, divisions: 12, onChanged: (v) => st.update((x) => x.temperature = v)),
          Text(
            'steps per answer · ${st.maxSteps}',
            style: Hand.door.copyWith(color: p.ink),
            textScaler: Hand.scaler(context),
          ),
          const Meta('How many skills it may chain before it has to answer.'),
          Slider(
            value: st.maxSteps.toDouble(),
            min: 1,
            max: 12,
            divisions: 11,
            onChanged: (v) => st.update((x) => x.maxSteps = v.round()),
          ),
          const SectionHead('Hugging Face'),
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
          const _KeyLinks(
            links: [
              ('create a token (read access)', 'https://huggingface.co/settings/tokens/new?tokenType=read'),
              (
                'accept the FunctionGemma licence',
                'https://huggingface.co/litert-community/functiongemma-270m-ft-mobile-actions',
              ),
            ],
          ),
          const SizedBox(height: 16),
          HandLink('show the welcome again', onTap: () => st.update((x) => x.onboarded = false)),
          const SectionHead('about'),
          Body('PhoneDots ${CrashReporter.appVersion}. An assistant that lives on your phone.'),
          for (final (title, body) in _about) ...[
            Padding(
              padding: const EdgeInsets.only(top: 16, bottom: 2),
              child: Text(title, style: context.type.rowTitle),
            ),
            Body(body),
          ],
          const SizedBox(height: 16),
          Align(
            alignment: Alignment.centerLeft,
            child: PillButton(
              'open-source licences',
              onTap: () => showLicensePage(context: context, applicationName: 'PhoneDots'),
            ),
          ),
        ],
      ),
    );
  }
}

const _about = [
  (
    'Gemma',
    'Gemma 4, FunctionGemma and EmbeddingGemma, under the Gemma Terms of Use (ai.google.dev/gemma/terms). Run with LiteRT-LM (Apache 2.0).',
  ),
  (
    'Desert Ant',
    'Specialist models by Desert Ant Labs, free up to 100k monthly active devices. Voz uses NVIDIA Parakeet TDT 0.6B v3 weights under CC BY 4.0.',
  ),
  (
    'The look',
    'The hand-drawn minimal design system from Burrow (Android-Showcase). Caveat, Inter, Nunito and Shantell Sans under the SIL Open Font License.',
  ),
  (
    'Inspiration',
    'Google AI Edge Gallery (Apache 2.0): ask image, audio scribe, prompt lab, agent skills and mobile actions in one assistant.',
  ),
];

/// One-tap links to the page where a key or token is made.
class _KeyLinks extends StatelessWidget {
  const _KeyLinks({required this.links});
  final List<(String, String)> links;

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    return Wrap(
      spacing: 12,
      children: [
        for (final (label, url) in links)
          HandLink('$label ↗', onTap: () => s.device.invoke('url.open', {'url': url})),
      ],
    );
  }
}
