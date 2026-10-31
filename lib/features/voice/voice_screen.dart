import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:record/record.dart';

import '../../app_state.dart';
import '../../skills/skill.dart';
import '../../theme/theme.dart';
import '../../widgets/hand.dart';

enum _Phase { idle, listening, transcribing, thinking, speaking }

/// Hands-free loop: record → Voz (or Gemma audio) → agent → spoken reply.
/// Shares the active conversation, so everything also appears in Chat.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> with SingleTickerProviderStateMixin {
  final _rec = AudioRecorder();
  final _tts = FlutterTts();
  late final _pulse = AnimationController(vsync: this, duration: const Duration(milliseconds: 1400))..repeat();
  StreamSubscription<Amplitude>? _amp;
  double _level = 0;
  _Phase _phase = _Phase.idle;
  String _heard = '';
  String _reply = '';
  String? _error;

  @override
  void initState() {
    super.initState();
    _tts.setCompletionHandler(() {
      if (mounted) setState(() => _phase = _Phase.idle);
    });
  }

  @override
  void dispose() {
    _amp?.cancel();
    _rec.dispose();
    _tts.stop();
    _pulse.dispose();
    super.dispose();
  }

  Future<void> _tap() async {
    switch (_phase) {
      case _Phase.idle:
        await _listen();
      case _Phase.listening:
        await _finish();
      case _Phase.speaking:
        await _tts.stop();
        setState(() => _phase = _Phase.idle);
      default:
    }
  }

  Future<void> _listen() async {
    final s = AppScope.services(context);
    try {
      if (!await _rec.hasPermission()) {
        setState(() => _error = 'Microphone permission is needed.');
        return;
      }
      final path = '${s.store.filesDir ?? ''}/voice-${DateTime.now().millisecondsSinceEpoch}.wav';
      await _rec.start(const RecordConfig(encoder: AudioEncoder.wav, sampleRate: 16000, numChannels: 1), path: path);
      _amp = _rec.onAmplitudeChanged(const Duration(milliseconds: 120)).listen((a) {
        if (mounted) setState(() => _level = ((a.current + 50) / 50).clamp(0, 1).toDouble());
      });
      setState(() {
        _phase = _Phase.listening;
        _error = null;
        _heard = '';
        _reply = '';
      });
    } catch (e) {
      setState(() => _error = 'Recording is not available here.');
    }
  }

  Future<void> _finish() async {
    await _amp?.cancel();
    final path = await _rec.stop();
    if (path == null || !mounted) return;
    final state = AppScope.of(context);
    final s = state.services;
    final chat = state.chat;
    final audio = Attachment(id: chat.nextAttachmentId(0), kind: 'audio', path: path, name: 'Voice message');
    setState(() => _phase = _Phase.transcribing);
    try {
      String text = '';
      if (s.models.isReady('desertant.voz') || s.isDemo) {
        final r = await s.specialists.run('desertant.voz', 'transcribe', {'audioPath': path});
        text = '${r['text'] ?? ''}'.trim();
      }
      setState(() {
        _heard = text.isEmpty ? '(voice message)' : text;
        _phase = _Phase.thinking;
      });
      if (text.isNotEmpty) {
        await chat.send(text);
      } else {
        // No Voz: Gemma 4 listens to the clip itself.
        await chat.send('Reply to what I said in this recording.', attachments: [audio]);
      }
      final last = chat.messages.last;
      _reply = last.error ?? last.text;
      if (!mounted) return;
      setState(() => _phase = _Phase.speaking);
      await _tts.speak(_reply.replaceAll(RegExp(r'[*`#]'), ''));
    } catch (e) {
      setState(() {
        _error = '$e';
        _phase = _Phase.idle;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final label = switch (_phase) {
      _Phase.idle => 'tap to talk',
      _Phase.listening => 'listening… tap when you\'re done',
      _Phase.transcribing => 'writing down what you said',
      _Phase.thinking => 'thinking',
      _Phase.speaking => 'speaking · tap to stop',
    };
    final active = _phase == _Phase.listening;
    return HandPage(
      body: Column(
        children: [
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: gutter),
              children: [
                const PageIntro(
                  'talk',
                  'Say it out loud. Voz writes it down on this phone, and the reply is read back to you.',
                  doodle: Doodle.mic,
                ),
                if (_heard.isNotEmpty) ...[
                  const SectionHead('you said', padding: EdgeInsets.only(bottom: 4)),
                  Text(_heard, style: Hand.title.copyWith(fontSize: 28, color: p.ink)),
                ],
                if (_reply.isNotEmpty) ...[const SectionHead('phonedots'), Body(_reply)],
                if (_error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Row(
                      children: [
                        DoodleIcon(Doodle.exclaim, size: 20, color: p.redPen, stroke: 2.6),
                        const SizedBox(width: 6),
                        Expanded(child: Body(_error!)),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          // The big button: an ink circle that breathes with your voice.
          Pressable(
            onTap: _tap,
            scale: 0.92,
            child: AnimatedBuilder(
              animation: _pulse,
              builder: (_, _) {
                final busy = _phase == _Phase.transcribing || _phase == _Phase.thinking;
                final scale = active ? 1 + _level * 0.3 : (busy ? 1 + 0.05 * sin(_pulse.value * 2 * pi) : 1.0);
                return SizedBox(
                  width: 160,
                  height: 160,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      if (active || busy)
                        Container(
                          width: 110 * scale + 30,
                          height: 110 * scale + 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: p.rule, width: 1.6),
                          ),
                        ),
                      Container(
                        width: 104,
                        height: 104,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: active ? p.redPen : p.ink),
                        child: Center(
                          child: DoodleIcon(
                            active ? Doodle.stop : (_phase == _Phase.speaking ? Doodle.wave : Doodle.mic),
                            size: 40,
                            color: p.paper,
                            stroke: 2.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          MarkedText(label, mark: active ? 'listening' : null, style: Hand.label.copyWith(fontSize: 23)),
          const SizedBox(height: 20),
        ],
      ),
    );
  }
}
