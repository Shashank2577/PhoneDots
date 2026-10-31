import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/models/model_catalog.dart';
import '../../core/util/format.dart';
import '../../theme/theme.dart';
import '../../widgets/hand.dart';
import '../privacy/privacy_screen.dart';

/// First launch: what PhoneDots is, then a one-time model setup.
class Onboarding extends StatefulWidget {
  const Onboarding({super.key});

  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  int _page = 0;
  bool _downloading = false;

  static const _starter = [
    'gemma-4-e2b',
    'functiongemma-270m-mobile-actions',
    'embeddinggemma-2-text-270m',
    'desertant.voz',
    'desertant.who',
    'desertant.redact',
  ];

  void _finish() => AppScope.services(context).settings.update((x) => x.onboarded = true);

  void _download() {
    final s = AppScope.services(context);
    for (final id in _starter) {
      final m = modelById(id);
      // Gated models (FunctionGemma) wait until the user grants access under models.
      if (m != null && m.supports(s.platform) && s.models.fits(m) && s.models.canTryDownload(m)) s.models.download(id);
    }
    setState(() => _downloading = true);
  }

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: const Duration(milliseconds: 280),
    child: KeyedSubtree(key: ValueKey(_page), child: _page == 0 ? _welcome(context) : _setup(context)),
  );

  Widget _welcome(BuildContext context) => HandPage(
    wordmark: true,
    bottom: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        InkButton('let\'s start', trailing: Doodle.arrow, expand: true, onTap: () => setState(() => _page = 1)),
        HandLink(
          'how does privacy work?',
          onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const PrivacyScreen())),
        ),
      ],
    ),
    children: [
      const SizedBox(height: 40),
      const Enter(
        child: MarkedText('your phone,\nyour assistant.', mark: 'assistant', style: Hand.display),
      ),
      const SizedBox(height: 16),
      const Enter(
        index: 1,
        child: Body(
          'PhoneDots chats, plans, transcribes meetings, reads photos and works your phone, with Google\'s Gemma '
          'and Desert Ant\'s specialist models running right here. Nothing you give it is uploaded.',
        ),
      ),
      const SizedBox(height: 28),
      for (final (i, (d, title, meta)) in [
        (Doodle.lock, 'nothing leaves this phone', 'no account, no cloud, no tracking'),
        (Doodle.tick, 'it asks first', 'before it calls, texts, emails or reads your contacts'),
        (Doodle.close, 'delete means delete', 'one tap forgets a chat, a memory or everything'),
      ].indexed)
        Enter(
          index: 2 + i,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                DoodleIcon(d, size: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: Hand.label.copyWith(fontSize: 24, color: context.pal.ink)),
                      Meta(meta),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
    ],
  );

  Widget _setup(BuildContext context) {
    final s = AppScope.services(context);
    final starter = [for (final id in _starter) ?modelById(id)].where((m) => m.supports(s.platform)).toList();
    final total = starter.fold<int>(0, (a, m) => a + m.approxBytes);
    return HandPage(
      onBack: () => setState(() => _page = 0),
      bottom: InkButton(
        _downloading ? 'start' : 'start · download later',
        trailing: Doodle.arrow,
        expand: true,
        onTap: _finish,
      ),
      children: [
        const Enter(
          child: MarkedText('you decide what PhoneDots downloads.', mark: 'you decide', style: Hand.headline),
        ),
        const SizedBox(height: 8),
        const Enter(
          index: 1,
          child: Body('The models download once. Wi-Fi is best. After that PhoneDots works with no internet at all.'),
        ),
        const HandDivider(padding: EdgeInsets.symmetric(vertical: 18)),
        Enter(
          index: 2,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('one-time setup', style: Hand.title.copyWith(fontSize: 27, color: context.pal.ink)),
              const SizedBox(width: 10),
              Padding(padding: const EdgeInsets.only(bottom: 4), child: Meta('about ${formatBytes(total)}')),
            ],
          ),
        ),
        const SizedBox(height: 6),
        Enter(index: 3, child: Meta(starter.map((m) => m.name.toLowerCase()).join('  ·  '))),
        const SizedBox(height: 14),
        Enter(
          index: 4,
          child: Align(
            alignment: Alignment.centerLeft,
            child: _downloading
                ? const Row(
                    children: [
                      DrawnDoodle(Doodle.tick, size: 22),
                      SizedBox(width: 8),
                      Expanded(child: Body('downloading, carry on while it runs')),
                    ],
                  )
                : PillButton('download the models', leading: Doodle.plus, onTap: _download),
          ),
        ),
        const SizedBox(height: 22),
        const Enter(
          index: 5,
          child: Meta(
            'Gemma files come from Hugging Face and are checked against their SHA-256. You can add or remove models any time under models.',
          ),
        ),
      ],
    );
  }
}
