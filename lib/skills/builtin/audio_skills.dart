import '../../core/util/format.dart';
import '../skill.dart';
import 'json_extract.dart';

const _audioParam = SkillParam('audio', ParamType.attachment, 'The audio recording to process.');

SkillResult? _needAudio(Attachment? a) =>
    a == null || a.kind != 'audio' ? SkillResult.error('Attach or record audio first.') : null;

/// Joins Voz words with Who turns into speaker segments.
List<Map<String, dynamic>> mergeSpeakers(List words, List turns) {
  if (turns.isEmpty) {
    final text = words.map((w) => (w as Map)['text']).join(' ');
    return [
      {'speaker': 0, 'start': 0.0, 'end': words.isEmpty ? 0.0 : (words.last as Map)['end'], 'text': text},
    ];
  }
  final segments = <Map<String, dynamic>>[];
  for (final t in turns.cast<Map>()) {
    final start = (t['start'] as num).toDouble();
    final end = (t['end'] as num).toDouble();
    final inTurn = words.cast<Map>().where((w) {
      final mid = ((w['start'] as num) + (w['end'] as num)) / 2;
      return mid >= start && mid < end;
    });
    final text = inTurn.map((w) => w['text']).join(' ').trim();
    if (text.isEmpty) continue;
    if (segments.isNotEmpty && segments.last['speaker'] == t['speaker']) {
      segments.last['text'] = '${segments.last['text']} $text';
      segments.last['end'] = end;
    } else {
      segments.add({'speaker': t['speaker'], 'start': start, 'end': end, 'text': text});
    }
  }
  return segments;
}

String _plainTranscript(List<Map<String, dynamic>> segments) => segments
    .map(
      (s) => 'Speaker ${(s['speaker'] as int) + 1} [${formatDuration((s['start'] as num).toDouble())}]: ${s['text']}',
    )
    .join('\n');

Future<Map<String, dynamic>> _speakerTranscript(Attachment a, SkillContext ctx) async {
  ctx.progress('Transcribing with Voz');
  final t = await ctx.specialist('desertant.voz', 'transcribe', {'audioPath': a.path});
  if (t['error'] != null) return t;
  ctx.progress('Labelling speakers with Who');
  final d = await ctx.specialist('desertant.who', 'diarize', {'audioPath': a.path});
  final words = (t['words'] as List?) ?? const [];
  final segments = words.length > 2
      ? mergeSpeakers(words, (d['turns'] as List?) ?? const [])
      : [
          {'speaker': 0, 'start': 0.0, 'end': t['duration'] ?? 0, 'text': t['text']},
        ];
  return {
    'text': t['text'],
    'duration': t['duration'],
    'speakers': d['speakerCount'] ?? 1,
    'segments': segments,
    if (t['demo'] == true) 'demo': true,
  };
}

UiCard transcriptCard(Map<String, dynamic> r, {String title = 'Transcript'}) =>
    UiCard('transcript', title: title, data: {'segments': r['segments'], 'duration': r['duration']});

String _srtTime(double s) {
  final ms = (s * 1000).round();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${two(ms ~/ 3600000)}:${two(ms ~/ 60000 % 60)}:${two(ms ~/ 1000 % 60)},${(ms % 1000).toString().padLeft(3, '0')}';
}

String buildSrt(List words, {int maxWords = 7, double maxSeconds = 3.5}) {
  final out = StringBuffer();
  var index = 1;
  var group = <Map>[];
  void flush() {
    if (group.isEmpty) return;
    out
      ..writeln(index++)
      ..writeln(
        '${_srtTime((group.first['start'] as num).toDouble())} --> ${_srtTime((group.last['end'] as num).toDouble())}',
      )
      ..writeln(group.map((w) => w['text']).join(' '))
      ..writeln();
    group = [];
  }

  for (final w in words.cast<Map>()) {
    if (group.isNotEmpty &&
        (group.length >= maxWords || (w['end'] as num) - (group.first['start'] as num) > maxSeconds)) {
      flush();
    }
    group.add(w);
  }
  flush();
  return out.toString();
}

