import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/theme.dart';

/// Burrow's hand-drawn components, ported from Shashank2577/Android-Showcase
/// (app/src/main/kotlin/.../ui/hand). Shapes are clean; only lines, the
/// marker swipe, the nav ring and the doodles wobble, and the wobble is
/// seeded so nothing jitters between frames.

int seedOf(Object? o) => (o?.hashCode ?? 0) & 0x7fff;

double _wobble(int seed, int i, double amount) {
  var x = (seed * 374761393 + i * 668265263) & 0xFFFFFFFF;
  x = ((x ^ (x >>> 13)) * 1274126177) & 0xFFFFFFFF;
  return ((x ^ (x >>> 16)) & 0xFFFF) / 65535 * 2 * amount - amount;
}

/// A slightly uneven stroke from [a] to [b].
Path handLinePath(Offset a, Offset b, int seed) {
  final p = Path()..moveTo(a.dx, a.dy);
  const segments = 4;
  for (var i = 1; i <= segments; i++) {
    final t = i / segments;
    final x = a.dx + (b.dx - a.dx) * t;
    final y = a.dy + (b.dy - a.dy) * t + _wobble(seed, i, 1.2);
    final cx = a.dx + (b.dx - a.dx) * (t - 0.5 / segments);
    p.quadraticBezierTo(cx, y + _wobble(seed, i + 10, 1), x, y);
  }
  return p;
}

/// A highlighter swipe across [r]: rough ends, slightly tilted.
Path swipePath(Rect r, int seed) {
  const pad = 3.0;
  final top = r.top + r.height * 0.38;
  final bottom = r.bottom - r.height * 0.04;
  final l = r.left - pad, rt = r.right + pad;
  return Path()
    ..moveTo(l + _wobble(seed, 1, pad), top + _wobble(seed, 2, 2))
    ..quadraticBezierTo((l + rt) / 2, top - 2 + _wobble(seed, 3, 1), rt, top + _wobble(seed, 4, 2))
    ..lineTo(rt + _wobble(seed, 5, pad), bottom + _wobble(seed, 6, 2))
    ..quadraticBezierTo((l + rt) / 2, bottom + 2, l, bottom + _wobble(seed, 7, 2))
    ..close();
}

/// A loose ring around [size] that doesn't quite close; [progress] draws it on.
Path handCirclePath(Size size, double progress, int seed) {
  final cx = size.width / 2, cy = size.height / 2;
  final rx = size.width / 2 + 9, ry = size.height / 2 + 4;
  const start = -2.2;
  final sweep = (2 * pi + 0.45) * progress;
  final p = Path();
  const steps = 48;
  for (var i = 0; i <= steps; i++) {
    final a = start + sweep * i / steps;
    final grow = 1 + 0.05 * i / steps + _wobble(seed, i ~/ 6, 0.015);
    final x = cx + cos(a) * rx * grow, y = cy + sin(a) * ry * grow;
    i == 0 ? p.moveTo(x, y) : p.lineTo(x, y);
  }
  return p;
}

Paint _stroke(Color c, double w) => Paint()
  ..color = c
  ..style = PaintingStyle.stroke
  ..strokeWidth = w
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

// ── Doodles ────────────────────────────────────────────────────────────────

