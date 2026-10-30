import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/models/model_catalog.dart';
import '../../core/util/format.dart';
import '../../theme/theme.dart';
import '../../theme/rough.dart';
import '../../widgets/common.dart';
import '../../widgets/sketch.dart';

/// First launch: explain the idea, then offer the recommended downloads.
class Onboarding extends StatefulWidget {
  const Onboarding({super.key});

  @override
  State<Onboarding> createState() => _OnboardingState();
}

class _OnboardingState extends State<Onboarding> {
  final _pages = PageController();
  int _page = 0;

  static const _starter = [
    'gemma-4-e2b',
    'functiongemma-270m-mobile-actions',
    'embeddinggemma-2-text-270m',
    'desertant.voz',
    'desertant.who',
    'desertant.redact',
  ];

  @override
  void dispose() {
    _pages.dispose();
    super.dispose();
  }

  void _done({bool download = false}) {
    final s = AppScope.services(context);
    if (download) {
      for (final id in _starter) {
        final m = modelById(id);
        if (m != null && m.supports(s.platform) && s.models.fits(m)) s.models.download(id);
      }
    }
    s.settings.update((x) => x.onboarded = true);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final s = AppScope.services(context);
    final starter = [for (final id in _starter) ?modelById(id)].where((m) => m.supports(s.platform)).toList();
    final total = starter.fold<int>(0, (a, m) => a + m.approxBytes);
    final pages = [
      _Page(
        title: 'AI that lives\non your phone',
        body:
            'PhoneDots runs Google\'s Gemma models and Desert Ant\'s specialist models entirely on this device. '
            'No account. No cloud. Works in airplane mode.',
        visual: Stack(
          alignment: Alignment.center,
          children: [
            DrawnPath(
              size: const Size(200, 150),
              color: p.highlight,
              width: 14,
              duration: const Duration(milliseconds: 900),
              builder: (s) => Rough.scribbleCircle((Offset.zero & s).deflate(14), seed: 8, turns: 1.2),
            ),
            const HoppingDots(size: 26),
          ],
        ),
      ),
      _Page(
        title: 'One brain,\nmany hands',
        body:
            'Gemma plans and talks. Specialists transcribe, label speakers, redact private details and understand photos. '
            'Skills connect them to your phone, your files and each other.',
        visual: Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (final t in [
              'Transcribe',
              'Who said what',
              'Redact',
              'Ask a photo',
              'Timers',
              'Search my files',
              'Recipes',
            ].indexed)
              Enter(
                index: t.$1,
                tilt: 0.2,
                child: Transform.rotate(
                  angle: (t.$1 % 3 - 1) * 0.05,
                  child: SketchBox(
                    seed: 700 + t.$1,
                    fill: p.note(t.$1),
                    radius: 5,
                    shadow: 2,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Text(t.$2, style: context.text.bodyLarge),
                  ),
                ),
              ),
          ],
        ),
      ),
      _Page(
        title: 'Get the\nstarter set',
        body: 'About ${formatBytes(total)}. Downloads are the only time the app goes online. Use Wi-Fi.',
        visual: SketchBox(
          seed: 901,
          shadow: 3,
          padding: const EdgeInsets.all(14),
          child: Column(
            children: [
              for (final m in starter)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 5),
                  child: Row(
                    children: [
                      Dot(color: p.ink, size: 6),
                      const SizedBox(width: 10),
                      Expanded(child: Text(m.name, style: context.text.bodyMedium)),
                      Text(formatBytes(m.approxBytes), style: context.text.bodySmall),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    ];
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            Align(
              alignment: Alignment.centerRight,
              child: TextButton(
                onPressed: _done,
                child: Text('Skip', style: TextStyle(color: p.muted)),
              ),
            ),
            Expanded(
              child: PageView(controller: _pages, onPageChanged: (i) => setState(() => _page = i), children: pages),
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (var i = 0; i < pages.length; i++)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: i == _page ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: i == _page ? p.ink : p.hairline,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
              child: SizedBox(
                width: double.infinity,
                child: _page < pages.length - 1
                    ? FilledButton(
                        onPressed: () =>
                            _pages.nextPage(duration: const Duration(milliseconds: 300), curve: Curves.easeOut),
                        child: const Text('Continue'),
                      )
                    : Column(
                        children: [
                          SizedBox(
                            width: double.infinity,
                            child: FilledButton(
                              onPressed: () => _done(download: true),
                              child: const Text('Download starter set'),
                            ),
                          ),
                          const SizedBox(height: 8),
                          TextButton(onPressed: _done, child: const Text('Choose later')),
                        ],
                      ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Page extends StatelessWidget {
  const _Page({required this.title, required this.body, required this.visual});
  final String title;
  final String body;
  final Widget visual;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    // Centred when it fits, scrollable on short screens.
    builder: (context, box) => SingleChildScrollView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: box.maxHeight),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Center(child: Enter(child: visual)),
            const SizedBox(height: 40),
            Enter(index: 2, child: Text(title, style: context.text.displaySmall?.copyWith(fontSize: 54, height: 0.95))),
            Enter(index: 3, child: Underline(width: 170, seed: title.length)),
            const SizedBox(height: 12),
            Enter(
              index: 4,
              child: Text(body, style: context.text.bodyLarge?.copyWith(color: context.pal.muted)),
            ),
          ],
        ),
      ),
    ),
  );
}
