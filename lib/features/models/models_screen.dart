import 'package:flutter/material.dart';

import '../../app_services.dart';
import '../../app_state.dart';
import '../../core/models/model_manager.dart';
import '../../core/models/model_spec.dart';
import '../../core/util/format.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';
import '../../widgets/hand.dart';

/// Opens the models page (it lives under "you").
void openModels(BuildContext context) =>
    Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ModelsScreen()));

class ModelsScreen extends StatelessWidget {
  const ModelsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    return HandPage(
      body: ListenableBuilder(
        listenable: Listenable.merge([s.models, s.settings]),
        builder: (context, _) {
          final m = s.models;
          final visible = m.visibleModels;
          final brains = visible.where((x) => x.provider == ModelProvider.gemma).toList();
          final specialists = visible.where((x) => x.provider == ModelProvider.desertAnt).toList();
          // Only the ones this phone has the memory for, so the count matches what starts.
          final missing = visible
              .where((x) => !m.isReady(x.id) && x.recommended && m.canTryDownload(x) && m.fits(x))
              .where((x) => m.state(x.id).status != ModelStatus.downloading)
              .toList();
          final missingBytes = missing.fold<int>(0, (a, x) => a + x.approxBytes);
          // Many missing: one pill at the top, and each row gets a quieter link.
          final compact = missing.length > 3;
          final used = formatBytes(m.storageUsed);
          return ListView(
            physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
            padding: const EdgeInsets.only(top: 8, bottom: 32),
            children: [
              const Column0(
                child: PageIntro(
                  'models',
                  'The AI behind PhoneDots. Each one downloads once, then runs on this phone\'s own chip. '
                      'Your words, photos and voice never go online.',
                ),
              ),
              Column0(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MarkedText('$used on this phone', mark: used, style: context.type.rowTitle),
                    if (m.device.totalRamMb > 0)
                      Caption('This phone has ${(m.device.totalRamMb / 1024).toStringAsFixed(0)} GB of memory'),
                  ],
                ),
              ),
              if (compact)
                Column0(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        PillButton(
                          'download all (${formatBytes(missingBytes)})',
                          leading: Doodle.arrow,
                          onTap: () {
                            for (final x in missing) {
                              m.download(x.id);
                            }
                          },
                        ),
                        Padding(
                          padding: const EdgeInsets.only(top: 6),
                          child: Meta('The ${missing.length} models PhoneDots uses that fit this phone.'),
                        ),
                      ],
                    ),
                  ),
                ),
              if (m.loadError != null)
                Column0(
                  child: Padding(padding: const EdgeInsets.only(top: 12), child: Warning(m.loadError!)),
                ),
              const Column0(child: SectionHead('the brain', note: 'Gemma: talks, plans, sees and searches')),
              for (final (i, spec) in brains.indexed)
                Column0(
                  child: Enter(
                    index: i,
                    child: ModelTile(spec: spec, services: s, compact: compact),
                  ),
                ),
              const Column0(child: SectionHead('helpers', note: 'Desert Ant specialists, one job each')),
              for (final (i, spec) in specialists.indexed)
                Column0(
                  child: Enter(
                    index: i,
                    child: ModelTile(spec: spec, services: s, compact: compact),
                  ),
                ),
              const Column0(
                child: Padding(
                  padding: EdgeInsets.only(top: 24),
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

/// One model: its name with real capitals and its size, what it does at full
/// width, then its state on its own line (a button under the text, never
/// beside it).
class ModelTile extends StatelessWidget {
  const ModelTile({super.key, required this.spec, required this.services, this.compact = false});
  final ModelSpec spec;
  final AppServices services;

  /// Quieter per-row actions, when one "download all" pill sits at the top.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final t = context.type;
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
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(spec.name, style: t.rowTitle),
                    if (role != null) HandTag(role),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Padding(padding: const EdgeInsets.only(top: 3), child: Caption(size)),
            ],
          ),
          Padding(padding: const EdgeInsets.only(top: 2), child: Meta(spec.summary)),
          if (notes.isNotEmpty) Caption(notes.join(' · ')),
          if (st.status == ModelStatus.downloading)
            Padding(padding: const EdgeInsets.only(top: 8), child: HandProgress(st.progress == 0 ? null : st.progress)),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: _Action(spec: spec, services: services, state: st, compact: compact),
          ),
          HandDivider(padding: const EdgeInsets.only(top: 10), seed: spec.id.length),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action({required this.spec, required this.services, required this.state, required this.compact});
  final ModelSpec spec;
  final AppServices services;
  final ModelState state;
  final bool compact;

  Widget _button(String label, VoidCallback onTap, {Doodle? leading}) =>
      compact ? HandLink(label, onTap: onTap) : PillButton(label, leading: leading, onTap: onTap);

  @override
  Widget build(BuildContext context) {
    final m = services.models;
    final p = context.pal;
    switch (state.status) {
      case ModelStatus.downloading:
        final cancel = spec.appDownloads || m.shared != null;
        return Row(
          children: [
            Expanded(
              child: Caption(
                state.busyElsewhere
                    ? 'Another app on this phone is downloading it'
                    : 'Downloading, ${(state.progress * 100).round()}%',
              ),
            ),
            if (cancel)
              DoodleButton(Doodle.close, tooltip: 'Cancel', size: 20, color: p.pencil, onTap: () => m.cancel(spec.id))
            else
              const Padding(padding: EdgeInsets.all(14), child: Scribbling(size: 20)),
          ],
        );
      case ModelStatus.absent when state.inSibling:
        // Another app on this phone has it: getting it is a copy, no download.
        return Align(
          alignment: Alignment.centerLeft,
          child: _button('copy, no download', () => m.download(spec.id), leading: Doodle.phone),
        );
      case ModelStatus.failed:
      case ModelStatus.absent:
        final failed = state.status == ModelStatus.failed;
        final Widget action;
        if (!m.canTryDownload(spec) || (spec.gated && failed)) {
          action = _button('get access', () => showGetAccess(context, services, spec), leading: Doodle.lock);
        } else {
          action = _button(failed ? 'retry' : 'download', () => m.download(spec.id));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (failed)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Warning(state.error ?? 'The download failed.'),
              ),
            action,
          ],
        );
      case ModelStatus.ready:
        final inUse = switch (spec.role) {
          ModelRole.planner => services.settings.plannerId == spec.id,
          ModelRole.router => services.settings.routerId == spec.id,
          ModelRole.embedder => services.settings.embedderId == spec.id,
          ModelRole.specialist => true,
        };
        return Row(
          children: [
            DoodleIcon(Doodle.tick, size: 18, color: p.pencil),
            const SizedBox(width: 6),
            const Expanded(child: Caption('On this phone')),
            if (!inUse)
              HandLink(
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
              color: p.pencil,
              onTap: () async {
                if (await confirmDialog(
                  context,
                  title: 'delete ${spec.name}?',
                  body: m.shared == null
                      ? 'Frees ${formatBytes(spec.approxBytes)}. You can download it again later.'
                      : 'Frees ${formatBytes(spec.approxBytes)} unless another app on this phone still uses it. You can get it again later.',
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
    final name = spec.name;
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
                    : Warning(message),
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