/// Burrow's hand-drawn icon set: loose strokes on a 24×24 grid.
enum Doodle {
  arrow('M3 12.6 C8 11.7 14 12.5 20.2 11.9 M15.2 7.1 C17 8.9 18.9 10.6 20.6 11.9 C18.8 13.3 17 15 15.3 16.9'),
  back('M21 12.4 C16 11.6 10 12.5 3.8 12 M8.8 7 C7 8.8 5.1 10.5 3.4 12 C5.2 13.4 7 15.1 8.7 17'),
  close('M5.5 5.8 C10 10.2 14 14.1 18.6 18.4 M18.3 5.4 C13.9 9.8 10 13.9 5.6 18.7'),
  lock(
    'M6 11.2 C10 10.8 14.2 11 18.2 11.3 C18.5 14.2 18.4 17.4 18 20.5 C14 20.9 10 20.8 6.1 20.4 C5.7 17.4 5.7 14.2 6 11.2 Z M8.3 11 L8.3 8.2 C8.4 4.4 15.8 4.3 15.8 8.3 L15.7 11.1 M12 14.6 L12.1 17.2',
  ),
  tick('M4.2 12.8 C6 14.4 7.6 16.2 9.4 18.2 C12.6 13.6 16 9.2 20.2 5.2'),
  star('M12 3.2 L14.4 9.1 L20.8 9.4 L15.8 13.4 L17.6 19.7 L12.1 16.1 L6.5 19.8 L8.2 13.5 L3.2 9.5 L9.6 9 Z'),
  mic(
    'M9.2 6.3 C9.2 2.6 14.8 2.6 14.8 6.3 L14.8 11.6 C14.8 15.3 9.2 15.3 9.2 11.6 Z M6 11.4 C6.2 19 17.8 19 18 11.2 M12 17.4 L12 21 M8.6 21.1 L15.4 20.9',
  ),
  play('M8.2 5 C11.9 7.2 15.5 9.6 19.2 12 C15.5 14.4 11.9 16.9 8.3 19.1 C8 14.4 8 9.7 8.2 5 Z'),
  stop(
    'M6.4 6.6 C10.2 6.2 14 6.3 17.6 6.5 C17.9 10.2 17.8 14 17.5 17.6 C13.8 17.9 10 17.8 6.5 17.5 C6.1 13.9 6.1 10.2 6.4 6.6 Z',
  ),
  eye(
    'M2.6 12.2 C6.2 6 17.6 5.8 21.4 12 C17.8 18.1 6.4 18.3 2.6 12.2 Z M12 9.2 C15.8 9.3 15.8 14.9 12 14.9 C8.3 14.9 8.3 9.2 12 9.2',
  ),
  search(
    'M10.4 3.8 C15 3.9 17 7.6 16.6 10.6 C16.1 14.6 12 16.8 8.6 16 C5 15.1 3.4 11.4 4.2 8.4 C4.9 5.6 7.4 3.8 10.4 3.8 M15 15.2 C16.8 17 18.6 18.8 20.6 20.6',
  ),
  plus('M12.1 4.4 C12 9.5 11.9 14.6 12 19.6 M4.4 12.2 C9.5 11.9 14.5 11.9 19.6 12.1'),
  share(
    'M12 15 L12.1 3.6 M7.8 7.6 C9.2 6.2 10.6 4.9 12 3.5 C13.4 4.9 14.8 6.3 16.2 7.7 M6.6 11.4 L4.8 11.5 C4.6 14.6 4.7 17.8 5 20.6 C9.6 21 14.4 21 19 20.6 C19.3 17.6 19.3 14.6 19.1 11.5 L17.4 11.4',
  ),
  exclaim('M12.2 3.6 C12 7.6 11.9 11.4 11.8 15', [Offset(11.9, 19.6)]),
  squiggle(
    'M2.5 12.5 C4.5 8.5 6.5 8.5 8 12 C9.5 15.6 11.6 15.6 13 12 C14.6 8.4 16.6 8.6 18 12 C19.2 14.8 20.6 14.6 21.6 12.4',
  ),
  phone(
    'M8 3.4 C10.7 3.2 13.3 3.2 16 3.4 C16.4 9.1 16.4 14.9 16 20.6 C13.3 20.9 10.7 20.9 8 20.6 C7.6 14.9 7.6 9.1 8 3.4 Z M10.9 17.8 L13.1 17.8',
  ),
  trash(
    'M4.6 6.6 L19.4 6.4 M9.4 6.4 C9.4 4.6 14.6 4.6 14.6 6.4 M6.4 6.8 C6.8 11.4 7.2 16 7.8 20.4 C10.6 20.8 13.4 20.8 16.2 20.4 C16.8 16 17.2 11.4 17.6 6.8',
  ),
  person('M12 3.6 C15.4 3.6 15.6 9.8 12 9.9 C8.5 9.9 8.6 3.6 12 3.6 M4.6 20.4 C5.4 13.6 18.6 13.4 19.4 20.4'),
  wave(
    'M3 12 L5 12 M6.6 9 L6.6 15 M9.4 6 L9.4 18 M12.2 9.6 L12.2 14.4 M15 4.8 L15 19.2 M17.8 8.4 L17.8 15.6 M20.6 11 L20.6 13',
  ),
  pen(
    'M4.6 19.6 C4.8 18.2 5 16.8 5.4 15.4 L15.6 5.2 C16.6 4.2 18.6 4.4 19.4 5.4 C20.2 6.4 20 8 19 9 L8.8 19.2 C7.4 19.6 6 19.8 4.6 19.6 Z M14 6.8 L17.4 10.2',
  ),
  gear(
    'M12 5.8 C15.5 5.8 18.2 8.5 18.2 12 C18.2 15.5 15.5 18.2 12 18.2 C8.5 18.2 5.8 15.5 5.8 12 C5.8 8.5 8.5 5.8 12 5.8 Z M12 9.8 C13.3 9.8 14.2 10.7 14.2 12 C14.2 13.3 13.3 14.2 12 14.2 C10.7 14.2 9.8 13.3 9.8 12 C9.8 10.7 10.7 9.8 12 9.8 M12 2.8 L12 5.8 M12 18.2 L12 21.2 M2.8 12 L5.8 12 M18.2 12 L21.2 12 M5.6 5.6 L7.7 7.7 M16.3 16.3 L18.4 18.4 M5.6 18.4 L7.7 16.3 M16.3 7.7 L18.4 5.6',
  ),
  sun(
    'M12 8.4 C14.1 8.4 15.6 9.9 15.6 12 C15.6 14.1 14.1 15.6 12 15.6 C9.9 15.6 8.4 14.1 8.4 12 C8.4 9.9 9.9 8.4 12 8.4 Z M12 2.6 L12.1 5.2 M12 18.8 L11.9 21.4 M2.6 12 L5.2 11.9 M18.8 12 L21.4 12.1 M5.3 5.3 L7.2 7.2 M16.8 16.8 L18.7 18.7 M5.3 18.7 L7.2 16.8 M16.8 7.2 L18.7 5.3',
  ),
  moon(
    'M15.8 4.2 C10.6 4.4 7 8.4 7.2 13 C7.4 17.6 11.6 20.8 16.2 19.8 C17.8 19.4 19.2 18.6 20.2 17.4 C15.6 17.8 12 14.6 11.9 10.4 C11.8 7.8 13.4 5.6 15.8 4.2 Z',
    [Offset(5.4, 6.4), Offset(4.4, 15.2)],
  ),
  eyeOff('M2.6 12.2 C6.2 6 17.6 5.8 21.4 12 C17.8 18.1 6.4 18.3 2.6 12.2 Z M4.4 4.4 C10 10 14 14 19.8 19.6'),
  lockOpen(
    'M6 11.2 C10 10.8 14.2 11 18.2 11.3 C18.5 14.2 18.4 17.4 18 20.5 C14 20.9 10 20.8 6.1 20.4 C5.7 17.4 5.7 14.2 6 11.2 Z M8.3 11 L8.3 8.2 C8.4 4.6 15.4 4 15.9 7.4 M12 14.6 L12.1 17.2',
  ),
  camera(
    'M3.6 8.2 C3.6 7.2 4.4 6.6 5.4 6.6 L8.2 6.6 L9.6 4.6 L14.4 4.6 L15.8 6.6 L18.6 6.6 C19.6 6.6 20.4 7.3 20.4 8.3 L20.3 17.6 C20.3 18.6 19.5 19.3 18.5 19.3 L5.5 19.4 C4.5 19.4 3.7 18.7 3.7 17.7 Z M12 9.4 C14.2 9.4 15.6 11 15.6 12.9 C15.6 14.9 14.1 16.4 12 16.4 C9.9 16.4 8.4 14.9 8.4 12.9 C8.4 11 9.8 9.4 12 9.4',
  ),
  bubble(
    'M4 6.4 C4 4.9 5.2 4 6.6 4 L17.4 4 C18.9 4 20 5 20 6.4 L20 13.6 C20 15 18.9 16 17.4 16 L10.2 16 L6 19.8 L6.6 16 C5.2 16 4 15 4 13.6 Z M8 8.6 L16 8.4 M8 11.6 L13.4 11.5',
  ),
  people(
    'M8.6 4.6 C11 4.6 11.2 9.4 8.6 9.4 C6 9.4 6.2 4.6 8.6 4.6 M2.8 18.8 C3.2 13.8 14 13.6 14.4 18.8 M15.6 5.6 C17.8 5.6 18 9.8 15.6 9.8 M16.6 13.2 C19.2 13.6 21 15.6 21.2 18.6',
  ),
  mask(
    'M2.8 9 C6 8 9 8.4 12 10 C15 8.4 18 8 21.2 9 C21.2 13.2 19 16 16 16 C14 16 12.8 14.6 12 13.4 C11.2 14.6 10 16 8 16 C5 16 2.8 13.2 2.8 9 Z M6.6 11.4 C7.6 10.8 8.8 10.9 9.6 11.6 M14.4 11.6 C15.2 10.9 16.4 10.8 17.4 11.4',
  ),
  cloudOff(
    'M7 17.6 C4.6 17.6 3 16 3 14 C3 12 4.6 10.6 6.6 10.6 C7 7.6 9.4 5.6 12.2 5.6 C15 5.6 17.2 7.6 17.6 10.2 C19.6 10.4 21 11.8 21 13.8 C21 15.9 19.4 17.6 17.2 17.6 Z M4 4 L20 20.4',
  ),
  curl(
    'M3 5 C8 3.6 12.6 5.4 12.2 9 C11.8 12.4 7.4 12 8.2 9.2 C9 6.6 15 7.4 17.4 12.6 C18.4 14.8 18.8 17 18.6 19.6 M15.6 17.2 L18.6 19.8 L21 16.8',
  ),
  heart(
    'M12 20 C7 16.4 3.6 13.2 3.8 9.4 C4 6.6 6.2 4.8 8.6 5 C10.2 5.1 11.3 6 12 7.2 C12.7 6 13.8 5.1 15.4 5 C17.8 4.8 20 6.6 20.2 9.4 C20.4 13.2 17 16.4 12 20 Z',
  ),
  spark(
    'M12 3 C12.6 8.4 14.2 10.6 20 12 C14.2 13.4 12.6 15.6 12 21 C11.4 15.6 9.8 13.4 4 12 C9.8 10.6 11.4 8.4 12 3 Z',
  ),
  // PhoneDots additions in the same hand.
  clip(
    'M15.8 7.4 L8.6 14.6 C7.6 15.6 7.8 17.2 8.8 18 C9.8 18.8 11.2 18.6 12.1 17.7 L19 10.8 C20.8 9 20.6 6.2 18.9 4.8 C17.2 3.4 14.8 3.6 13.2 5.2 L6 12.4 C3.6 14.8 3.8 18.4 6.1 20.2',
  ),
  send(
    'M3.6 11.6 C9.6 9.2 15 6.8 20.6 3.6 C18.6 9.2 16.4 14.6 13.6 20.6 C12.6 17.6 11.6 14.6 10.6 12.6 C8.4 12.4 6 12 3.6 11.6 Z M10.6 12.6 L20.4 3.8',
  ),
  copy(
    'M8.6 8.4 C12 8.1 15.6 8.2 19 8.4 C19.3 12.2 19.3 16 19 19.7 C15.6 20 12 20 8.6 19.7 C8.3 16 8.3 12.2 8.6 8.4 Z M5.3 15.8 C5 12.2 5 8.4 5.2 4.6 C8.6 4.3 12 4.3 15.4 4.6 L15.5 6.2',
  ),
  history(
    'M4.4 12 C4.4 7.8 7.8 4.4 12 4.4 C16.2 4.4 19.6 7.8 19.6 12 C19.6 16.2 16.2 19.6 12 19.6 C9.6 19.6 7.4 18.4 6 16.6 M12 7.8 L12 12.2 L15 14 M3 9.2 L4.4 12.4 L7.4 10.6',
  ),
  newChat(
    'M4.6 19.6 C4.8 18.2 5 16.8 5.4 15.4 L15.6 5.2 C16.6 4.2 18.6 4.4 19.4 5.4 C20.2 6.4 20 8 19 9 L8.8 19.2 C7.4 19.6 6 19.8 4.6 19.6 Z M3.4 4.6 L10.6 4.4 M3.6 8.6 L7.4 8.4',
  ),
  chip(
    'M7 7.2 C10.4 6.8 13.8 6.9 17 7.2 C17.3 10.4 17.2 13.6 16.9 16.8 C13.6 17.2 10.4 17.1 7.1 16.8 C6.8 13.6 6.8 10.4 7 7.2 Z M10 4 L10 7 M14 4 L14 7 M10 17 L10 20 M14 17 L14 20 M4 10 L7 10 M4 14 L7 14 M17 10 L20 10 M17 14 L20 14',
  ),
  timer(
    'M12 7.4 C16 7.4 18.8 10.4 18.8 14 C18.8 17.8 15.8 20.6 12 20.6 C8.2 20.6 5.2 17.6 5.2 14 C5.2 10.2 8.2 7.4 12 7.4 Z M12 14 L14.6 11.4 M9.8 3.6 L14.2 3.4 M12 3.6 L12 7.2',
  ),
  calc(
    'M6.2 3.6 C10 3.4 14 3.4 17.8 3.6 C18.2 9.2 18.2 14.8 17.8 20.4 C14 20.7 10 20.7 6.2 20.4 C5.8 14.8 5.8 9.2 6.2 3.6 Z M8.6 6.4 L15.4 6.4 L15.4 9.4 L8.6 9.4 Z M9 12.6 L9.2 12.6 M12 12.6 L12.2 12.6 M15 12.6 L15.2 12.6 M9 16 L9.2 16 M12 16 L12.2 16 M15 16 L15.2 16',
  ),
  folder(
    'M3.4 7 C3.4 6 4 5.4 5 5.4 L9.4 5.2 L11.2 7.2 L19 7.2 C20 7.2 20.6 7.8 20.6 8.8 L20.4 17.8 C20.4 18.8 19.8 19.4 18.8 19.4 L5 19.6 C4 19.6 3.4 19 3.4 18 Z',
  ),
  flask(
    'M9.4 3.6 L14.6 3.6 M10.2 3.8 L10.2 9.4 C8 12.6 6 15.6 5 18 C4.6 19.4 5.4 20.4 6.8 20.4 L17.2 20.4 C18.6 20.4 19.4 19.4 19 18 C18 15.6 16 12.6 13.8 9.4 L13.8 3.8 M7.4 14.6 C10.4 15.2 13.4 13.8 16.6 14.6',
  ),
  book(
    'M12 6.4 C9.6 4.8 6.6 4.6 3.8 5.2 L3.8 18.6 C6.6 18 9.6 18.2 12 19.8 C14.4 18.2 17.4 18 20.2 18.6 L20.2 5.2 C17.4 4.6 14.4 4.8 12 6.4 Z M12 6.4 L12 19.6',
  ),
  image(
    'M4 5.4 C9.4 5 14.6 5 20 5.4 C20.4 9.8 20.4 14.2 20 18.6 C14.6 19 9.4 19 4 18.6 C3.6 14.2 3.6 9.8 4 5.4 Z M4.4 16.6 C7 13.4 9 11.8 11.4 14.4 C13.2 12.4 15.6 11.6 19.6 15.2',
    [Offset(15.4, 9.2)],
  ),
  doc(
    'M6 3.6 L14 3.4 L18.4 7.8 L18.2 20.4 C14.2 20.7 10 20.7 6 20.4 C5.6 14.8 5.6 9.2 6 3.6 Z M14 3.6 L14 8 L18.2 8 M8.6 12.4 L15.4 12.2 M8.6 15.8 L13.4 15.6',
  );

