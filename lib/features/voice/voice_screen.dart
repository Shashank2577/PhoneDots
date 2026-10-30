import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:record/record.dart';

import '../../app_state.dart';
import '../../skills/skill.dart';
import '../../theme/theme.dart';
import '../../widgets/common.dart';

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
      _Phase.idle => 'Tap to talk',
      _Phase.listening => 'Listening… tap when done',
      _Phase.transcribing => 'Transcribing on device',
      _Phase.thinking => 'Thinking',
      _Phase.speaking => 'Speaking · tap to stop',
    };
    return Scaffold(
      appBar: AppBar(title: const Text('Voice')),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(children: [
            Expanded(
              child: ListView(children: [
                if (_heard.isNotEmpty) ...[
                  Text('YOU', style: context.text.labelSmall),
                  const SizedBox(height: 6),
                  Text(_heard, style: context.text.titleLarge?.copyWith(fontWeight: FontWeight.w500)),
                  const SizedBox(height: 24),
                ],
                if (_reply.isNotEmpty) ...[
                  Text('PHONEDOTS', style: context.text.labelSmall),
                  const SizedBox(height: 6),
                  Text(_reply, style: context.text.bodyLarge),
                ],
                if (_error != null) Text(_error!, style: context.text.bodyMedium?.copyWith(color: p.danger)),
              ]),
            ),
            GestureDetector(
              onTap: _tap,
              child: AnimatedBuilder(
                animation: _pulse,
                builder: (_, _) {
                  final active = _phase == _Phase.listening;
                  final busy = _phase == _Phase.transcribing || _phase == _Phase.thinking;
                  final scale = active ? 1 + _level * 0.35 : busy ? 1 + 0.05 * sin(_pulse.value * 2 * pi) : 1.0;
                  return Stack(alignment: Alignment.center, children: [
                    if (active || busy)
                      Container(
                        width: 150 * scale,
                        height: 150 * scale,
                        decoration: BoxDecoration(shape: BoxShape.circle, color: p.ink.withValues(alpha: 0.06)),
                      ),
                    Container(
                      width: 104,
                      height: 104,
                      decoration: BoxDecoration(shape: BoxShape.circle, color: active ? p.danger : p.ink),
                      child: Icon(
                        active ? Icons.stop_rounded : _phase == _Phase.speaking ? Icons.volume_up_rounded : Icons.mic_rounded,
                        color: p.bg,
                        size: 36,
                      ),
                    ),
                  ]);
                },
              ),
            ),
            const SizedBox(height: 20),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Dot(color: _phase == _Phase.listening ? p.danger : p.dot, size: 6),
              const SizedBox(width: 8),
              Text(label, style: context.text.bodyMedium?.copyWith(color: p.muted)),
            ]),
            const SizedBox(height: 12),
          ]),
        ),
      ),
    );
  }
}
