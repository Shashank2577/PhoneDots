import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../theme/rough.dart';
import '../theme/theme.dart';

/// Stable seed from any value, so a shape keeps its wobble across rebuilds.
int seedOf(Object? o) => (o?.hashCode ?? 0) & 0x7fff;

/// A hand-drawn box: paper fill, pen outline, optional offset "sticker"
/// shadow and optional hatching.
class SketchBox extends StatelessWidget {
  const SketchBox({
    super.key,
    required this.child,
    this.seed = 1,
    this.fill,
    this.stroke,
    this.strokeWidth = 1.6,
    this.radius = 14,
    this.shadow = 0,
    this.hatch,
    this.padding = EdgeInsets.zero,
  });

  final Widget child;
  final int seed;
  final Color? fill;
  final Color? stroke;
  final double strokeWidth;
  final double radius;

  /// Offset of the solid ink shadow behind the box (0 = none).
  final double shadow;
  final Color? hatch;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return CustomPaint(
      painter: _BoxPainter(
        seed: seed,
        fill: fill ?? p.surface,
        stroke: stroke ?? p.stroke,
        width: strokeWidth,
        radius: radius,
        shadow: shadow,
        shadowColor: p.stroke,
        hatch: hatch,
      ),
      child: Padding(padding: padding, child: child),
    );
  }
}

class _BoxPainter extends CustomPainter {
  _BoxPainter({
    required this.seed,
    required this.fill,
    required this.stroke,
    required this.width,
    required this.radius,
    required this.shadow,
    required this.shadowColor,
    this.hatch,
  });

  final int seed;
  final Color fill;
  final Color stroke;
  final double width;
  final double radius;
  final double shadow;
  final Color shadowColor;
  final Color? hatch;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(width);
    if (shadow > 0) {
      canvas.drawPath(
        Rough.rect(rect.shift(Offset(shadow, shadow)), seed: seed + 3, radius: radius),
        Paint()..color = shadowColor,
      );
    }
    final body = Rough.rect(rect, seed: seed, radius: radius);
    canvas.drawPath(body, Paint()..color = fill);
    if (hatch != null) {
      Rough.hachure(
        canvas,
        body,
        rect,
        Paint()
          ..color = hatch!
          ..strokeWidth = 1.4
          ..style = PaintingStyle.stroke
          ..strokeCap = StrokeCap.round,
        seed: seed,
      );
    }
    final pen = Paint()
      ..color = stroke
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round;
    canvas.drawPath(Rough.rect(rect, seed: seed, radius: radius, closed: false), pen);
    canvas.drawPath(
      Rough.rect(rect, seed: seed, radius: radius, roughness: 1.3, pass: 1, closed: false),
      pen
        ..color = stroke.withValues(alpha: stroke.a * 0.4)
        ..strokeWidth = width * 0.7,
    );
  }

  @override
  bool shouldRepaint(_BoxPainter o) =>
      o.seed != seed ||
      o.fill != fill ||
      o.stroke != stroke ||
      o.shadow != shadow ||
      o.hatch != hatch ||
      o.radius != radius;
}

/// Squishes on press, springs back on release, with a tiny tilt and a
/// light haptic tick. Wrap anything tappable in it.
class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.child,
    this.onTap,
    this.onLongPress,
    this.scale = 0.94,
    this.tilt = 0.02,
    this.haptic = true,
  });

  final Widget child;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final double scale;
  final double tilt;
  final bool haptic;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 110),
    reverseDuration: const Duration(milliseconds: 420),
  );
  late final _anim = CurvedAnimation(parent: _c, curve: Curves.easeOut, reverseCurve: Curves.elasticIn);

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  void _down(_) {
    if (widget.onTap == null && widget.onLongPress == null) return;
    _c.forward();
  }

  void _up([_]) => _c.reverse();

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null || widget.onLongPress != null;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: _down,
      onTapUp: _up,
      onTapCancel: _up,
      onTap: !enabled
          ? null
          : () {
              if (widget.haptic) HapticFeedback.lightImpact();
              widget.onTap?.call();
            },
      onLongPress: widget.onLongPress == null
          ? null
          : () {
              HapticFeedback.mediumImpact();
              widget.onLongPress!();
            },
      child: AnimatedBuilder(
        animation: _anim,
        child: widget.child,
        builder: (_, child) => Transform.rotate(
          angle: -widget.tilt * _anim.value,
          child: Transform.scale(scale: 1 - (1 - widget.scale) * _anim.value, child: child),
        ),
      ),
    );
  }
}