  const Doodle(this.d, [this.dots = const []]);
  final String d;
  final List<Offset> dots;

  static final Map<Doodle, Path> _cache = {};

  /// Parses the M/L/C/Z subset used by the doodles.
  Path get path => _cache.putIfAbsent(this, () {
    final p = Path();
    final tokens = RegExp(r'[MLCZ]|-?\d*\.?\d+').allMatches(d).map((m) => m.group(0)!).toList();
    var i = 0;
    var cmd = 'M';
    double n() => double.parse(tokens[i++]);
    while (i < tokens.length) {
      if (RegExp(r'[MLCZ]').hasMatch(tokens[i])) cmd = tokens[i++];
      switch (cmd) {
        case 'M':
          p.moveTo(n(), n());
          cmd = 'L';
        case 'L':
          p.lineTo(n(), n());
        case 'C':
          p.cubicTo(n(), n(), n(), n(), n(), n());
        case 'Z':
          p.close();
      }
    }
    return p;
  });
}

class DoodleIcon extends StatelessWidget {
  const DoodleIcon(this.doodle, {super.key, this.size = 24, this.color, this.stroke = 2, this.semanticLabel});
  final Doodle doodle;
  final double size;
  final Color? color;
  final double stroke;
  final String? semanticLabel;

  @override
  Widget build(BuildContext context) => Semantics(
    label: semanticLabel,
    child: CustomPaint(size: Size.square(size), painter: _DoodlePainter(doodle, color ?? context.pal.ink, stroke, 1)),
  );
}

