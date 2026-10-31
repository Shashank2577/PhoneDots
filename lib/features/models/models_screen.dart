import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../app_state.dart';
import '../../core/models/model_manager.dart';
import '../../core/models/model_spec.dart';
import '../../core/util/format.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/hand.dart';

class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    return HandPage(
      wordmark: true,
      body: ListenableBuilder(
        listenable: Listenable.merge([s.models, s.settings]),
        builder: (context, _) {
          final m = s.models;
          final visible = m.visibleModels;
          final brains = visible.where((x) => x.provider == ModelProvider.gemma).toList();
          final specialists = visible.where((x) => x.provider == ModelProvider.desertAnt).toList();
          final missing = visible.where((x) => !m.isReady(x.id) && x.recommended).toList();
          final used = formatBytes(m.storageUsed);
          return ListView(
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              Column0(
                child: PageIntro(
                  'the models',
                  'The AI behind PhoneDots. Each one is downloaded once, then runs on this phone\'s own chip. '
                      'Your words, photos and voice never go to the internet.',
                  doodle: Doodle.spark,
                ),
              ),
              Column0(
                child: Row(
                  children: [
                    MarkedText('$used on this phone', mark: used, style: Hand.label.copyWith(fontSize: 22)),
                    const Spacer(),
                    if (m.device.totalRamMb > 0) Meta('${(m.device.totalRamMb / 1024).toStringAsFixed(0)} GB memory'),
                  ],
                ),
              ),
              if (missing.isNotEmpty)
                Column0(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: PillButton(
                        'download the ${missing.length} recommended',
                        leading: Doodle.arrow,
                        onTap: () {
                          for (final x in missing) {
                            if (m.fits(x)) m.download(x.id);
                          }
                        },
                      ),
                    ),
                  ),
                ),
              if (m.loadError != null)
                Column0(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        DoodleIcon(Doodle.exclaim, size: 20, color: context.pal.redPen, stroke: 2.6),
                        const SizedBox(width: 6),
                        Expanded(child: Body(m.loadError!)),
                      ],
                    ),
                  ),
                ),
              const Column0(child: SectionHead('gemma · the brain', note: 'talks, plans, sees')),
              for (final (i, spec) in brains.indexed)
                Column0(
                  child: Enter(
                    index: i,
                    child: ModelTile(spec: spec, services: s),
                  ),
                ),
              const Column0(child: SectionHead('desert ant · the specialists', note: 'one job each')),
              for (final (i, spec) in specialists.indexed)
                Column0(
                  child: Enter(
                    index: i,
                    child: ModelTile(spec: spec, services: s),
                  ),
                ),
              const Column0(
                child: Padding(
                  padding: EdgeInsets.only(top: 16),
                  child: Meta(
                    'Downloads are the only time PhoneDots uses the network. Gemma files come from Hugging Face '
                    '(litert-community) and are checked against their SHA-256 before use.',
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

/// One model as a line on the page: "voz · 470 MB", what it does, and its state.
class ModelTile extends StatelessWidget {
  const ModelTile({super.key, required this.spec, required this.services});
  final ModelSpec spec;
  final AppServices services;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final m = services.models;
    final st = m.state(spec.id);
    final settings = services.settings;
    final role = switch (spec.role) {
      ModelRole.planner when settings.plannerId == spec.id => 'brain',
      ModelRole.router when settings.routerId == spec.id => 'router',
      ModelRole.embedder when settings.embedderId == spec.id => 'search',
      _ => null,
    };
    final size = '${spec.provider == ModelProvider.desertAnt ? '~' : ''}${formatBytes(spec.approxBytes)}';
    final notes = [
      if (spec.has(ModelCapability.image)) 'sees',
      if (spec.has(ModelCapability.audio)) 'hears',
      if (spec.has(ModelCapability.tools)) 'uses tools',
      if (spec.has(ModelCapability.thinking)) 'thinks',
      if (!m.fits(spec)) 'needs ${(spec.minRamMb / 1000).round()} GB memory',
      if (spec.beta) 'beta',
    ];
    final status = switch (st.status) {
      ModelStatus.ready => 'on this phone',
      ModelStatus.downloading => 'downloading ${(st.progress * 100).round()}%',
      ModelStatus.failed => st.error ?? 'download failed',
      ModelStatus.absent => 'not downloaded yet',
    };
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            '${spec.name.toLowerCase()} · $size',
                            style: Hand.label.copyWith(fontSize: 23, color: p.ink),
                          ),
                        ),
                        if (role != null) ...[const SizedBox(width: 8), HandTag(role, marked: true)],
                      ],
                    ),
                    Meta(spec.summary),
                    if (notes.isNotEmpty) Meta(notes.join(' · '), color: p.graphite),
                    Meta(status, color: st.status == ModelStatus.failed ? p.redPen : p.pencil),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _Action(spec: spec, services: services, state: st),
            ],
          ),
          if (st.status == ModelStatus.downloading)
            Padding(padding: const EdgeInsets.only(top: 8), child: HandProgress(st.progress == 0 ? null : st.progress)),
          const HandDivider(padding: EdgeInsets.only(top: 12)),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.spec, required this.services, required this.state});
  final ModelSpec spec;
  final AppServices services;
  final ModelState state;

  @override
  Widget build(BuildContext context) {
    final m = services.models;
    final p = context.pal;
    switch (state.status) {
      case ModelStatus.downloading:
        return spec.appDownloads
            ? DoodleButton(Doodle.close, tooltip: 'Cancel', onTap: () => m.cancel(spec.id))
            : const Scribbling(size: 20);
      case ModelStatus.failed:
      case ModelStatus.absent:
        return PillButton(state.status == ModelStatus.failed ? 'retry' : 'download', onTap: () => m.download(spec.id));
      case ModelStatus.ready:
        final inUse = switch (spec.role) {
          ModelRole.planner => services.settings.plannerId == spec.id,
          ModelRole.router => services.settings.routerId == spec.id,
          ModelRole.embedder => services.settings.embedderId == spec.id,
          ModelRole.specialist => true,
        };
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (!inUse)
              PillButton(
                'use',
                onTap: () => services.settings.update((s) {
                  switch (spec.role) {
                    case ModelRole.planner:
                      s.plannerId = spec.id;
                    case ModelRole.router:
                      s.routerId = spec.id;
                    case ModelRole.embedder:
                      s.embedderId = spec.id;
                    case ModelRole.specialist:
                  }
                }),
              ),
            DoodleButton(
              Doodle.trash,
              tooltip: 'Delete',
              size: 20,
              color: p.redPen,
              onTap: () async {
                if (await confirmDialog(
                  context,
                  title: 'delete ${spec.name.toLowerCase()}?',
                  body: 'Frees ${formatBytes(spec.approxBytes)}. You can download it again later.',
                  confirm: 'delete',
                  destructive: true,
                )) {
                  await m.delete(spec.id);
                }
              },
            ),
          ],
        );
    }
  }
}