/// Plays once when the widget first appears: rises, fades in and settles
/// from a slight tilt. In lists this animates items as they scroll in.
class Enter extends StatefulWidget {
  const Enter({
    super.key,
    required this.child,
    this.index = 0,
    this.from = const Offset(0, 18),
    this.tilt = 0.03,
    this.duration = const Duration(milliseconds: 420),
  });

  final Widget child;

  /// Stagger position; each step delays by 45 ms (capped).
  final int index;
  final Offset from;
  final double tilt;
  final Duration duration;

  @override
  State<Enter> createState() => _EnterState();
}

class _EnterState extends State<Enter> with SingleTickerProviderStateMixin {
  // The stagger delay lives inside the animation (an Interval), so disposing
  // the controller cancels everything; no stray timers.
  late final int _delayMs = 45 * min(widget.index, 8);
  late final _c = AnimationController(
    vsync: this,
    duration: widget.duration + Duration(milliseconds: _delayMs),
  )..forward();
  late final double _start = _delayMs / _c.duration!.inMilliseconds;
  late final _fade = CurvedAnimation(
    parent: _c,
    curve: Interval(_start, 1, curve: Curves.easeOut),
  );
  late final _a = CurvedAnimation(
    parent: _c,
    curve: Interval(_start, 1, curve: Curves.easeOutBack),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: widget.child,
    builder: (_, child) {
      final t = _a.value;
      return Opacity(
        opacity: _fade.value.clamp(0, 1),
        child: Transform.translate(
          offset: widget.from * (1 - t),
          child: Transform.rotate(angle: widget.tilt * (1 - t), child: child),
        ),
      );
    },
  );
}

/// A pen stroke that draws itself in.
class DrawnPath extends StatefulWidget {
  const DrawnPath({
    super.key,
    required this.builder,
    required this.size,
    this.color,
    this.width = 2.2,
    this.duration = const Duration(milliseconds: 380),
    this.delay = Duration.zero,
  });

  final Path Function(Size size) builder;
  final Size size;
  final Color? color;
  final double width;
  final Duration duration;
  final Duration delay;

  @override
  State<DrawnPath> createState() => _DrawnPathState();
}

class _DrawnPathState extends State<DrawnPath> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: widget.duration + widget.delay)..forward();
  late final _t = CurvedAnimation(
    parent: _c,
    curve: Interval(widget.delay.inMilliseconds / _c.duration!.inMilliseconds, 1, curve: Curves.easeOutCubic),
  );

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.pal.ink;
    return SizedBox.fromSize(
      size: widget.size,
      child: AnimatedBuilder(
        animation: _t,
        builder: (_, _) => CustomPaint(painter: _StrokePainter(widget.builder, _t.value, color, widget.width)),
      ),
    );
  }
}

class _StrokePainter extends CustomPainter {
  _StrokePainter(this.builder, this.t, this.color, this.width);
  final Path Function(Size) builder;
  final double t;
  final Color color;
  final double width;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    Rough.partial(builder(size), t),
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round,
  );

  @override
  bool shouldRepaint(_StrokePainter o) => o.t != t || o.color != color;
}

/// Animated hand-drawn check mark.
class DrawnCheck extends StatelessWidget {
  const DrawnCheck({super.key, this.size = 18, this.color});
  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => DrawnPath(
    size: Size.square(size),
    color: color ?? context.pal.dot,
    width: 2.6,
    builder: (s) => Rough.check(Offset.zero & s),
  );
}

