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
          final missing = visible.where((x) => !m.isReady(x.id) && x.recommended && m.canTryDownload(x)).toList();
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
      if (spec.gated && !m.isReady(spec.id)) 'needs a free Hugging Face OK',
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
        if (!m.canTryDownload(spec) || (spec.gated && state.status == ModelStatus.failed)) {
          return PillButton('get access', leading: Doodle.lock, onTap: () => showGetAccess(context, services, spec));
        }
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

/// Walks through Google's licence gate for a gated model: accept on the
/// model page, make a read token, paste it, check, download.
void showGetAccess(BuildContext context, AppServices services, ModelSpec spec) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => Padding(
    padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
    child: _GetAccess(services: services, spec: spec),
  ),
);

class _GetAccess extends StatefulWidget {
  const _GetAccess({required this.services, required this.spec});
  final AppServices services;
  final ModelSpec spec;

  @override
  State<_GetAccess> createState() => _GetAccessState();
}

class _GetAccessState extends State<_GetAccess> {
  late final _token = TextEditingController(text: widget.services.settings.hfToken);
  Access? _result;
  bool _checking = false;

  @override
  void dispose() {
    _token.dispose();
    super.dispose();
  }

  void _open(String url) => widget.services.device.invoke('url.open', {'url': url});

  Future<void> _check() async {
    setState(() => _checking = true);
    await widget.services.settings.update((x) => x.hfToken = _token.text.trim());
    final r = await widget.services.models.checkAccess(widget.spec);
    if (mounted) {
      setState(() {
        _result = r;
        _checking = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final spec = widget.spec;
    final p = context.pal;
    final name = spec.name.toLowerCase();
    final message = switch (_result) {
      Access.ok => 'You\'re in. $name can download now.',
      Access.needsToken => 'Paste a token first (step 2).',
      Access.badToken => 'Hugging Face didn\'t accept that token. Make a new "read" token and paste it again.',
      Access.needsLicence => 'Token works, but the licence isn\'t accepted yet. Do step 1, then check again.',
      Access.unknown => 'Couldn\'t reach Hugging Face. Check your connection and try again.',
      null => null,
    };
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(gutter, 0, gutter, 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            PageIntro(
              'get access',
              'Google asks everyone to accept the Gemma licence before $name downloads. It\'s free, takes a minute, '
                  'and you only do it once.',
              doodle: Doodle.lock,
            ),
            const Steps([
              'Open the model page, sign in to Hugging Face and tap "Agree and access repository".',
              'Make a token with "read" access and copy it.',
              'Paste it below and check. It\'s stored on this phone only.',
            ]),
            const SizedBox(height: 12),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                PillButton('1 · model page', leading: Doodle.arrow, onTap: () => _open(spec.hfPage!)),
                PillButton(
                  '2 · make a token',
                  leading: Doodle.arrow,
                  onTap: () => _open('https://huggingface.co/settings/tokens/new?tokenType=read'),
                ),
              ],
            ),
            const SizedBox(height: 14),
            TextField(
              controller: _token,
              autocorrect: false,
              decoration: const InputDecoration(hintText: '3 · paste the token (hf_…)'),
            ),
            const SizedBox(height: 12),
            if (message != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _result == Access.ok
                    ? DoneNote(message)
                    : Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          DoodleIcon(Doodle.exclaim, size: 20, color: p.redPen, stroke: 2.6),
                          const SizedBox(width: 6),
                          Expanded(child: Body(message)),
                        ],
                      ),
              ),
            if (_result == Access.ok)
              InkButton(
                'download $name',
                trailing: Doodle.arrow,
                expand: true,
                onTap: () {
                  widget.services.models.download(spec.id);
                  Navigator.pop(context);
                },
              )
            else
              InkButton('check access', busy: _checking, expand: true, onTap: _check),
          ],
        ),
      ),
    );
  }
}