class _DoodlePainter extends CustomPainter {
  _DoodlePainter(this.doodle, this.color, this.stroke, this.progress);
  final Doodle doodle;
  final Color color;
  final double stroke;
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    canvas.scale(s);
    var path = doodle.path;
    if (progress < 1) {
      final out = Path();
      for (final m in path.computeMetrics()) {
        out.addPath(m.extractPath(0, m.length * progress), Offset.zero);
      }
      path = out;
    }
    canvas.drawPath(path, _stroke(color, stroke / s));
    if (progress >= 1) {
      for (final d in doodle.dots) {
        canvas.drawCircle(d, stroke / s * 0.75, Paint()..color = color);
      }
    }
  }

  @override
  bool shouldRepaint(_DoodlePainter o) => o.progress != progress || o.color != color || o.doodle != doodle;
}

/// A doodle that draws itself in (e.g. the tick when a step finishes).
class DrawnDoodle extends StatefulWidget {
  const DrawnDoodle(
    this.doodle, {
    super.key,
    this.size = 24,
    this.color,
    this.stroke = 2.2,
    this.duration = const Duration(milliseconds: 360),
  });
  final Doodle doodle;
  final double size;
  final Color? color;
  final double stroke;
  final Duration duration;

  @override
  State<DrawnDoodle> createState() => _DrawnDoodleState();
}

class _DrawnDoodleState extends State<DrawnDoodle> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: widget.duration)..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    builder: (_, _) => CustomPaint(
      size: Size.square(widget.size),
      painter: _DoodlePainter(
        widget.doodle,
        widget.color ?? context.pal.ink,
        widget.stroke,
        Curves.easeOutCubic.transform(_c.value),
      ),
    ),
  );
}

// ── Text ───────────────────────────────────────────────────────────────────

/// Text with a marker swipe behind the first occurrence of [mark].
class MarkedText extends StatelessWidget {
  const MarkedText(this.text, {super.key, this.mark, this.style, this.color, this.maxLines});
  final String text;
  final String? mark;
  final TextStyle? style;
  final Color? color;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final s = (style ?? Hand.title).copyWith(color: color ?? style?.color ?? p.ink);
    final start = mark == null ? -1 : text.indexOf(mark!);
    if (start < 0) {
      return Text(text, style: s, maxLines: maxLines, overflow: maxLines == null ? null : TextOverflow.ellipsis);
    }
    final scaler = MediaQuery.textScalerOf(context);
    return LayoutBuilder(
      builder: (context, box) {
        final tp = TextPainter(
          text: TextSpan(text: text, style: s),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: maxLines,
        )..layout(maxWidth: box.maxWidth);
        final boxes = tp.getBoxesForSelection(TextSelection(baseOffset: start, extentOffset: start + mark!.length));
        return CustomPaint(
          painter: _SwipePainter(boxes.map((b) => b.toRect()).toList(), p.marker, seedOf(mark)),
          // Text on the marker is always marker ink, so it stays readable in dark mode.
          child: Text.rich(
            TextSpan(
              style: s,
              children: [
                TextSpan(text: text.substring(0, start)),
                TextSpan(
                  text: mark,
                  style: TextStyle(color: p.markerInk),
                ),
                TextSpan(text: text.substring(start + mark!.length)),
              ],
            ),
            maxLines: maxLines,
            overflow: maxLines == null ? null : TextOverflow.ellipsis,
          ),
        );
      },
    );
  }
}

