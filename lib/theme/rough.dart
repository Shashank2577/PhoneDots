import 'dart:math';

import 'package:flutter/material.dart';

/// Hand-drawn geometry. Shapes wobble with smooth, seeded noise so they look
/// drawn with a pen yet stay perfectly still between frames.
class Rough {
  static final Map<String, Path> _cache = {};

  static double _noise(double t, int seed, int pass) {
    final r = Random(seed * 31 + pass * 7);
    var v = 0.0;
    for (var k = 1; k <= 3; k++) {
      v += sin(2 * pi * (t * (k + r.nextInt(2)) + r.nextDouble())) / k;
    }
    return v / 1.6;
  }

  /// Outline of a rounded rect drawn by hand. [pass] gives a second, slightly
  /// different stroke; open outlines overshoot like a pen that didn't stop.
  static Path rect(
    Rect rect, {
    int seed = 1,
    double radius = 12,
    double roughness = 1,
    int pass = 0,
    bool closed = true,
  }) {
    final key =
        '${rect.left.round()},${rect.top.round()},${rect.width.round()},${rect.height.round()},$seed,$radius,$roughness,$pass,$closed';
    final hit = _cache[key];
    if (hit != null) return hit;
    if (_cache.length > 600) _cache.clear();

    final r = min(radius, min(rect.width, rect.height) / 2);
    final metric = (Path()..addRRect(RRect.fromRectAndRadius(rect, Radius.circular(r)))).computeMetrics().first;
    final length = metric.length;
    final n = max(12, (length / 14).round());
    final amp = roughness * min(1.6, 0.6 + min(rect.width, rect.height) / 90);
    final start = Random(seed + pass).nextDouble() * length;
    final span = closed ? 1.0 : 1.04;
    final pts = <Offset>[];
    for (var i = 0; i <= n; i++) {
      final t = i / n * span;
      final tangent = metric.getTangentForOffset((start + t * length) % length)!;
      final normal = Offset(-tangent.vector.dy, tangent.vector.dx);
      pts.add(tangent.position + normal * (amp * _noise(t, seed, pass)));
    }
    final path = _smooth(pts, closed: closed);
    _cache[key] = path;
    return path;
  }

  /// A wobbly line from [a] to [b].
  static Path line(Offset a, Offset b, {int seed = 1, double roughness = 1}) {
    final d = b - a;
    final len = d.distance;
    if (len == 0) return Path();
    final normal = Offset(-d.dy, d.dx) / len;
    final n = max(3, (len / 18).round());
    final pts = [for (var i = 0; i <= n; i++) a + d * (i / n) + normal * (roughness * 0.9 * _noise(i / n, seed, 0))];
    return _smooth(pts, closed: false);
  }

  /// An ellipse-ish loop that overshoots, like circling something with a pen.
  static Path scribbleCircle(Rect rect, {int seed = 1, double turns = 1.15}) {
    final c = rect.center;
    final rx = rect.width / 2, ry = rect.height / 2;
    final rnd = Random(seed);
    final start = rnd.nextDouble() * 2 * pi;
    const n = 36;
    final pts = <Offset>[];
    for (var i = 0; i <= n * turns; i++) {
      final a = start + i / n * 2 * pi;
      final wobble = 1 + 0.06 * _noise(i / n, seed, 1) + 0.04 * i / n;
      pts.add(c + Offset(cos(a) * rx * wobble, sin(a) * ry * wobble));
    }
    return _smooth(pts, closed: false);
  }

  /// A check mark stroke inside [rect].
  static Path check(Rect rect) => Path()
    ..moveTo(rect.left + rect.width * 0.12, rect.top + rect.height * 0.55)
    ..quadraticBezierTo(
      rect.left + rect.width * 0.3,
      rect.top + rect.height * 0.7,
      rect.left + rect.width * 0.4,
      rect.top + rect.height * 0.9,
    )
    ..quadraticBezierTo(
      rect.left + rect.width * 0.6,
      rect.top + rect.height * 0.35,
      rect.left + rect.width * 0.95,
      rect.top + rect.height * 0.08,
    );

  /// Diagonal pen hatching clipped to [clip].
  static void hachure(Canvas canvas, Path clip, Rect bounds, Paint paint, {double gap = 6, int seed = 1}) {
    canvas.save();
    canvas.clipPath(clip);
    final h = bounds.height;
    for (var x = bounds.left - h; x < bounds.right + h; x += gap) {
      canvas.drawPath(
        line(Offset(x, bounds.bottom + 2), Offset(x + h, bounds.top - 2), seed: seed + x.round(), roughness: 0.6),
        paint,
      );
    }
    canvas.restore();
  }

