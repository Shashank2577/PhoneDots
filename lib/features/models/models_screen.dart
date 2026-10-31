import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../app_state.dart';
import '../../core/models/model_manager.dart';
import '../../core/models/model_spec.dart';
import '../../core/util/format.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/sketch.dart';

class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final p = context.pal;
    return DoodlePage(
      title: 'Models',
      body: ListenableBuilder(
        listenable: Listenable.merge([s.models, s.settings]),
        builder: (context, _) {
          final m = s.models;
          final visible = m.visibleModels;
          final brains = visible.where((x) => x.provider == ModelProvider.gemma).toList();
          final specialists = visible.where((x) => x.provider == ModelProvider.desertAnt).toList();
          final ready = visible.where((x) => m.isReady(x.id)).length;
          return ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              Panel(
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Row(
                  children: [
                    _Stat(label: 'On device', value: '$ready / ${visible.length}'),
                    _Stat(label: 'Storage', value: formatBytes(m.storageUsed)),
                    _Stat(
                      label: 'Memory',
                      value: m.device.totalRamMb == 0 ? '—' : '${(m.device.totalRamMb / 1024).toStringAsFixed(0)} GB',
                    ),
                  ],
                ),
              ),
              if (m.loadError != null)
                Panel(
                  margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  color: p.danger.withValues(alpha: 0.06),
                  child: Text(m.loadError!, style: context.text.bodySmall?.copyWith(color: p.ink)),
                ),
              const SectionLabel('Gemma · the brain'),
              for (final spec in brains) ModelTile(spec: spec, services: s),
              const SectionLabel('Desert Ant · the specialists'),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                child: Text(
                  'Small models that each do one job very well. Skills download them when first needed.',
                  style: context.text.bodySmall,
                ),
              ),
              for (final spec in specialists) ModelTile(spec: spec, services: s),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
                child: Text(
                  'Downloads are the only time PhoneDots uses the network. Gemma files come from Hugging Face (litert-community) '
                  'and are checked against their SHA-256 before use.',
                  style: context.text.bodySmall,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Stat extends StatelessWidget {
  const _Stat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Expanded(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(value, style: context.text.titleLarge),
        const SizedBox(height: 2),
        Text(label, style: context.text.bodySmall),
      ],
    ),
  );
}

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
      ModelRole.planner when settings.plannerId == spec.id => 'Brain',
      ModelRole.router when settings.routerId == spec.id => 'Router',
      ModelRole.embedder when settings.embedderId == spec.id => 'Search',
      _ => null,
    };
    final loaded = m.loadedPlanner == spec.id || m.loadedRouter == spec.id;
    return Panel(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Dot(
                color: loaded
                    ? p.dot
                    : st.status == ModelStatus.ready
                    ? p.ink
                    : p.hairline,
              ),
              const SizedBox(width: 10),
              Expanded(child: Text(spec.name, style: context.text.titleMedium)),
              if (role != null) Tag(role, color: p.ink, filled: true),
            ],
          ),
          const SizedBox(height: 6),
          Text(spec.summary, style: context.text.bodySmall),
          const SizedBox(height: 10),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              Tag('${spec.provider == ModelProvider.desertAnt ? '≈ ' : ''}${formatBytes(spec.approxBytes)}'),
              if (spec.recommended) Tag('Recommended', color: p.dot, filled: true),
              if (spec.has(ModelCapability.image)) const Tag('Vision'),
              if (spec.has(ModelCapability.audio)) const Tag('Audio'),
              if (spec.has(ModelCapability.tools)) const Tag('Tools'),
              if (spec.has(ModelCapability.thinking)) const Tag('Thinking'),
              if (spec.beta) Tag('Beta', color: p.warn, filled: true),
              if (!m.fits(spec)) Tag('Needs ${(spec.minRamMb / 1000).round()} GB RAM', color: p.warn, filled: true),
            ],
          ),
          const SizedBox(height: 12),
          _Actions(spec: spec, services: services, state: st),
        ],
      ),
    );
  }
}

class _Actions extends StatelessWidget {
  const _Actions({required this.spec, required this.services, required this.state});
  final ModelSpec spec;
  final AppServices services;
  final ModelState state;

  @override
  Widget build(BuildContext context) {
    final m = services.models;
    final p = context.pal;
    switch (state.status) {
      case ModelStatus.downloading:
        final progress = Row(
          children: [
            Expanded(child: SketchProgress(value: state.progress == 0 || state.busyElsewhere ? null : state.progress)),
            const SizedBox(width: 12),
            Text('${(state.progress * 100).round()}%', style: context.text.bodySmall),
            if (spec.appDownloads || m.shared != null)
              IconButton(icon: const Icon(Icons.close_rounded, size: 18), onPressed: () => m.cancel(spec.id)),
          ],
        );
        if (!state.busyElsewhere) return progress;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            progress,
            Text(
              'Another app on this phone is downloading it; PhoneDots uses the same copy.',
              style: context.text.bodySmall?.copyWith(color: p.faint),
            ),
          ],
        );
      case ModelStatus.ready:
        final canUse = spec.role != ModelRole.specialist;
        final inUse = switch (spec.role) {
          ModelRole.planner => services.settings.plannerId == spec.id,
          ModelRole.router => services.settings.routerId == spec.id,
          ModelRole.embedder => services.settings.embedderId == spec.id,
          ModelRole.specialist => true,
        };
        return Row(
          children: [
            if (canUse && !inUse)
              FilledButton(
                onPressed: () => services.settings.update((s) {
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
                child: const Text('Use'),
              )
            else
              Text(
                spec.role == ModelRole.specialist ? 'Ready' : 'In use',
                style: context.text.bodySmall?.copyWith(color: p.dot),
              ),
            const Spacer(),
            TextButton(
              onPressed: () async {
                if (await confirmDialog(
                  context,
                  title: 'Delete ${spec.name}?',
                  body: m.shared == null
                      ? 'Frees ${formatBytes(spec.approxBytes)}. You can download it again later.'
                      : 'Frees ${formatBytes(spec.approxBytes)} unless another app on this phone still uses it. You can get it again later.',
                  confirm: 'Delete',
                  destructive: true,
                )) {
                  await m.delete(spec.id);
                }
              },
              child: Text('Delete', style: TextStyle(color: p.danger)),
            ),
          ],
        );
      case ModelStatus.failed:
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(state.error ?? 'Download failed', style: context.text.bodySmall?.copyWith(color: p.danger)),
            const SizedBox(height: 8),
            OutlinedButton(onPressed: () => m.download(spec.id), child: const Text('Try again')),
          ],
        );
      case ModelStatus.absent when state.inSibling:
        // Another app on this phone has it: getting it is a copy, no download.
        return Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => m.download(spec.id),
              icon: const Icon(Icons.devices_rounded, size: 18),
              label: const Text('Copy'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                'Already on this phone in another app, so no download',
                textAlign: TextAlign.right,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodySmall?.copyWith(color: p.dot, fontSize: 11),
              ),
            ),
          ],
        );
      case ModelStatus.absent:
        return Row(
          children: [
            OutlinedButton.icon(
              onPressed: () => m.download(spec.id),
              icon: const Icon(Icons.download_rounded, size: 18),
              label: const Text('Download'),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                spec.license,
                textAlign: TextAlign.right,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: context.text.bodySmall?.copyWith(color: p.faint, fontSize: 11),
              ),
            ),
          ],
        );
    }
  }
}
