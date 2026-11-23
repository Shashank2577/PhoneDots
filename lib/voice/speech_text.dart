/// How a sentence should sound. The model picks one per sentence with a tag
/// such as "[happy]"; voices that have a clip for it speak in that tone.
enum Mood {
  neutral('default'),
  happy('happy'),
  calm('calm'),
  sad('sad'),
  whisper('whisper'),
  laughing('laughing'),
  sympathetic('sympathetic'),
  confused('confused'),
  sarcastic('sarcastic'),
  awe('awe'),
  angry('angry'),
  excited('projected'),
  serious('enunciated');

  const Mood(this.clipName);

  /// The Expresso style whose recording carries this mood.
  final String clipName;

  static Mood? parse(String s) {
    final t = s.trim().toLowerCase();
    for (final m in Mood.values) {
      if (m.name == t) return m;
    }
    return switch (t) {
      'cheerful' || 'joyful' || 'warm' => Mood.happy,
      'gentle' || 'soft' || 'relaxed' => Mood.calm,
      'laugh' || 'laughs' || 'amused' || 'funny' => Mood.laughing,
      'kind' || 'caring' || 'empathetic' => Mood.sympathetic,
      'surprised' || 'amazed' || 'wow' => Mood.awe,
      'energetic' || 'enthusiastic' => Mood.excited,
      'firm' || 'clear' => Mood.serious,
      'default' => Mood.neutral,
      _ => null,
    };
  }
}

class SpeechChunk {
  const SpeechChunk(this.text, [this.mood = Mood.neutral]);
  final String text;
  final Mood mood;

  @override
  String toString() => '[${mood.name}] $text';
}

final _tag = RegExp(r'\[\s*([a-zA-Z]+)\s*\]');

/// Removes mood tags, for showing a spoken reply as text.
String stripMoodTags(String s) => s
    .replaceAllMapped(_tag, (m) => Mood.parse(m.group(1)!) == null ? m.group(0)! : '')
    .replaceAll(RegExp(r'[ \t]{2,}'), ' ')
    .replaceAll(RegExp(r' +([.,!?])'), r'$1')
    .trim();

/// Text as it should be read aloud: no markdown, links, code or emoji.
String speakable(String s) => s
    .replaceAll(RegExp(r'```[\s\S]*?```'), ' ')
    .replaceAll(RegExp(r'`([^`]*)`'), r'$1')
    .replaceAllMapped(RegExp(r'\[([^\]]+)\]\([^)]*\)'), (m) => m.group(1)!)
    .replaceAll(RegExp(r'https?://\S+'), 'a link')
    .replaceAll(RegExp(r'[*_#>|~]+'), '')
    .replaceAll(RegExp(r'^\s*[-•]\s+', multiLine: true), '')
    .replaceAll(RegExp(r'[\u{1F000}-\u{1FAFF}\u{2600}-\u{27BF}\u{FE0F}]', unicode: true), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

/// Turns a reply that arrives a few words at a time into whole sentences,
/// each with its mood, as soon as each sentence is complete, so speaking can
/// start before the model has finished.
class SentenceStreamer {
  SentenceStreamer({this.minChars = 12});

  /// Very short fragments ("Sure.") are joined to the next sentence so the
  /// voice doesn't stop and start.
  final int minChars;
  final _buf = StringBuffer();
  Mood _mood = Mood.neutral;
  String _seen = '';

  /// Feed the whole reply so far; returns sentences that became complete.
  List<SpeechChunk> update(String fullText) {
    if (!fullText.startsWith(_seen)) {
      // The text was replaced (e.g. a retry): start over.
      _buf.clear();
      _seen = '';
    }
    _buf.write(fullText.substring(_seen.length));
    _seen = fullText;
    return _drain(final_: false);
  }

  /// Everything left once the reply is complete.
  List<SpeechChunk> finish() => _drain(final_: true);

  List<SpeechChunk> _drain({required bool final_}) {
    final out = <SpeechChunk>[];
    var text = _buf.toString();
    while (true) {
      final end = RegExp(r'[.!?…]+["”’)\]]*(?=\s)|\n+').firstMatch(text);
      if (end == null) break;
      final sentence = text.substring(0, end.end);
      if (speakable(stripMoodTags(sentence)).length < minChars && !final_) {
        // Too short on its own: wait for the next sentence unless it is the
        // last of the paragraph.
        final next = RegExp(r'[.!?…]+["”’)\]]*(?=\s)|\n+').firstMatch(text.substring(end.end));
        if (next == null) break;
        final joined = text.substring(0, end.end + next.end);
        out.addAll(_chunks(joined));
        text = text.substring(end.end + next.end);
        continue;
      }
      out.addAll(_chunks(sentence));
      text = text.substring(end.end);
    }
    if (final_ && text.trim().isNotEmpty) {
      out.addAll(_chunks(text));
      text = '';
    }
    _buf
      ..clear()
      ..write(text);
    return out;
  }

  /// A sentence may change mood part-way: "[happy] Great! [calm] Now…".
  List<SpeechChunk> _chunks(String s) {
    final out = <SpeechChunk>[];
    var last = 0;
    for (final m in _tag.allMatches(s)) {
      final mood = Mood.parse(m.group(1)!);
      if (mood == null) continue;
      final before = speakable(s.substring(last, m.start));
      if (before.isNotEmpty) out.add(SpeechChunk(before, _mood));
      _mood = mood;
      last = m.end;
    }
    final rest = speakable(stripMoodTags(s.substring(last)));
    if (rest.isNotEmpty) out.add(SpeechChunk(rest, _mood));
    return out;
  }
}