class _SwipePainter extends CustomPainter {
  _SwipePainter(this.rects, this.color, this.seed);
  final List<Rect> rects;
  final Color color;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    for (var i = 0; i < rects.length; i++) {
      canvas.drawPath(swipePath(rects[i], seed + i), Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_SwipePainter o) => o.rects != rects || o.color != color;
}

class Meta extends StatelessWidget {
  const Meta(this.text, {super.key, this.color, this.maxLines, this.align});
  final String text;
  final Color? color;
  final int? maxLines;
  final TextAlign? align;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: context.text.bodySmall?.copyWith(color: color ?? context.pal.pencil),
    maxLines: maxLines,
    overflow: maxLines == null ? null : TextOverflow.ellipsis,
    textAlign: align,
  );
}

class Body extends StatelessWidget {
  const Body(this.text, {super.key, this.color, this.align});
  final String text;
  final Color? color;
  final TextAlign? align;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: context.text.bodyMedium?.copyWith(color: color),
    textAlign: align,
  );
}

/// The top of a page: its name and one plain line about what you can do here.
class PageIntro extends StatelessWidget {
  const PageIntro(this.title, this.purpose, {super.key, this.mark, this.doodle});
  final String title;
  final String purpose;
  final String? mark;
  final Doodle? doodle;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: MarkedText(title, mark: mark, style: Hand.headline),
            ),
            if (doodle != null)
              Padding(
                padding: const EdgeInsets.only(left: 12, bottom: 6),
                child: Transform.rotate(
                  angle: -0.14,
                  child: DoodleIcon(doodle!, size: 40, color: context.pal.pencil, stroke: 1.8),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Body(purpose, color: context.pal.pencil),
      ],
    ),
  );
}

/// A hand-lettered section head with an optional note on the right.
class SectionHead extends StatelessWidget {
  const SectionHead(
    this.text, {
    super.key,
    this.note,
    this.mark = false,
    this.padding = const EdgeInsets.only(top: 22, bottom: 6),
  });
  final String text;
  final String? note;
  final bool mark;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Flexible(
          child: MarkedText(text, mark: mark ? text : null, style: Hand.title.copyWith(fontSize: 27)),
        ),
        if (note != null) ...[
          const Spacer(),
          Padding(padding: const EdgeInsets.only(left: 12, bottom: 4), child: Meta(note!)),
        ],
      ],
    ),
  );
}

// ── Lines ──────────────────────────────────────────────────────────────────

class HandDivider extends StatelessWidget {
  const HandDivider({super.key, this.seed = 1, this.padding = const EdgeInsets.symmetric(vertical: 8)});
  final int seed;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Padding(
    padding: padding,
    child: CustomPaint(size: const Size(double.infinity, 4), painter: _LinePainter(context.pal.rule, 1.4, seed, 1)),
  );
}

class _LinePainter extends CustomPainter {
  _LinePainter(this.color, this.width, this.seed, this.fraction);
  final Color color;
  final double width;
  final int seed;
  final double fraction;

  @override
  void paint(Canvas canvas, Size size) {
    if (fraction <= 0) return;
    final y = size.height / 2;
    canvas.drawPath(handLinePath(Offset(0, y), Offset(size.width * fraction, y), seed), _stroke(color, width));
  }

  @override
  bool shouldRepaint(_LinePainter o) => o.fraction != fraction || o.color != color;
}

/// Graphite track with an inked part.
class HandProgress extends StatelessWidget {
  const HandProgress(this.fraction, {super.key});
  final double? fraction;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return TweenAnimationBuilder<double>(
      tween: Tween(end: fraction ?? 0),
      duration: const Duration(milliseconds: 400),
      builder: (_, f, _) => SizedBox(
        height: 10,
        child: Stack(
          children: [
            Positioned.fill(child: CustomPaint(painter: _LinePainter(p.rule, 2, 9, 1))),
            Positioned.fill(child: CustomPaint(painter: _LinePainter(p.ink, 3, 9, fraction == null ? 0 : f))),
          ],
        ),
      ),
    );
  }
}

/// A wobbly underline under its child.
class HandUnderline extends StatelessWidget {
  const HandUnderline({super.key, required this.child, this.color, this.seed = 3});
  final Widget child;
  final Color? color;
  final int seed;

  @override
  Widget build(BuildContext context) => CustomPaint(
    foregroundPainter: _UnderlinePainter((color ?? context.pal.ink).withValues(alpha: 0.8), seed),
    child: child,
  );
}

class _UnderlinePainter extends CustomPainter {
  _UnderlinePainter(this.color, this.seed);
  final Color color;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height - 1;
    canvas.drawPath(handLinePath(Offset(0, y), Offset(size.width, y + _wobble(seed, 0, 1)), seed), _stroke(color, 1.6));
  }

  @override
  bool shouldRepaint(_UnderlinePainter o) => o.color != color;
}

// ── Actions ────────────────────────────────────────────────────────────────

/// Calm press feedback: a small squish and a light haptic tick.
class Pressable extends StatefulWidget {
  const Pressable({super.key, required this.child, this.onTap, this.scale = 0.97, this.haptic = true});
  final Widget child;
  final VoidCallback? onTap;
  final double scale;
  final bool haptic;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _down = false;

  void _set(bool v) {
    if (widget.onTap != null && _down != v) setState(() => _down = v);
  }

  @override
  Widget build(BuildContext context) => widget.onTap == null
      ? widget
            .child // not tappable, so not announced as a button either
      : GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _set(true),
          onTapUp: (_) => _set(false),
          onTapCancel: () => _set(false),
          onTap: widget.onTap == null
              ? null
              : () {
                  if (widget.haptic) HapticFeedback.selectionClick();
                  widget.onTap!();
                },
          child: AnimatedScale(
            scale: _down ? widget.scale : 1,
            duration: Duration(milliseconds: _down ? 90 : 260),
            curve: _down ? Curves.easeOut : Curves.easeOutBack,
            child: widget.child,
          ),
        );
}

