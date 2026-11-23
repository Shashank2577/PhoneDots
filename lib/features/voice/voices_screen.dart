import 'dart:async';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../core/util/format.dart';
import '../../theme/theme.dart';
import '../../voice/speech_text.dart';
import '../../voice/voice_catalog.dart';
import '../../voice/voice_manager.dart';
import '../../widgets/common.dart';
import '../../widgets/hand.dart';

/// Choose how PhoneDots sounds: listen to a voice, then download it.
class VoicesScreen extends StatefulWidget {
  const VoicesScreen({super.key});

  @override
  State<VoicesScreen> createState() => _VoicesScreenState();
}

class _VoicesScreenState extends State<VoicesScreen> {
  VoiceSource _filter = VoiceSource.donated;
  int _shown = 24;
  final _try = TextEditingController(text: 'Hi! I found three recipes you will love. The quickest takes ten minutes.');
  Mood _tryMood = Mood.happy;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(AppScope.services(context).voices.refreshCatalog());
    });
  }

  @override
  void dispose() {
    _try.dispose();
    super.dispose();
  }

  Future<void> _listen(String urlOrPath, String what) async {
    final s = AppScope.services(context);
    if (urlOrPath.startsWith('http')) {
      unawaited(s.ledger.record('voice', 'Played a voice sample ($what) from huggingface.co', network: true));
    }
    try {
      await s.speaker.preview(urlOrPath);
    } catch (e) {
      if (mounted) toast(context, 'Could not play the sample: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = AppScope.services(context);
    final p = context.pal;
    final v = s.voices;
    return ListenableBuilder(
      listenable: Listenable.merge([v, s.settings]),
      builder: (context, _) {
        final installed = [
          for (final x in v.catalog)
            if (v.installed.contains(x.id)) x,
        ];
        final list = [
          for (final x in v.offered)
            if (x.source == _filter && !v.installed.contains(x.id)) x,
        ];
        return HandPage(
          children: [
            const PageIntro(
              'voices',
              'Natural voices made on this phone. Listen to one, then download it: about 1 MB a voice. '
                  'Voices with feelings can sound happy, calm, whispering or laughing as the conversation needs.',
              mark: 'on this phone',
              doodle: Doodle.wave,
            ),
            _EngineCard(v),
            const SectionHead('how it speaks'),
            SwitchRow(
              title: 'speak with feeling',
              body: 'With a voice that has moods, the assistant picks the tone for each sentence.',
              value: s.settings.expressiveSpeech,
              onChanged: (x) => s.settings.update((st) => st.expressiveSpeech = x),
            ),
            Text(
              'speed · ${s.settings.voiceSpeed.toStringAsFixed(1)}×',
              style: Hand.label.copyWith(fontSize: 23, color: p.ink),
            ),
            Slider(
              value: s.settings.voiceSpeed,
              min: 0.7,
              max: 1.4,
              divisions: 7,
              onChanged: (x) => s.settings.update((st) => st.voiceSpeed = x),
            ),
            SwitchRow(
              title: 'personal-use voices',
              body:
                  'Show the voices with feelings. Their recordings (Meta\'s Expresso set) may only be used '
                  'personally, not in anything commercial.',
              value: s.settings.personalUseVoices,
              onChanged: (x) => s.settings.update((st) => st.personalUseVoices = x),
            ),
            const SectionHead('your voice'),
            _VoiceRow(
              name: 'the phone\'s own voice',
              meta: 'built in, no download',
              selected: s.settings.voiceId == 'system',
              onUse: () => s.settings.update((st) => st.voiceId = 'system'),
            ),
            for (final x in installed)
              _VoiceRow(
                name: x.name,
                meta: '${x.expressive ? '${x.clips.length} moods · ' : ''}${x.licence}',
                selected: s.settings.voiceId == x.id,
                enabled: v.engine == EngineStatus.ready && (!x.personalUseOnly || s.settings.personalUseVoices),
                onListen: () => _listen(v.clipPath(x.id, Mood.neutral)!, x.name),
                onUse: () => s.settings.update((st) => st.voiceId = x.id),
                onRemove: () => v.removeVoice(x),
                moods: x.expressive ? [for (final m in x.clips.keys) m] : const [],
                onMood: (m) => _listen(v.clipPath(x.id, m)!, '${x.name} ${m.name}'),
              ),
            if (v.selected != null) ...[
              const SectionHead('try it'),
              TextField(controller: _try, maxLines: 3, minLines: 1),
              const SizedBox(height: 8),
              if (v.selected!.expressive)
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final m in v.selected!.clips.keys)
                      ChoicePill(m.name, selected: _tryMood == m, onTap: () => setState(() => _tryMood = m)),
                  ],
                ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerLeft,
                child: PillButton(
                  'say it',
                  leading: Doodle.play,
                  onTap: () => s.speaker.say(
                    SpeechChunk(speakable(_try.text), v.selected!.expressive ? _tryMood : Mood.neutral),
                  ),
                ),
              ),
            ],
            const SectionHead('find a voice'),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                ChoicePill(
                  'donated',
                  selected: _filter == VoiceSource.donated,
                  onTap: () => setState(() => _filter = VoiceSource.donated),
                ),
                ChoicePill(
                  'VCTK',
                  selected: _filter == VoiceSource.vctk,
                  onTap: () => setState(() => _filter = VoiceSource.vctk),
                ),
                if (s.settings.personalUseVoices)
                  ChoicePill(
                    'with feelings',
                    leading: Doodle.heart,
                    selected: _filter == VoiceSource.expressive,
                    onTap: () => setState(() => _filter = VoiceSource.expressive),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Meta(switch (_filter) {
              VoiceSource.donated => 'Real people who gave their voices to Kyutai\'s project (CC0): free for anything.',
              VoiceSource.vctk => 'Speakers from the VCTK corpus (CC BY 4.0, University of Edinburgh).',
              VoiceSource.expressive => 'The same speakers in many moods. Personal, non-commercial use only.',
            }),
            if (list.isEmpty) const HandEmpty(title: 'no more voices here', doodle: Doodle.wave),
            for (final x in list.take(_shown))
              _VoiceRow(
                name: x.name,
                meta: x.expressive ? '${x.clips.length} moods' : 'listen first, about 1 MB',
                progress: v.voiceProgress[x.id],
                onListen: () => _listen(x.sampleUrl, x.name),
                moods: x.expressive ? [for (final m in x.clips.keys) m] : const [],
                onMood: (m) => _listen(x.clips[m]!, '${x.name} ${m.name}'),
                downloadLabel: x.expressive ? 'download · ~${x.clips.length} MB' : 'download',
                onDownload: () async {
                  if (await v.installVoice(x) && context.mounted) {
                    if (v.engine == EngineStatus.ready) await s.settings.update((st) => st.voiceId = x.id);
                    if (context.mounted) toast(context, '${x.name} is ready');
                  }
                },
              ),
            if (list.length > _shown)
              HandLink(
                'show ${list.length - _shown < 24 ? list.length - _shown : 24} more',
                onTap: () => setState(() => _shown += 24),
              ),
            const SizedBox(height: 12),
            Meta(PocketEngine.licence, color: p.graphite),
          ],
        );
      },
    );
  }
}