List<Skill> audioSkills() => [
  FnSkill(
    id: 'transcribe_audio',
    name: 'Transcribe audio',
    description: 'Turn speech in an audio recording into text with word timestamps. Runs Voz on device.',
    kind: SkillKind.model,
    category: SkillCategory.audio,
    params: const [_audioParam],
    requiresModels: const ['desertant.voz'],
    examples: const ['Transcribe this voice note'],
    handler: (args, ctx) async {
      final a = ctx.attachment(args['audio']);
      final missing = _needAudio(a);
      if (missing != null) return missing;
      ctx.progress('Transcribing with Voz');
      final r = await ctx.specialist('desertant.voz', 'transcribe', {'audioPath': a!.path});
      if (r['error'] != null) return SkillResult.error('${r['error']}');
      final text = '${r['text']}';
      return SkillResult(
        {
          'text': text.length > 6000 ? '${text.substring(0, 6000)}…' : text,
          'duration_seconds': r['duration'],
          'summary': 'Transcribed ${formatDuration((r['duration'] as num? ?? 0).toDouble())} of audio.',
        },
        cards: [
          UiCard(
            'transcript',
            title: 'Transcript',
            data: {
              'segments': [
                {'speaker': 0, 'start': 0.0, 'end': r['duration'] ?? 0, 'text': text},
              ],
              'duration': r['duration'],
            },
          ),
        ],
      );
    },
  ),
  FnSkill(
    id: 'transcribe_with_speakers',
    name: 'Transcript with speakers',
    description: 'Transcribe a recording and label who said what (Voz + Who).',
    kind: SkillKind.model,
    category: SkillCategory.audio,
    params: const [_audioParam],
    requiresModels: const ['desertant.voz', 'desertant.who'],
    examples: const ['Who said what in this recording?'],
    handler: (args, ctx) async {
      final a = ctx.attachment(args['audio']);
      final missing = _needAudio(a);
      if (missing != null) return missing;
      final r = await _speakerTranscript(a!, ctx);
      if (r['error'] != null) return SkillResult.error('${r['error']}');
      final plain = _plainTranscript((r['segments'] as List).cast());
      return SkillResult(
        {'speakers': r['speakers'], 'transcript': plain.length > 6000 ? '${plain.substring(0, 6000)}…' : plain},
        cards: [transcriptCard(r)],
      );
    },
  ),
  FnSkill(
    id: 'meeting_minutes',
    name: 'Meeting minutes',
    description: 'From a meeting recording: speaker transcript, summary, decisions and action items.',
    kind: SkillKind.model,
    category: SkillCategory.audio,
    params: const [_audioParam],
    requiresModels: const ['desertant.voz', 'desertant.who'],
    examples: const ['Make minutes from this meeting'],
    handler: (args, ctx) async {
      final a = ctx.attachment(args['audio']);
      final missing = _needAudio(a);
      if (missing != null) return missing;
      final r = await _speakerTranscript(a!, ctx);
      if (r['error'] != null) return SkillResult.error('${r['error']}');
      final plain = _plainTranscript((r['segments'] as List).cast());
      ctx.progress('Writing minutes with Gemma');
      final raw = await ctx.ask(
        system:
            'You write meeting minutes. Reply with JSON only: '
            '{"summary": string, "decisions": [string], "actions": [{"owner": string, "task": string, "due": string}]}',
        prompt: plain,
      );
      final m = extractJson(raw);
      final summary = m?['summary']?.toString() ?? raw.trim();
      final decisions = (m?['decisions'] as List?)?.map((e) => '$e').toList() ?? const <String>[];
      final actions =
          (m?['actions'] as List?)
              ?.whereType<Map>()
              .map((x) => [x['owner'], x['task'], x['due']].where((v) => v != null && '$v'.isNotEmpty).join(' · '))
              .toList() ??
          const <String>[];
      return SkillResult(
        {'summary': summary, 'decisions': decisions, 'action_items': actions, 'speakers': r['speakers']},
        cards: [
          UiCard('text', title: 'Summary', data: {'text': summary}),
          if (decisions.isNotEmpty)
            UiCard('checklist', title: 'Decisions', data: {'items': decisions, 'readonly': true}),
          if (actions.isNotEmpty) UiCard('checklist', title: 'Action items', data: {'items': actions}),
          transcriptCard(r),
        ],
      );
    },
  ),
  FnSkill(
    id: 'detect_spoken_language',
    name: 'Detect spoken language',
    description: 'Identify the language spoken in a recording (102 languages, Ear).',
    kind: SkillKind.model,
    category: SkillCategory.audio,
    params: const [_audioParam],
    requiresModels: const ['desertant.ear'],
    handler: (args, ctx) async {
      final a = ctx.attachment(args['audio']);
      final missing = _needAudio(a);
      if (missing != null) return missing;
      final r = await ctx.specialist('desertant.ear', 'identify', {'audioPath': a!.path});
      if (r['error'] != null) return SkillResult.error('${r['error']}');
      return SkillResult(
        {'language': r['language'], 'confidence': r['confidence'], 'reliable': r['isReliable']},
        cards: [
          UiCard(
            'kv',
            title: 'Spoken language',
            data: {
              'Language': '${r['language']}',
              'Confidence': '${(((r['confidence'] as num?) ?? 0) * 100).round()}%',
            },
          ),
        ],
      );
    },
  ),
  FnSkill(
    id: 'enhance_speech',
    name: 'Clean up audio',
    description: 'Remove background noise and echo and even out loudness in a voice recording (Clear).',
    kind: SkillKind.model,
    category: SkillCategory.audio,
    params: const [_audioParam],
    requiresModels: const ['desertant.clear'],
    handler: (args, ctx) async {
      final a = ctx.attachment(args['audio']);
      final missing = _needAudio(a);
      if (missing != null) return missing;
      ctx.progress('Enhancing with Clear');
      final r = await ctx.specialist('desertant.clear', 'enhance', {'audioPath': a!.path});
      if (r['error'] != null) return SkillResult.error('${r['error']}');
      return SkillResult(
        {'summary': 'Cleaned audio saved.', 'path': r['outputPath']},
        cards: [
          UiCard('file', title: 'Clean audio', data: {'path': r['outputPath'], 'kind': 'audio'}),
        ],
      );
    },
  ),
  FnSkill(
    id: 'find_filler_words',
    name: 'Find filler words',
    description: 'Find every "uh", "um" and "hmm" in a recording with timestamps (Uhm).',
    kind: SkillKind.model,
    category: SkillCategory.audio,
    params: const [_audioParam],
    requiresModels: const ['desertant.uhm'],
    platforms: const {'ios'},
    handler: (args, ctx) async {
      final a = ctx.attachment(args['audio']);
      final missing = _needAudio(a);
      if (missing != null) return missing;
      final r = await ctx.specialist('desertant.uhm', 'analyze', {'audioPath': a!.path});
      if (r['error'] != null) return SkillResult.error('${r['error']}');
      final fillers = (r['fillers'] as List? ?? const []).cast<Map>();
      return SkillResult(
        {'count': fillers.length, 'summary': 'Found ${fillers.length} filler words.'},
        cards: [
          UiCard(
            'timeline',
            title: 'Filler words',
            data: {
              'items': fillers
                  .map(
                    (f) => {'time': formatDuration((f['start'] as num).toDouble()), 'text': '${f['type'] ?? 'filler'}'},
                  )
                  .toList(),
            },
          ),
        ],
      );
    },
  ),
  FnSkill(
    id: 'export_subtitles',
    name: 'Export subtitles',
    description: 'Create an .srt subtitle file from a recording or video soundtrack.',
    kind: SkillKind.model,
    category: SkillCategory.audio,
    params: const [_audioParam],
    requiresModels: const ['desertant.voz'],
    handler: (args, ctx) async {
      final a = ctx.attachment(args['audio']);
      final missing = _needAudio(a);
      if (missing != null) return missing;
      ctx.progress('Transcribing with Voz');
      final r = await ctx.specialist('desertant.voz', 'transcribe', {'audioPath': a!.path});
      if (r['error'] != null) return SkillResult.error('${r['error']}');
      final srt = buildSrt((r['words'] as List?) ?? const []);
      final path = await ctx.saveTextFile('${a.name.split('.').first}.srt', srt);
      return SkillResult(
        {'summary': 'Subtitles ready.', 'path': path},
        cards: [
          UiCard('file', title: 'Subtitles (.srt)', data: {'path': path, 'kind': 'document', 'preview': srt}),
        ],
      );
    },
  ),
];