/// The one primary action per screen: a black pill with Caveat lettering.
class InkButton extends StatelessWidget {
  const InkButton(
    this.text, {
    super.key,
    this.onTap,
    this.busy = false,
    this.trailing,
    this.danger = false,
    this.expand = false,
  });
  final String text;
  final VoidCallback? onTap;
  final bool busy;
  final Doodle? trailing;
  final bool danger;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final enabled = onTap != null && !busy;
    return Pressable(
      onTap: enabled ? onTap : null,
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: onTap == null ? 0.35 : 1,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          width: expand ? double.infinity : null,
          padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
          decoration: ShapeDecoration(color: danger ? p.redPen : p.ink, shape: const StadiumBorder()),
          child: Row(
            mainAxisSize: expand ? MainAxisSize.max : MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (busy) ...[
                SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2, color: p.paper)),
                const SizedBox(width: 12),
              ],
              Flexible(
                child: Text(
                  text,
                  style: Hand.label.copyWith(fontSize: 23, color: p.paper),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (trailing != null) ...[const SizedBox(width: 10), DoodleIcon(trailing!, size: 20, color: p.paper)],
            ],
          ),
        ),
      ),
    );
  }
}

/// A secondary action that still reads as a button: an outlined pill.
class PillButton extends StatelessWidget {
  const PillButton(this.text, {super.key, this.onTap, this.leading, this.color});
  final String text;
  final VoidCallback? onTap;
  final Doodle? leading;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.pal.ink;
    return Pressable(
      onTap: onTap,
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 8),
          decoration: ShapeDecoration(
            shape: StadiumBorder(side: BorderSide(color: c, width: 1.6)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (leading != null) ...[DoodleIcon(leading!, size: 18, color: c), const SizedBox(width: 8)],
              Flexible(
                child: Text(
                  text,
                  style: Hand.label.copyWith(color: c),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tertiary action: hand-lettered text with a wobbly underline.
class HandLink extends StatelessWidget {
  const HandLink(this.text, {super.key, this.onTap, this.color, this.style});
  final String text;
  final VoidCallback? onTap;
  final Color? color;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final c = color ?? context.pal.ink;
    return Pressable(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 48),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
          child: Opacity(
            opacity: onTap == null ? 0.4 : 1,
            child: HandUnderline(
              color: c,
              seed: text.length,
              child: Text(text, style: (style ?? Hand.label).copyWith(color: c)),
            ),
          ),
        ),
      ),
    );
  }
}

/// A choice drawn as a pill: filled in ink when picked.
class ChoicePill extends StatelessWidget {
  const ChoicePill(this.text, {super.key, required this.selected, required this.onTap, this.leading});
  final String text;
  final bool selected;
  final VoidCallback onTap;
  final Doodle? leading;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final fg = selected ? p.paper : p.ink;
    return Pressable(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        constraints: const BoxConstraints(minHeight: 48, maxWidth: 280),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: ShapeDecoration(
          color: selected ? p.ink : Colors.transparent,
          shape: StadiumBorder(side: BorderSide(color: p.ink, width: 1.6)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (leading != null) ...[DoodleIcon(leading!, size: 18, color: fg), const SizedBox(width: 8)],
            Flexible(
              child: Text(
                text,
                style: Hand.label.copyWith(color: fg),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A small drawn icon button, 48 dp to touch.
class DoodleButton extends StatelessWidget {
  const DoodleButton(this.doodle, {super.key, required this.tooltip, this.onTap, this.color, this.size = 26});
  final Doodle doodle;
  final String tooltip;
  final VoidCallback? onTap;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Pressable(
      onTap: onTap,
      scale: 0.88,
      child: SizedBox.square(
        dimension: 48,
        child: Center(
          child: DoodleIcon(
            doodle,
            size: size,
            color: onTap == null ? context.pal.graphite : color,
            semanticLabel: tooltip,
          ),
        ),
      ),
    ),
  );
}

/// A drawn toggle: an ink pill with a ticked knob when on, an outline when off.
class HandSwitch extends StatelessWidget {
  const HandSwitch({super.key, required this.value, this.onChanged, this.label});
  final bool value;
  final ValueChanged<bool>? onChanged;

  /// What the switch turns on or off, read out by screen readers.
  final String? label;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Semantics(
      container: true,
      toggled: value,
      enabled: onChanged != null,
      label: label,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      child: ExcludeSemantics(
        child: Pressable(
          onTap: onChanged == null ? null : () => onChanged!(!value),
          scale: 0.92,
          // The drawn switch is 52x30; the touch area is a full 56x48.
          child: Container(
            width: 56,
            height: 48,
            alignment: Alignment.center,
            child: Opacity(
              opacity: onChanged == null ? 0.4 : 1,
              child: TweenAnimationBuilder<double>(
                tween: Tween(end: value ? 1 : 0),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOut,
                builder: (_, t, _) => SizedBox(
                  width: 52,
                  height: 30,
                  child: Stack(
                    children: [
                      Positioned.fill(child: CustomPaint(painter: _SwitchPainter(t, p))),
                      if (t > 0.6)
                        Positioned(
                          right: 7,
                          top: 7,
                          child: Opacity(
                            opacity: (t - 0.6) / 0.4,
                            child: DoodleIcon(Doodle.tick, size: 16, stroke: 2.2, color: p.ink),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _SwitchPainter extends CustomPainter {
  _SwitchPainter(this.t, this.p);
  final double t;
  final Palette p;

  @override
  void paint(Canvas canvas, Size size) {
    final r = size.height / 2;
    final rr = RRect.fromRectAndRadius(Offset.zero & size, Radius.circular(r));
    if (t > 0) canvas.drawRRect(rr, Paint()..color = p.ink.withValues(alpha: t));
    canvas.drawRRect(rr.deflate(0.9), _stroke(p.ink, 1.8));
    final knob = r - 4;
    final c = Offset(r + (size.width - 2 * r) * t, r);
    canvas.drawCircle(c, knob, Paint()..color = p.paper);
    canvas.drawCircle(c, knob, _stroke(p.ink, 1.6));
  }

  @override
  bool shouldRepaint(_SwitchPainter o) => o.t != t || o.p != p;
}

/// A hand-lettered label with a switch: privacy and permission rows.
class SwitchRow extends StatelessWidget {
  const SwitchRow({
    super.key,
    required this.title,
    this.body,
    required this.value,
    required this.onChanged,
    this.doodle,
  });
  final String title;
  final String? body;
  final bool value;
  final ValueChanged<bool> onChanged;
  final Doodle? doodle;

  @override
  Widget build(BuildContext context) => Pressable(
    onTap: () => onChanged(!value),
    scale: 0.99,
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          if (doodle != null) ...[DoodleIcon(doodle!, color: context.pal.pencil), const SizedBox(width: 14)],
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: Hand.label.copyWith(fontSize: 23, color: context.pal.ink)),
                if (body != null) Meta(body!),
              ],
            ),
          ),
          const SizedBox(width: 12),
          HandSwitch(value: value, onChanged: onChanged, label: title),
        ],
      ),
    ),
  );
}

/// One big hand-lettered line that leads somewhere, ending in a circled
/// arrow. A door with nowhere to go is drawn in pencil.
class Door extends StatelessWidget {
  const Door(
    this.text, {
    super.key,
    this.onTap,
    this.mark,
    this.meta,
    this.alert = false,
    this.leading,
    this.style,
    this.trailing,
  });
  final String text;
  final VoidCallback? onTap;
  final String? mark;
  final String? meta;
  final bool alert;
  final Doodle? leading;
  final TextStyle? style;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Pressable(
      onTap: onTap,
      scale: 0.985,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            if (leading != null) ...[DoodleIcon(leading!, color: p.ink), const SizedBox(width: 14)],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Flexible(
                        child: MarkedText(
                          text,
                          mark: mark,
                          style: style ?? Hand.door,
                          color: onTap != null ? p.ink : p.pencil,
                        ),
                      ),
                      if (alert)
                        Padding(
                          padding: const EdgeInsets.only(left: 2, top: 4),
                          child: DoodleIcon(
                            Doodle.exclaim,
                            size: 22,
                            color: p.redPen,
                            stroke: 2.6,
                            semanticLabel: 'needs you',
                          ),
                        ),
                    ],
                  ),
                  if (meta != null) Padding(padding: const EdgeInsets.only(top: 2), child: Meta(meta!)),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 12),
              trailing!,
            ] else if (onTap != null) ...[
              const SizedBox(width: 12),
              const CircledArrow(),
            ],
          ],
        ),
      ),
    );
  }
}

class CircledArrow extends StatelessWidget {
  const CircledArrow({super.key, this.size = 40});
  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      shape: BoxShape.circle,
      border: Border.all(color: context.pal.ink, width: 1.6),
    ),
    child: Center(child: DoodleIcon(Doodle.arrow, size: size * 0.55)),
  );
}

/// A small pill tag: outlined in rule, or marked.
class HandTag extends StatelessWidget {
  const HandTag(this.text, {super.key, this.marked = false, this.onTap, this.color});
  final String text;
  final bool marked;
  final VoidCallback? onTap;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Pressable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
        decoration: ShapeDecoration(
          color: marked ? p.marker : null,
          shape: StadiumBorder(side: marked ? BorderSide.none : BorderSide(color: color ?? p.rule, width: 1.2)),
        ),
        child: Text(
          text,
          style: Hand.small.copyWith(color: marked ? p.markerInk : (color ?? p.ink)),
          maxLines: 1,
          softWrap: false,
        ),
      ),
    );
  }
}

