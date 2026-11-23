import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';

import '../../app_state.dart';
import '../../theme/theme.dart';
import '../../voice/conversation_loop.dart';
import '../../voice/speech_text.dart';
import '../../widgets/hand.dart';
import 'voices_screen.dart';

/// Hands-free, turn-by-turn conversation. It listens until you pause,
/// answers out loud sentence by sentence (in the mood the reply calls for,
/// with an expressive voice), then listens again. Talk over it to interrupt.
/// Shares the active chat, so everything also appears in Chat.
class VoiceScreen extends StatefulWidget {
  const VoiceScreen({super.key});

  @override
  State<VoiceScreen> createState() => _VoiceScreenState();
}

class _VoiceScreenState extends State<VoiceScreen> with SingleTickerProviderStateMixin {
  late final _anim = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();
  ConversationLoop? _loop;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loop == null) {
      final state = AppScope.of(context);
      _loop = ConversationLoop(services: state.services, chat: state.chat, speaker: state.services.speaker);
      WidgetsBinding.instance.addPostFrameCallback((_) => _loop?.start());
    }
  }

  @override
  void dispose() {
    unawaited(_loop?.stop());
    _loop?.dispose();
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final s = AppScope.services(context);
    final loop = _loop!;
    return ListenableBuilder(
      listenable: Listenable.merge([loop, s.voices]),
      builder: (context, _) {
        final voice = s.voices.selected;
        final label = switch (loop.state) {
          TalkState.off => 'paused · tap to talk',
          TalkState.listening => 'listening…',
          TalkState.hearing => 'hearing you',
          TalkState.transcribing => 'writing down what you said',
          TalkState.thinking => 'thinking',
          TalkState.speaking => 'speaking · talk to interrupt',
        };
        return HandPage(
          actions: [
            DoodleButton(
              Doodle.wave,
              tooltip: 'Voices',
              onTap: () => Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VoicesScreen())),
            ),
          ],
          body: Column(
            children: [
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.symmetric(horizontal: gutter),
                  children: [
                    PageIntro(
                      'talk',
                      voice == null
                          ? 'Just talk; it answers out loud, then listens again. Pick a natural voice under voices.'
                          : 'Just talk; ${voice.name} answers out loud${voice.expressive && s.settings.expressiveSpeech ? ', with feeling,' : ''} then listens again.',
                      doodle: Doodle.mic,
                    ),
                    if (loop.problem != null) Body(loop.problem!, color: p.redPen),
                    if (loop.heard.isNotEmpty) ...[
                      const SectionHead('you said', padding: EdgeInsets.only(bottom: 4)),
                      Text(loop.heard, style: Hand.title.copyWith(fontSize: 26, color: p.ink)),
                    ],
                    if (loop.reply.isNotEmpty) ...[const SectionHead('phonedots'), Body(loop.reply)],
                    if (voice == null)
                      Padding(
                        padding: const EdgeInsets.only(top: 16),
                        child: HandLink(
                          'choose a natural voice ↗',
                          onTap: () =>
                              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const VoicesScreen())),
                        ),
                      ),
                  ],
                ),
              ),
              Pressable(
                onTap: () => loop.state == TalkState.off ? loop.start() : loop.stop(),
                scale: 0.94,
                child: AnimatedBuilder(
                  animation: _anim,
                  builder: (_, _) => MoodFace(
                    mood: loop.state == TalkState.speaking ? loop.mood : Mood.neutral,
                    talking: loop.state == TalkState.speaking,
                    listening: loop.state == TalkState.listening || loop.state == TalkState.hearing,
                    busy: loop.state == TalkState.transcribing || loop.state == TalkState.thinking,
                    level: loop.level,
                    t: _anim.value,
                    size: 170,
                  ),
                ),
              ),
              const SizedBox(height: 6),
              Text(label, style: Hand.label.copyWith(fontSize: 23, color: p.ink)),
              if (loop.state == TalkState.speaking && loop.mood != Mood.neutral)
                Meta('sounding ${loop.mood.name}', color: p.pencil),
              const SizedBox(height: 20),
            ],
          ),
        );
      },
    );
  }
}

/// A hand-drawn face whose eyes and mouth follow the mood, that moves its
/// mouth while talking and leans in while listening.
class MoodFace extends StatelessWidget {
  const MoodFace({
    super.key,
    required this.mood,
    this.talking = false,
    this.listening = false,
    this.busy = false,
    this.level = -100,
    this.t = 0,
    this.size = 160,
  });

  final Mood mood;
  final bool talking;
  final bool listening;
  final bool busy;
  final double level;
  final double t;
  final double size;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'PhoneDots, ${talking ? 'speaking' : (listening ? 'listening' : 'waiting')}',
    child: CustomPaint(
      size: Size.square(size),
      painter: _FacePainter(
        ink: context.pal.ink,
        marker: context.pal.marker,
        mood: mood,
        talking: talking,
        listening: listening,
        busy: busy,
        level: level,
        t: t,
      ),
    ),
  );
}

class _FacePainter extends CustomPainter {
  _FacePainter({
    required this.ink,
    required this.marker,
    required this.mood,
    required this.talking,
    required this.listening,
    required this.busy,
    required this.level,
    required this.t,
  });