  /// Catmull-Rom spline through points.
  static Path _smooth(List<Offset> p, {required bool closed}) {
    final path = Path()..moveTo(p.first.dx, p.first.dy);
    Offset at(int i) => closed ? p[(i + p.length) % p.length] : p[i.clamp(0, p.length - 1)];
    final count = closed ? p.length : p.length - 1;
    for (var i = 0; i < count; i++) {
      final p0 = at(i - 1), p1 = at(i), p2 = at(i + 1), p3 = at(i + 2);
      final c1 = p1 + (p2 - p0) / 6;
      final c2 = p2 - (p3 - p1) / 6;
      path.cubicTo(c1.dx, c1.dy, c2.dx, c2.dy, p2.dx, p2.dy);
    }
    if (closed) path.close();
    return path;
  }

  /// Returns the first [fraction] of [path], for draw-on animations.
  static Path partial(Path path, double fraction) {
    final out = Path();
    if (fraction <= 0) return out;
    for (final m in path.computeMetrics()) {
      out.addPath(m.extractPath(0, m.length * fraction.clamp(0, 1)), Offset.zero);
    }
    return out;
  }
}

Paint _pen(Color color, double width) => Paint()
  ..color = color
  ..style = PaintingStyle.stroke
  ..strokeWidth = width
  ..strokeCap = StrokeCap.round
  ..strokeJoin = StrokeJoin.round;

/// A Material [OutlinedBorder] drawn by hand, so every themed button, card,
/// chip, dialog and sheet gets the sketch look for free.
class RoughBorder extends OutlinedBorder {
  const RoughBorder({super.side = BorderSide.none, this.radius = 12, this.seed = 7, this.roughness = 1});

  final double radius;
  final int seed;
  final double roughness;

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(side.width);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Rough.rect(rect.deflate(side.width / 2), seed: seed, radius: radius, roughness: roughness);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) =>
      Rough.rect(rect, seed: seed, radius: radius, roughness: roughness);

  @override
  void paint(Canvas canvas, Rect rect, {TextDirection? textDirection}) {
    if (side.style == BorderStyle.none || side.width == 0) return;
    final r = rect.deflate(side.width / 2);
    canvas.drawPath(
      Rough.rect(r, seed: seed, radius: radius, roughness: roughness, closed: false),
      _pen(side.color, side.width),
    );
    canvas.drawPath(
      Rough.rect(r, seed: seed, radius: radius, roughness: roughness * 1.3, pass: 1, closed: false),
      _pen(side.color.withValues(alpha: side.color.a * 0.45), side.width * 0.7),
    );
  }

  @override
  ShapeBorder scale(double t) => RoughBorder(side: side.scale(t), radius: radius * t, seed: seed, roughness: roughness);

  @override
  RoughBorder copyWith({BorderSide? side, double? radius, int? seed}) => RoughBorder(
    side: side ?? this.side,
    radius: radius ?? this.radius,
    seed: seed ?? this.seed,
    roughness: roughness,
  );

  @override
  bool operator ==(Object other) =>
      other is RoughBorder &&
      other.side == side &&
      other.radius == radius &&
      other.seed == seed &&
      other.roughness == roughness;

  @override
  int get hashCode => Object.hash(side, radius, seed, roughness);
}

/// Hand-drawn text field outline. Paints the label gap with [gapColor].
class RoughInputBorder extends InputBorder {
  const RoughInputBorder({
    super.borderSide = const BorderSide(),
    this.radius = 12,
    this.seed = 3,
    this.gapColor = Colors.transparent,
  });

  final double radius;
  final int seed;
  final Color gapColor;

  @override
  bool get isOutline => true;

  @override
  InputBorder copyWith({BorderSide? borderSide}) =>
      RoughInputBorder(borderSide: borderSide ?? this.borderSide, radius: radius, seed: seed, gapColor: gapColor);

  @override
  EdgeInsetsGeometry get dimensions => EdgeInsets.all(borderSide.width);

  @override
  Path getInnerPath(Rect rect, {TextDirection? textDirection}) =>
      Rough.rect(rect.deflate(borderSide.width), seed: seed, radius: radius);

  @override
  Path getOuterPath(Rect rect, {TextDirection? textDirection}) => Rough.rect(rect, seed: seed, radius: radius);

  @override
  void paint(
    Canvas canvas,
    Rect rect, {
    double? gapStart,
    double gapExtent = 0.0,
    double gapPercentage = 0.0,
    TextDirection? textDirection,
  }) {
    if (borderSide.style == BorderStyle.none) return;
    final r = rect.deflate(borderSide.width / 2);
    canvas.drawPath(Rough.rect(r, seed: seed, radius: radius, closed: false), _pen(borderSide.color, borderSide.width));
    if (gapStart != null && gapExtent > 0 && gapPercentage > 0) {
      final w = gapExtent * gapPercentage;
      canvas.drawRect(Rect.fromLTWH(rect.left + gapStart - 2, rect.top - 4, w + 4, 8), Paint()..color = gapColor);
    }
  }

  @override
  ShapeBorder scale(double t) =>
      RoughInputBorder(borderSide: borderSide.scale(t), radius: radius * t, seed: seed, gapColor: gapColor);
}