/// The "stays on this phone" stamp.
class OnDeviceStamp extends StatelessWidget {
  const OnDeviceStamp({super.key, this.text = 'on this phone'});
  final String text;

  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      DoodleIcon(Doodle.lock, size: 14, color: context.pal.pencil, stroke: 1.6),
      const SizedBox(width: 5),
      Meta(text),
    ],
  );
}

/// Numbered steps so a flow says up front what will happen.
class Steps extends StatelessWidget {
  const Steps(this.steps, {super.key, this.current = -1});
  final List<String> steps;
  final int current;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Column(
      children: [
        for (var i = 0; i < steps.length; i++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 28,
                  child: i < current
                      ? DoodleIcon(Doodle.tick, size: 20, color: p.pencil)
                      : Text('${i + 1}.', style: Hand.label.copyWith(color: i == current ? p.ink : p.pencil)),
                ),
                Expanded(child: Body(steps[i], color: i <= current ? p.ink : p.pencil)),
              ],
            ),
          ),
      ],
    );
  }
}

/// Inline confirmation after something happened, with an optional next step.
class DoneNote extends StatelessWidget {
  const DoneNote(this.text, {super.key, this.action, this.onAction});
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Row(
    children: [
      const DrawnDoodle(Doodle.tick, size: 22),
      const SizedBox(width: 8),
      Expanded(child: Body(text)),
      if (action != null) HandLink(action!, onTap: onAction),
    ],
  );
}

class HandEmpty extends StatelessWidget {
  const HandEmpty({super.key, required this.title, this.body, this.doodle = Doodle.spark, this.action});
  final String title;
  final String? body;
  final Doodle doodle;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 28),
    child: Column(
      children: [
        Transform.rotate(angle: -0.12, child: DoodleIcon(doodle, size: 44, color: context.pal.pencil, stroke: 1.8)),
        const SizedBox(height: 10),
        Text(
          title,
          style: Hand.title.copyWith(color: context.pal.ink),
          textAlign: TextAlign.center,
        ),
        if (body != null)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Meta(body!, align: TextAlign.center),
          ),
        if (action != null) Padding(padding: const EdgeInsets.only(top: 14), child: action!),
      ],
    ),
  );
}

// ── Page & navigation ──────────────────────────────────────────────────────

/// The quiet page every screen sits on: a top row (back doodle or the
/// wordmark, plus actions), and a centred scrolling column with gutters.
class HandPage extends StatelessWidget {
  const HandPage({
    super.key,
    this.children,
    this.body,
    this.wordmark = false,
    this.actions = const [],
    this.bottom,
    this.onBack,
  });
  final List<Widget>? children;

