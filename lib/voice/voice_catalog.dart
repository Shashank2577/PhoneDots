import 'speech_text.dart';

/// The neural voice engine: Kyutai Pocket TTS (100M parameters, CC BY 4.0),
/// run by sherpa-onnx on the phone's CPU. It speaks in the voice and tone of
/// a 10-second reference clip, so voices are tiny downloads and a voice with
/// one clip per mood can sound happy, calm, whispering, laughing…
class PocketEngine {
  static const id = 'pocket-tts';
  static const name = 'Pocket TTS';
  static const folder = 'sherpa-onnx-pocket-tts-int8-2026-01-26';
  static const archiveUrl = 'https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/$folder.tar.bz2';
  static const archiveSha256 = 'f4da7c7bd465f7b91e89191487fe90504396a51d6f0bcf94d0787633e2657293';
  static const archiveBytes = 98337865;
  static const installedBytes = 198000000;
  static const files = [
    'lm_flow.int8.onnx',
    'lm_main.int8.onnx',
    'encoder.onnx',
    'decoder.int8.onnx',
    'text_conditioner.onnx',
    'vocab.json',
    'token_scores.json',
  ];
  static const licence = 'Kyutai Pocket TTS, CC BY 4.0 (weights) · sherpa-onnx, Apache 2.0';
}

enum VoiceSource {
  /// Volunteers' voices, CC0: free for any use.
  donated,

  /// The VCTK corpus, CC BY 4.0: free with attribution.
  vctk,

  /// The Expresso dataset: one speaker in many moods. CC BY-NC 4.0, so
  /// personal, non-commercial use only.
  expressive,
}

class VoiceSpec {
  const VoiceSpec({required this.id, required this.name, required this.source, required this.clips, this.note = ''});

  final String id;
  final String name;
  final VoiceSource source;

  /// Reference clips by mood; [Mood.neutral] is always present.
  final Map<Mood, String> clips;
  final String note;

  String get sampleUrl => clips[Mood.neutral]!;
  bool get expressive => clips.length > 1;
  bool get personalUseOnly => source == VoiceSource.expressive;

  String get licence => switch (source) {
    VoiceSource.donated => 'CC0, donated to Kyutai\'s voice project',
    VoiceSource.vctk => 'CC BY 4.0, VCTK corpus (University of Edinburgh)',
    VoiceSource.expressive => 'CC BY-NC 4.0, Expresso dataset (Meta): personal use only',
  };

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'source': source.name,
    'note': note,
    'clips': {for (final e in clips.entries) e.key.name: e.value},
  };

  static VoiceSpec? fromJson(Map<String, dynamic> j) {
    try {
      final clips = <Mood, String>{
        for (final e in (j['clips'] as Map).entries)
          if (Mood.values.asNameMap()[e.key] != null) Mood.values.asNameMap()[e.key]!: '${e.value}',
      };
      if (!clips.containsKey(Mood.neutral)) return null;
      return VoiceSpec(
        id: j['id'] as String,
        name: j['name'] as String,
        source: VoiceSource.values.byName(j['source'] as String),
        clips: clips,
        note: j['note'] as String? ?? '',
      );
    } catch (_) {
      return null;
    }
  }
}

/// Builds the voice list from Kyutai's public voice repository file listing.
class VoiceCatalog {
  static const repo = 'kyutai/tts-voices';
  static const listingUrl = 'https://huggingface.co/api/models/$repo';
  static String fileUrl(String path) => 'https://huggingface.co/$repo/resolve/main/$path';

  /// A few voices so the list is never empty, even before the listing loads.
  static final starter = <VoiceSpec>[
    for (final v in const ['0a67', '1410', '1dd0'])
      VoiceSpec(
        id: 'donated-$v',
        name: 'voice $v',
        source: VoiceSource.donated,
        clips: {Mood.neutral: fileUrl('voice-donations/${v}_enhanced.wav')},
      ),
  ];

  /// Parses the Hugging Face model API response (its "siblings" file list).
  static List<VoiceSpec> parse(Map<String, dynamic> listing) {
    final files = [
      for (final s in (listing['siblings'] as List? ?? const []))
        if (s is Map && s['rfilename'] is String) s['rfilename'] as String,
    ];
    final out = <VoiceSpec>[];
    // Donated voices: prefer the cleaned "_enhanced" recording.
    final donated = <String, String>{};
    for (final f in files) {
      final m = RegExp(r'^voice-donations/([A-Za-z0-9]+)(_enhanced)?\.wav$').firstMatch(f);
      if (m == null) continue;
      if (m.group(2) != null || !donated.containsKey(m.group(1))) donated[m.group(1)!] = f;
    }
    for (final e in donated.entries) {
      out.add(
        VoiceSpec(
          id: 'donated-${e.key}',
          name: 'voice ${e.key}',
          source: VoiceSource.donated,
          clips: {Mood.neutral: fileUrl(e.value)},
        ),
      );
    }
    final vctk = <String, String>{};
    for (final f in files) {
      final m = RegExp(r'^vctk/(p\d+)_\d+(_enhanced)?\.wav$').firstMatch(f);
      if (m == null) continue;
      if (m.group(2) != null || !vctk.containsKey(m.group(1))) vctk[m.group(1)!] = f;
    }
    for (final e in vctk.entries) {
      out.add(
        VoiceSpec(
          id: 'vctk-${e.key}',
          name: 'VCTK ${e.key}',
          source: VoiceSource.vctk,
          clips: {Mood.neutral: fileUrl(e.value)},
        ),
      );
    }
    // Expresso: file "exA-exB_style_NNN_channelC_..." is speaker A on channel 1, B on 2.
    final moods = <String, Map<Mood, String>>{};
    for (final f in files) {
      final m = RegExp(r'^expresso/(ex\d+)-(ex\d+)_([a-z]+)(?:-[a-z]+)?_\d+_channel([12])_[^/]*\.wav$').firstMatch(f);
      if (m == null || f.contains('_enhanced')) continue;
      final speaker = m.group(4) == '1' ? m.group(1)! : m.group(2)!;
      final style = m.group(3)!;
      final mood = Mood.values.where((x) => x.clipName == style).firstOrNull;
      if (mood == null) continue;
      moods.putIfAbsent(speaker, () => {}).putIfAbsent(mood, () => fileUrl(f));
    }
    for (final e in (moods.entries.toList()..sort((a, b) => a.key.compareTo(b.key)))) {
      if (!e.value.containsKey(Mood.neutral)) continue;
      out.add(
        VoiceSpec(
          id: 'expressive-${e.key}',
          name: 'expressive ${e.key.replaceFirst('ex0', '')}',
          source: VoiceSource.expressive,
          clips: e.value,
          note: '${e.value.length} moods',
        ),
      );
    }
    return out;
  }
}