/// A scribbled underline that draws itself under a heading.
class Underline extends StatelessWidget {
  const Underline({
    super.key,
    this.width = 120,
    this.seed = 1,
    this.color,
    this.delay = const Duration(milliseconds: 150),
  });
  final double width;
  final int seed;
  final Color? color;
  final Duration delay;

  @override
  Widget build(BuildContext context) => DrawnPath(
    size: Size(width, 10),
    delay: delay,
    duration: const Duration(milliseconds: 520),
    color: color ?? context.pal.highlight,
    width: 5,
    builder: (s) {
      final p = Rough.line(Offset(2, s.height * 0.55), Offset(s.width, s.height * 0.4), seed: seed, roughness: 1.4);
      return p..addPath(
        Rough.line(Offset(s.width * 0.08, s.height * 0.85), Offset(s.width * 0.9, s.height * 0.7), seed: seed + 9),
        Offset.zero,
      );
    },
  );
}

/// Heading in the script font with a highlighter underline.
class DoodleTitle extends StatelessWidget {
  const DoodleTitle(this.text, {super.key, this.size = 40, this.seed});
  final String text;
  final double size;
  final int? seed;

  @override
  Widget build(BuildContext context) => Column(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(text, style: context.text.headlineMedium?.copyWith(fontSize: size)),
      Transform.translate(
        offset: const Offset(0, -6),
        child: Underline(width: max(60, text.length * size * 0.38), seed: seed ?? seedOf(text)),
      ),
    ],
  );
}

/// Scroll-aware page header: a big script title that shrinks and tucks
/// under a pen line as content scrolls beneath it.
class DoodleHeader extends StatelessWidget {
  const DoodleHeader({super.key, required this.title, this.actions = const [], this.bottom});
  final String title;
  final List<Widget> actions;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) => SliverPersistentHeader(
    pinned: true,
    delegate: _HeaderDelegate(title, actions, bottom, MediaQuery.paddingOf(context).top, context.pal, context.text),
  );
}

class _HeaderDelegate extends SliverPersistentHeaderDelegate {
  _HeaderDelegate(this.title, this.actions, this.bottom, this.top, this.p, this.t);
  final String title;
  final List<Widget> actions;
  final Widget? bottom;
  final double top;
  final Palette p;
  final TextTheme t;

  double get _bottomH => bottom == null ? 0 : 58;

  @override
  double get maxExtent => top + 112 + _bottomH;

  @override
  double get minExtent => top + 60 + _bottomH;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) {
    final f = (shrinkOffset / (maxExtent - minExtent)).clamp(0.0, 1.0);
    final size = 44 - 14 * f;
    return Container(
      color: p.bg,
      padding: EdgeInsets.only(top: top),
      child: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                Positioned(
                  left: 20,
                  bottom: 6 + 4 * (1 - f),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(title, style: t.headlineMedium?.copyWith(fontSize: size)),
                      Opacity(
                        opacity: 1 - f,
                        child: Transform.translate(
                          offset: const Offset(0, -6),
                          child: Underline(width: title.length * size * 0.36, seed: seedOf(title)),
                        ),
                      ),
                    ],
                  ),
                ),
                Positioned(right: 8, bottom: 4, child: Row(children: actions)),
              ],
            ),
          ),
          ?bottom,
          CustomPaint(
            size: const Size(double.infinity, 3),
            painter: _RulePainter(p.stroke.withValues(alpha: f * 0.7)),
          ),
        ],
      ),
    );
  }

  @override
  bool shouldRebuild(_HeaderDelegate o) => o.title != title || o.p != p || o.actions != actions || o.bottom != bottom;
}

class _RulePainter extends CustomPainter {
  _RulePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size size) => canvas.drawPath(
    Rough.line(Offset(8, 1.5), Offset(size.width - 8, 1.5), seed: 5),
    Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.4,
  );

  @override
  bool shouldRepaint(_RulePainter o) => o.color != color;
}