  final Color ink;
  final Color marker;
  final Mood mood;
  final bool talking;
  final bool listening;
  final bool busy;
  final double level;
  final double t;

  @override
  void paint(Canvas canvas, Size size) {
    final c = size.center(Offset.zero);
    final r = size.width * 0.42;
    final pen = Paint()
      ..color = ink
      ..style = PaintingStyle.stroke
      ..strokeWidth = size.width * 0.028
      ..strokeCap = StrokeCap.round;
    // Listening: the head swells with your voice. Busy: a slow breath.
    final loud = ((level + 60) / 40).clamp(0.0, 1.0);
    final scale = listening ? 1 + loud * 0.08 : (busy ? 1 + 0.03 * sin(t * 2 * pi) : 1.0);
    canvas.save();
    canvas.translate(c.dx, c.dy);
    canvas.scale(scale);
    if (listening) {
      canvas.drawCircle(Offset.zero, r * 1.02, Paint()..color = marker.withValues(alpha: 0.35 + loud * 0.4));
    }
    // A slightly wobbly hand-drawn head.
    final head = Path();
    for (var i = 0; i <= 64; i++) {
      final a = i / 64 * 2 * pi;
      final w = r * (1 + 0.025 * sin(a * 3 + 1) + 0.015 * sin(a * 5));
      final pt = Offset(cos(a) * w, sin(a) * w);
      i == 0 ? head.moveTo(pt.dx, pt.dy) : head.lineTo(pt.dx, pt.dy);
    }
    canvas.drawPath(head, pen);

    final eyeY = -r * 0.18;
    final eyeX = r * 0.36;
    final fill = Paint()..color = ink;
    void eye(double x) {
      switch (mood) {
        case Mood.happy || Mood.laughing || Mood.excited:
          // Smiling eyes: little arches.
          canvas.drawArc(
            Rect.fromCenter(center: Offset(x, eyeY + r * 0.04), width: r * 0.24, height: r * 0.2),
            pi,
            pi,
            false,
            pen,
          );
        case Mood.calm || Mood.sympathetic || Mood.whisper:
          // Soft, half-closed.
          canvas.drawArc(
            Rect.fromCenter(center: Offset(x, eyeY), width: r * 0.24, height: r * 0.14),
            0,
            pi,
            false,
            pen,
          );
        case Mood.awe || Mood.confused:
          canvas.drawCircle(Offset(x, eyeY), r * 0.1, pen);
          canvas.drawCircle(Offset(x, eyeY), r * 0.04, fill);
        default:
          final blink = (t * 7 % 1) > 0.94; // an occasional blink
          blink
              ? canvas.drawLine(Offset(x - r * 0.07, eyeY), Offset(x + r * 0.07, eyeY), pen)
              : canvas.drawCircle(Offset(x, eyeY), r * 0.07, fill);
      }
    }

    eye(-eyeX);
    eye(eyeX);
    if (mood == Mood.sad || mood == Mood.sympathetic || mood == Mood.angry) {
      final tilt = mood == Mood.angry ? 1 : -1;
      for (final s in [-1.0, 1.0]) {
        canvas.drawLine(
          Offset(s * eyeX - r * 0.12, eyeY - r * 0.2 + tilt * s * r * 0.05),
          Offset(s * eyeX + r * 0.12, eyeY - r * 0.2 - tilt * s * r * 0.05),
          pen,
        );
      }
    }

    // Mouth: shape by mood, opening and closing while talking.
    final open = talking ? (0.25 + 0.75 * (0.5 + 0.5 * sin(t * 2 * pi * 3))) : 0.0;
    final my = r * 0.36;
    final mw = r * (mood == Mood.whisper ? 0.22 : 0.5);
    switch (mood) {
      case Mood.happy || Mood.laughing || Mood.excited:
        final rect = Rect.fromCenter(center: Offset(0, my - r * 0.08), width: mw, height: r * (0.3 + 0.2 * open));
        canvas.drawArc(rect, 0.1, pi - 0.2, false, pen);
        if (talking) canvas.drawArc(rect.deflate(r * 0.06), 0.3, pi - 0.6, false, fill..style = PaintingStyle.fill);
      case Mood.sad || Mood.angry:
        canvas.drawArc(
          Rect.fromCenter(center: Offset(0, my + r * 0.1), width: mw, height: r * 0.24),
          pi + 0.2,
          pi - 0.4,
          false,
          pen,
        );
      case Mood.awe || Mood.confused:
        canvas.drawOval(Rect.fromCenter(center: Offset(0, my), width: r * 0.18, height: r * (0.16 + 0.12 * open)), pen);
      default:
        if (open > 0.05) {
          canvas.drawOval(Rect.fromCenter(center: Offset(0, my), width: mw * 0.7, height: r * 0.22 * open), pen);
        } else {
          final m = Path()
            ..moveTo(-mw / 2, my)
            ..quadraticBezierTo(0, my + r * (mood == Mood.calm ? 0.1 : 0.06), mw / 2, my);
          canvas.drawPath(m, pen);
        }
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(_FacePainter o) =>
      o.t != t ||
      o.mood != mood ||
      o.talking != talking ||
      o.listening != listening ||
      o.level != level ||
      o.busy != busy;
}
