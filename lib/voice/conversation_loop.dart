import 'dart:async';

import 'package:flutter/foundation.dart';

import '../agent/agent.dart';
import '../app_services.dart';
import '../core/app_log.dart';
import '../core/util/files.dart';
import '../skills/skill.dart';
import 'listener.dart';
import 'speaker.dart';
import 'speech_text.dart';
import 'wav.dart';

enum TalkState { off, listening, hearing, transcribing, thinking, speaking }

/// Turn-by-turn conversation: listen until you pause, understand, answer out
/// loud sentence by sentence, then listen again. Talking while it speaks
/// interrupts it.
class ConversationLoop extends ChangeNotifier {
  ConversationLoop({required this.services, required this.chat, required this.speaker}) {
    speaker.addListener(_onSpeaker);
  }

  final AppServices services;
  final ChatController chat;
  final Speaker speaker;

  TalkState state = TalkState.off;
  String heard = '';
  String reply = '';
  String? problem;
  double level = -100;
  VoiceListener? _listener;
  Timer? _startTimer;
  SentenceStreamer? _streamer;
  int _turn = 0;

  Mood get mood => speaker.mood;

  void _set(TalkState s) {
    state = s;
    if (_listener != null) _listener!.vad.bargeIn = s == TalkState.speaking || s == TalkState.thinking;
    notifyListeners();
  }

  void _onSpeaker() => notifyListeners();

  Future<void> start() async {
    problem = null;
    bool ok;
    try {
      _listener ??= VoiceListener(
        onSpeechStart: _onSpeechStart,
        onUtterance: (s) => unawaited(_onUtterance(s)),
        onLevel: (db) {
          level = db;
          if (state == TalkState.listening || state == TalkState.hearing) notifyListeners();
        },
      );
      // A microphone that never answers ends with an explanation, not silence.
      final answer = Completer<bool>();
      _startTimer = Timer(const Duration(seconds: 10), () {
        if (!answer.isCompleted) answer.completeError(TimeoutException('the microphone did not answer'));
      });
      _listener!.start().then(
        (v) => answer.isCompleted ? null : answer.complete(v),
        onError: (Object e) => answer.isCompleted ? null : answer.completeError(e),
      );
      ok = await answer.future;
      _startTimer?.cancel();
    } catch (e, st) {
      appLog.error('voice', 'microphone did not start', null, e, st);
      problem = 'The microphone could not start: $e';
      _set(TalkState.off);
      return;
    }
    if (!ok) {
      problem = 'PhoneDots needs the microphone to talk. Allow it in the phone\'s settings.';
      _set(TalkState.off);
      return;
    }
    appLog.info('voice', 'conversation started', {'voice': services.voices.selected?.id ?? 'system'});
    _set(TalkState.listening);
  }

  Future<void> stop() async {
    _turn++;
    await _listener?.stop();
    await speaker.stop();
    if (chat.busy) await chat.stop();
    _set(TalkState.off);
  }

  /// You started talking. If the assistant was answering, it stops.
  void _onSpeechStart() {
    if (state == TalkState.speaking || state == TalkState.thinking) {
      appLog.info('voice', 'interrupted by the user');
      _turn++;
      unawaited(speaker.stop());
      if (chat.busy) unawaited(chat.stop());
    }
    _set(TalkState.hearing);
  }

  Future<void> _onUtterance(Float32List samples) async {
    final turn = ++_turn;
    _set(TalkState.transcribing);
    final dir = services.store.filesDir;
    final path = await writeBytesFile(
      dir,
      'heard-${DateTime.now().millisecondsSinceEpoch}.wav',
      encodeWav(samples, VoiceListener.sampleRate),
    );
    if (turn != _turn) return;
    String? text;
    if (path != null && await services.specialists.isDownloaded('desertant.voz')) {
      try {
        final r = await services.specialists.run('desertant.voz', 'transcribe', {'audioPath': path});
        text = '${r['text'] ?? ''}'.trim();
      } catch (e) {
        appLog.warn('voice', 'transcription failed', {'error': '$e'});
      }
    }
    if (turn != _turn) return;
    if (text != null && text.isEmpty) {
      // Nothing intelligible: keep listening.
      _set(TalkState.listening);
      return;
    }
    heard = text ?? '(voice message)';
    reply = '';
    _streamer = SentenceStreamer();
    _set(TalkState.thinking);
    void onChat() {
      if (turn != _turn || chat.messages.isEmpty) return;
      final m = chat.messages.last;
      if (m.isUser) return;
      reply = stripMoodTags(m.text);
      for (final c in _streamer!.update(m.text)) {
        speaker.say(c);
        if (state == TalkState.thinking) _set(TalkState.speaking);
      }
      notifyListeners();
    }

    chat.addListener(onChat);
    try {
      if (text != null) {
        await chat.send(text, spoken: true);
      } else if (path != null) {
        // No Voz: Gemma listens to the recording itself (audio-capable models).
        await chat.send(
          'Reply to what I said.',
          attachments: [Attachment(id: chat.nextAttachmentId(0), kind: 'audio', path: path, name: 'voice.wav')],
          spoken: true,
        );
      }
    } finally {
      chat.removeListener(onChat);
    }
    if (turn != _turn) return;
    final last = chat.messages.isEmpty ? null : chat.messages.last;
    if (last != null && last.error != null) speaker.sayAll('Sorry, something went wrong. ${last.error}');
    for (final c in _streamer!.finish()) {
      speaker.say(c);
    }
    if (speaker.speaking) _set(TalkState.speaking);
    await speaker.whenIdle;
    if (turn != _turn || state == TalkState.off) return;
    _set(TalkState.listening);
  }

  bool _disposed = false;

  /// Work that finishes after the screen closed (a slow microphone, a reply
  /// still arriving) must not touch it.
  @override
  void notifyListeners() {
    if (!_disposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _turn++;
    _startTimer?.cancel();
    speaker.removeListener(_onSpeaker);
    unawaited(_listener?.dispose());
    super.dispose();
  }
}