/// Dotted notebook paper behind every screen.
class PaperBackground extends StatelessWidget {
  const PaperBackground({super.key, required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) => CustomPaint(painter: _GridPainter(context.pal), child: child);
}

class _GridPainter extends CustomPainter {
  _GridPainter(this.p);
  final Palette p;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = p.bg);
    final dot = Paint()..color = p.grid;
    for (var y = 12.0; y < size.height; y += 22) {
      for (var x = 12.0; x < size.width; x += 22) {
        canvas.drawCircle(Offset(x, y), 1.1, dot);
      }
    }
  }

  @override
  bool shouldRepaint(_GridPainter o) => o.p != p;
}

/// Three dots that hop in turn: the brand's "thinking" indicator.
class HoppingDots extends StatefulWidget {
  const HoppingDots({super.key, this.size = 8});
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
    final colors = [p.ink, p.dot, p.warn];
    return AnimatedBuilder(
      animation: _c,
      builder: (_, _) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 8),
              child: Transform.translate(
                offset: Offset(0, -6 * max(0, sin((_c.value - i * 0.18) * 2 * pi))),
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

/// A pencil circle that keeps scribbling while something runs.
class Scribbling extends StatefulWidget {
  const Scribbling({super.key, this.size = 16, this.color});
  final double size;
  final Color? color;

  @override
  State<Scribbling> createState() => _ScribblingState();
}

class _ScribblingState extends State<Scribbling> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 900))..repeat();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = widget.color ?? context.pal.warn;
    return SizedBox.square(
      dimension: widget.size,
      child: AnimatedBuilder(
        animation: _c,
        builder: (_, _) => Transform.rotate(
          angle: _c.value * 2 * pi,
          child: CustomPaint(
            painter: _StrokePainter((s) => Rough.scribbleCircle(Offset.zero & s, seed: 3, turns: 0.75), 1, color, 2),
          ),
        ),
      ),
    );
  }
}

/// Wavy hand-drawn progress bar filled with pen hatching.
class SketchProgress extends StatelessWidget {
  const SketchProgress({super.key, required this.value, this.height = 16});
  final double? value;
  final double height;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return SizedBox(
      height: height,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: value ?? 0),
        duration: const Duration(milliseconds: 300),
        builder: (_, v, _) => CustomPaint(size: Size.infinite, painter: _ProgressPainter(value == null ? null : v, p)),
      ),
    );
  }
}

class _ProgressPainter extends CustomPainter {
  _ProgressPainter(this.v, this.p);
  final double? v;
  final Palette p;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(1.5);
    final fillW = rect.width * (v ?? 0.3);
    final fill = Rough.rect(
      Rect.fromLTWH(rect.left, rect.top, max(rect.height, fillW), rect.height),
      seed: 13,
      radius: size.height / 2,
    );
    canvas.drawPath(fill, Paint()..color = p.highlight);
    Rough.hachure(
      canvas,
      fill,
      rect,
      Paint()
        ..color = p.ink.withValues(alpha: 0.55)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
      gap: 5,
      seed: 13,
    );
    canvas.drawPath(
      Rough.rect(rect, seed: 12, radius: size.height / 2, closed: false),
      Paint()
        ..color = p.stroke
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
  }

  @override
  bool shouldRepaint(_ProgressPainter o) => o.v != v || o.p != p;
}