  /// Use instead of [children] for screens that manage their own scrolling.
  final Widget? body;
  final bool wordmark;
  final List<Widget> actions;
  final Widget? bottom;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    final canPop = ModalRoute.of(context)?.canPop ?? false;
    final back = onBack ?? (canPop ? () => Navigator.of(context).maybePop() : null);
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: Column(
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: maxColumn + gutter * 2),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  child: Row(
                    children: [
                      if (back != null) DoodleButton(Doodle.back, tooltip: 'Back', onTap: back),
                      // The wordmark gives way first, so actions never overflow.
                      Expanded(
                        child: wordmark
                            ? Padding(
                                padding: EdgeInsets.only(left: back == null ? 12 : 0),
                                child: const Align(
                                  alignment: Alignment.centerLeft,
                                  child: FittedBox(fit: BoxFit.scaleDown, child: Wordmark()),
                                ),
                              )
                            : const SizedBox.shrink(),
                      ),
                      ...actions,
                    ],
                  ),
                ),
              ),
            ),
            Expanded(
              child:
                  body ??
                  ListView(
                    physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
                    padding: const EdgeInsets.only(bottom: 32),
                    children: [for (final c in children ?? const <Widget>[]) Column0(child: c)],
                  ),
            ),
            if (bottom != null)
              Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: maxColumn + gutter * 2),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: gutter, vertical: 12),
                    child: bottom,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Centres a child in the page column (560 dp max, 24 dp gutters).
class Column0 extends StatelessWidget {
  const Column0({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: maxColumn + gutter * 2),
      // Full column width, content starting at the left edge like the body copy.
      child: SizedBox(
        width: double.infinity,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: gutter),
          child: Align(alignment: AlignmentDirectional.centerStart, child: child),
        ),
      ),
    ),
  );
}

class Wordmark extends StatelessWidget {
  const Wordmark({super.key});

  @override
  Widget build(BuildContext context) => Text('phonedots.', style: Hand.title.copyWith(color: context.pal.ink));
}

/// Four hand-lettered words; the current one gets a loose drawn ring.
class HandNav extends StatelessWidget {
  const HandNav({super.key, required this.index, required this.onTap, required this.labels});
  final int index;
  final ValueChanged<int> onTap;
  final List<String> labels;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    // One size for every word, small enough to fit five on a narrow phone,
    // so FittedBox rarely has to shrink any single word on its own.
    final perWord = (MediaQuery.sizeOf(context).width - 24) / labels.length - 30;
    final navSize = (perWord / MediaQuery.textScalerOf(context).scale(1) / 2.6).clamp(15.0, 23.0);
    return Container(
      color: p.paper,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: gutter),
              child: HandDivider(padding: EdgeInsets.zero),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  for (var i = 0; i < labels.length; i++) ...[
                    if (i > 0)
                      ExcludeSemantics(
                        child: Text('·', style: Hand.label.copyWith(color: p.pencil)),
                      ),
                    Flexible(
                      child: Pressable(
                        onTap: () => onTap(i),
                        scale: 0.92,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 14),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(minWidth: 30),
                            child: TweenAnimationBuilder<double>(
                              tween: Tween(end: i == index ? 1 : 0),
                              duration: const Duration(milliseconds: 450),
                              builder: (_, ring, child) =>
                                  CustomPaint(painter: _RingPainter(p.ink, ring, i + 2), child: child),
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: Text(
                                  labels[i],
                                  style: Hand.label.copyWith(fontSize: navSize, color: i == index ? p.ink : p.pencil),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter(this.color, this.progress, this.seed);
  final Color color;
  final double progress;
  final int seed;

  @override
  void paint(Canvas canvas, Size size) {
    if (progress <= 0) return;
    canvas.drawPath(handCirclePath(size, progress, seed), _stroke(color, 1.8));
  }

  @override
  bool shouldRepaint(_RingPainter o) => o.progress != progress || o.color != color;
}

// ── Motion ─────────────────────────────────────────────────────────────────

/// Rises and fades in once, staggered by [index]; in lists this plays as
/// items scroll into view. The delay is part of the animation, so disposing
/// cancels it cleanly.
class Enter extends StatefulWidget {
  const Enter({super.key, required this.child, this.index = 0, this.from = const Offset(0, 10)});
  final Widget child;
  final int index;
  final Offset from;

  @override
  State<Enter> createState() => _EnterState();
}

class _EnterState extends State<Enter> with SingleTickerProviderStateMixin {
  late final int _delay = 40 * min(widget.index, 8);
  late final _c = AnimationController(
    vsync: this,
    duration: Duration(milliseconds: 320 + _delay),
  )..forward();
  late final _a = CurvedAnimation(
    parent: _c,
    curve: Interval(_delay / (320 + _delay), 1, curve: Curves.easeOutCubic),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _a,
    child: widget.child,
    builder: (_, child) => Opacity(
      opacity: _a.value,
      child: Transform.translate(offset: widget.from * (1 - _a.value), child: child),
    ),
  );
}

/// Three dots hopping in turn: the "thinking" indicator.
class HoppingDots extends StatefulWidget {
  const HoppingDots({super.key, this.size = 7});
  final double size;

  @override
  State<HoppingDots> createState() => _HoppingDotsState();
}

class _HoppingDotsState extends State<HoppingDots> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    final colors = [p.ink, p.pencil, p.graphite];
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
              child: Transform.translate(
                offset: Offset(0, -5 * max(0, sin((_c.value - i * 0.18) * 2 * pi))),
                child: Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(color: colors[i], shape: BoxShape.circle),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// A pencil ring that keeps drawing while something runs.
class Scribbling extends StatefulWidget {
  const Scribbling({super.key, this.size = 16});
  final double size;

  @override
  State<Scribbling> createState() => _ScribblingState();
}

class _ScribblingState extends State<Scribbling> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 1100))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox.square(
    dimension: widget.size,
    child: AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Transform.rotate(
        angle: _c.value * 2 * pi,
        child: CustomPaint(painter: _ArcPainter(context.pal.pencil)),
      ),
    ),
  );
}

class _ArcPainter extends CustomPainter {
  _ArcPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) =>
      canvas.drawArc((Offset.zero & size).deflate(1.5), 0, pi * 1.4, false, _stroke(color, 2));

  @override
  bool shouldRepaint(_ArcPainter o) => o.color != color;
}