class _EngineCard extends StatelessWidget {
  const _EngineCard(this.v);
  final VoiceManager v;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            DoodleIcon(v.engine == EngineStatus.ready ? Doodle.tick : Doodle.chip, size: 20, color: p.ink),
            const SizedBox(width: 8),
            Expanded(
              child: Text('the voice engine', style: Hand.label.copyWith(fontSize: 23, color: p.ink)),
            ),
          ],
        ),
        Meta(switch (v.engine) {
          EngineStatus.ready => 'Pocket TTS is ready. Every word is made on this phone.',
          EngineStatus.downloading => 'downloading… ${(v.engineProgress * 100).round()}%',
          EngineStatus.unpacking => 'unpacking…',
          EngineStatus.failed => v.engineError ?? 'Something went wrong.',
          EngineStatus.absent =>
            'Kyutai\'s Pocket TTS: one download of ${formatBytes(PocketEngine.archiveBytes)} '
                '(${formatBytes(PocketEngine.installedBytes)} on the phone). Needed for natural voices.',
        }, color: v.engine == EngineStatus.failed ? p.redPen : null),
        if (v.engine == EngineStatus.downloading) ...[const SizedBox(height: 8), HandProgress(v.engineProgress)],
        const SizedBox(height: 8),
        if (v.engine == EngineStatus.absent || v.engine == EngineStatus.failed)
          PillButton('download the engine', leading: Doodle.arrow, onTap: v.installEngine)
        else if (v.engine == EngineStatus.downloading)
          HandLink('cancel', onTap: v.cancelEngine),
      ],
    );
  }
}

class _VoiceRow extends StatelessWidget {
  const _VoiceRow({
    required this.name,
    required this.meta,
    this.selected = false,
    this.enabled = true,
    this.progress,
    this.onListen,
    this.onUse,
    this.onRemove,
    this.onDownload,
    this.downloadLabel = 'download',
    this.moods = const [],
    this.onMood,
  });

  final String name;
  final String meta;
  final bool selected;
  final bool enabled;
  final double? progress;
  final VoidCallback? onListen;
  final VoidCallback? onUse;
  final VoidCallback? onRemove;
  final VoidCallback? onDownload;
  final String downloadLabel;
  final List<Mood> moods;
  final void Function(Mood m)? onMood;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (onListen != null) DoodleButton(Doodle.play, tooltip: 'Listen to $name', size: 20, onTap: onListen),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    MarkedText(name, mark: selected ? name : null, style: Hand.label.copyWith(fontSize: 22)),
                    Meta(meta, maxLines: 2),
                  ],
                ),
              ),
              if (progress != null)
                SizedBox(width: 60, child: HandProgress(progress))
              else if (onDownload != null)
                PillButton(downloadLabel, onTap: onDownload)
              else if (onUse != null && !selected)
                PillButton('use', onTap: enabled ? onUse : null),
              if (onRemove != null)
                DoodleButton(Doodle.trash, tooltip: 'Remove $name', size: 18, color: p.redPen, onTap: onRemove),
            ],
          ),
          if (moods.length > 1)
            Padding(
              padding: const EdgeInsets.only(left: 48, top: 4),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final m in moods) HandTag(m == Mood.neutral ? 'normal' : m.name, onTap: () => onMood?.call(m)),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