/// Springy hand-drawn toggle.
class SketchSwitch extends StatelessWidget {
  const SketchSwitch({super.key, required this.value, required this.onChanged});
  final bool value;
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Pressable(
      onTap: onChanged == null ? null : () => onChanged!(!value),
      scale: 0.9,
      child: SizedBox(
        width: 52,
        height: 30,
        child: Stack(
          children: [
            Positioned.fill(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: SketchBox(
                  key: ValueKey(value),
                  seed: 44,
                  radius: 15,
                  fill: value ? p.dot.withValues(alpha: 0.85) : p.surface,
                  child: const SizedBox.expand(),
                ),
              ),
            ),
            AnimatedAlign(
              duration: const Duration(milliseconds: 380),
              curve: Curves.elasticOut,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.all(5),
                child: SketchBox(
                  seed: 46,
                  radius: 10,
                  fill: p.surface,
                  strokeWidth: 1.4,
                  child: const SizedBox.square(dimension: 18),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A list row with a sketch toggle, replacing SwitchListTile.
class SketchSwitchTile extends StatelessWidget {
  const SketchSwitchTile({super.key, required this.title, this.subtitle, required this.value, required this.onChanged});
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => ListTile(
    title: Text(title),
    subtitle: subtitle == null ? null : Text(subtitle!),
    trailing: SketchSwitch(value: value, onChanged: onChanged),
    onTap: () => onChanged(!value),
  );
}

/// Bottom navigation where the active tab is circled in pen and its icon hops.
class SketchNavBar extends StatelessWidget {
  const SketchNavBar({super.key, required this.index, required this.onTap, required this.items});
  final int index;
  final ValueChanged<int> onTap;
  final List<(IconData, IconData, String)> items;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Container(
      color: p.bg,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(size: const Size(double.infinity, 3), painter: _RulePainter(p.stroke.withValues(alpha: 0.6))),
            SizedBox(
              height: 66,
              child: Row(
                children: [
                  for (var i = 0; i < items.length; i++)
                    Expanded(
                      child: Pressable(
                        onTap: () => onTap(i),
                        scale: 0.88,
                        child: _NavItem(item: items[i], selected: i == index, seed: i),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.item, required this.selected, required this.seed});
  final (IconData, IconData, String) item;
  final bool selected;
  final int seed;

  @override
  Widget build(BuildContext context) {
    final p = context.pal;
    return Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        SizedBox(
          width: 56,
          height: 34,
          child: Stack(
            alignment: Alignment.center,
            children: [
              if (selected)
                DrawnPath(
                  key: ValueKey('circle$seed'),
                  size: const Size(56, 34),
                  color: p.highlight,
                  width: 9,
                  duration: const Duration(milliseconds: 420),
                  builder: (s) => Rough.scribbleCircle((Offset.zero & s).deflate(7), seed: seed + 2, turns: 1.05),
                ),
              AnimatedScale(
                scale: selected ? 1.15 : 1,
                duration: const Duration(milliseconds: 420),
                curve: Curves.elasticOut,
                child: Icon(selected ? item.$2 : item.$1, size: 24, color: selected ? p.ink : p.muted),
              ),
            ],
          ),
        ),
        Text(item.$3, style: TextStyle(fontSize: 14, color: selected ? p.ink : p.muted)),
      ],
    );
  }
}

/// Small wiggle on demand, e.g. to nudge an empty field.
class Wiggle extends StatefulWidget {
  const Wiggle({super.key, required this.child, this.trigger = 0});
  final Widget child;

  /// Change this value to replay the wiggle.
  final int trigger;

  @override
  State<Wiggle> createState() => _WiggleState();
}

class _WiggleState extends State<Wiggle> with SingleTickerProviderStateMixin {
  late final _c = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));

  @override
  void didUpdateWidget(Wiggle old) {
    super.didUpdateWidget(old);
    if (old.trigger != widget.trigger) _c.forward(from: 0);
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: _c,
    child: widget.child,
    builder: (_, child) => Transform.rotate(angle: sin(_c.value * pi * 6) * 0.05 * (1 - _c.value), child: child),
  );
}

/// A tab page: collapsing doodle header over bouncy scrolling content.
class DoodlePage extends StatelessWidget {
  const DoodlePage({super.key, required this.title, required this.body, this.actions = const [], this.bottom});
  final String title;
  final Widget body;
  final List<Widget> actions;
  final Widget? bottom;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: NestedScrollView(
      physics: const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics()),
      headerSliverBuilder: (_, _) => [DoodleHeader(title: title, actions: actions, bottom: bottom)],
      body: Builder(
        builder: (context) => ScrollConfiguration(behavior: const _Bouncy(), child: body),
      ),
    ),
  );
}

class _Bouncy extends ScrollBehavior {
  const _Bouncy();

  @override
  ScrollPhysics getScrollPhysics(BuildContext context) =>
      const BouncingScrollPhysics(parent: AlwaysScrollableScrollPhysics());

  @override
  Widget buildOverscrollIndicator(BuildContext context, Widget child, ScrollableDetails details) => child;
}
