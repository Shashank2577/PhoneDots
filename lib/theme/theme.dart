import 'package:flutter/material.dart';

import 'rough.dart';

/// Design tokens: ink on paper (light) and chalk on a board (dark), with
/// sticky-note pastels and a highlighter for emphasis.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.ink,
    required this.stroke,
    required this.muted,
    required this.faint,
    required this.hairline,
    required this.grid,
    required this.dot,
    required this.danger,
    required this.warn,
    required this.highlight,
    required this.notes,
  });

  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color ink;

  /// Pen colour for hand-drawn outlines.
  final Color stroke;
  final Color muted;
  final Color faint;

  /// Light pencil for dividers and tracks.
  final Color hairline;

  /// The dot grid printed on the paper.
  final Color grid;
  final Color dot;
  final Color danger;
  final Color warn;
  final Color highlight;

  /// Sticky-note fills: yellow, pink, mint, blue, lavender.
  final List<Color> notes;

  Color note(int i) => notes[i % notes.length];

  static const light = Palette(
    bg: Color(0xFFFBF7EE),
    surface: Color(0xFFFFFDF8),
    surfaceAlt: Color(0xFFF3EDE0),
    ink: Color(0xFF221E19),
    stroke: Color(0xFF2B2620),
    muted: Color(0xFF6F675C),
    faint: Color(0xFFA49B8E),
    hairline: Color(0xFFDDD5C6),
    grid: Color(0xFFE4DCCB),
    dot: Color(0xFF1F9D57),
    danger: Color(0xFFE0453A),
    warn: Color(0xFFDB8A1A),
    highlight: Color(0xFFFFE27A),
    notes: [Color(0xFFFFF1A8), Color(0xFFFFD8E2), Color(0xFFCDF3DE), Color(0xFFD5E7FF), Color(0xFFE7DCFF)],
  );

  static const dark = Palette(
    bg: Color(0xFF1D2320),
    surface: Color(0xFF242B27),
    surfaceAlt: Color(0xFF2D3530),
    ink: Color(0xFFF1EEE4),
    stroke: Color(0xFFE6E2D6),
    muted: Color(0xFFA9B0A6),
    faint: Color(0xFF6E776F),
    hairline: Color(0xFF3A433D),
    grid: Color(0xFF2A322D),
    dot: Color(0xFF4ADE80),
    danger: Color(0xFFFF7A70),
    warn: Color(0xFFF6C35B),
    highlight: Color(0xFF8A7A2A),
    notes: [Color(0xFF4A4526), Color(0xFF4A2F38), Color(0xFF26443A), Color(0xFF2A3A52), Color(0xFF3A3352)],
  );

  @override
  Palette copyWith() => this;

  @override
  Palette lerp(Palette? other, double t) => t < 0.5 || other == null ? this : other;
}

extension PaletteX on BuildContext {
  Palette get pal => Theme.of(this).extension<Palette>()!;
  TextTheme get text => Theme.of(this).textTheme;
}

const radius = 14.0;
const handFont = 'PatrickHand';
const scriptFont = 'Caveat';

/// Paper slides in with a slight tilt, like turning to a new page.
class PaperPageTransitions extends PageTransitionsBuilder {
  const PaperPageTransitions();

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    final curved = CurvedAnimation(parent: animation, curve: Curves.easeOutBack, reverseCurve: Curves.easeInCubic);
    return AnimatedBuilder(
      animation: curved,
      child: child,
      builder: (_, child) {
        final t = curved.value;
        return Opacity(
          opacity: animation.value.clamp(0, 1),
          child: Transform(
            alignment: Alignment.bottomLeft,
            transform: Matrix4.identity()
              ..translateByDouble((1 - t) * 60, (1 - t) * 18, 0, 1)
              ..rotateZ((1 - t) * 0.06),
            child: child,
          ),
        );
      },
    );
  }
}

ThemeData buildTheme(Brightness brightness) {
  final p = brightness == Brightness.light ? Palette.light : Palette.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.ink,
    onPrimary: p.bg,
    secondary: p.muted,
    onSecondary: p.bg,
    error: p.danger,
    onError: Colors.white,
    surface: p.surface,
    onSurface: p.ink,
    surfaceContainerLowest: p.bg,
    surfaceContainerLow: p.surface,
    surfaceContainer: p.surface,
    surfaceContainerHigh: p.surfaceAlt,
    surfaceContainerHighest: p.surfaceAlt,
    outline: p.stroke,
    outlineVariant: p.hairline,
    onSurfaceVariant: p.muted,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness, fontFamily: handFont);
  final t = base.textTheme;
  TextStyle script(TextStyle? s, double size) => (s ?? const TextStyle()).copyWith(
    fontFamily: scriptFont,
    fontWeight: FontWeight.w700,
    fontSize: size,
    height: 1.0,
    color: p.ink,
  );
  final text = t.copyWith(
    displaySmall: script(t.displaySmall, 46),
    headlineMedium: script(t.headlineMedium, 36),
    titleLarge: script(t.titleLarge, 30),
    titleMedium: t.titleMedium?.copyWith(fontSize: 18, height: 1.2, color: p.ink),
    bodyLarge: t.bodyLarge?.copyWith(fontSize: 18, height: 1.4, color: p.ink),
    bodyMedium: t.bodyMedium?.copyWith(fontSize: 16.5, height: 1.35, color: p.ink),
    bodySmall: t.bodySmall?.copyWith(fontSize: 14.5, height: 1.3, color: p.muted),
    labelLarge: t.labelLarge?.copyWith(fontSize: 17, color: p.ink),
    labelMedium: t.labelMedium?.copyWith(fontSize: 14.5, color: p.muted),
    labelSmall: t.labelSmall?.copyWith(fontSize: 13.5, letterSpacing: 1.2, color: p.muted),
  );
  final pen = BorderSide(color: p.stroke, width: 1.6);
  RoughBorder rough([int seed = 7, double r = radius]) => RoughBorder(side: pen, seed: seed, radius: r);
  return base.copyWith(
    extensions: [p],
    scaffoldBackgroundColor: Colors.transparent,
    textTheme: text,
    pageTransitionsTheme: const PageTransitionsTheme(
      builders: {
        TargetPlatform.android: PaperPageTransitions(),
        TargetPlatform.iOS: PaperPageTransitions(),
        TargetPlatform.linux: PaperPageTransitions(),
        TargetPlatform.macOS: PaperPageTransitions(),
        TargetPlatform.windows: PaperPageTransitions(),
      },
    ),
    dividerTheme: DividerThemeData(color: p.hairline, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
      iconTheme: IconThemeData(color: p.ink, size: 24),
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: rough(11),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.ink,
        foregroundColor: p.bg,
        shape: rough(5, 22),
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 22),
        textStyle: text.labelLarge?.copyWith(fontSize: 18),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        side: pen,
        shape: rough(9, 22),
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.ink,
        textStyle: text.labelLarge,
        shape: rough(13, 22).copyWith(side: BorderSide.none),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: p.ink)),
    chipTheme: ChipThemeData(
      backgroundColor: p.surface,
      side: BorderSide(color: p.stroke, width: 1.2),
      shape: rough(17, 20),
      labelStyle: text.labelMedium?.copyWith(color: p.ink),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      hintStyle: TextStyle(color: p.faint, fontFamily: handFont),
      labelStyle: TextStyle(color: p.muted, fontFamily: handFont),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: RoughInputBorder(borderSide: pen, gapColor: p.bg),
      enabledBorder: RoughInputBorder(borderSide: pen, gapColor: p.bg),
      focusedBorder: RoughInputBorder(
        borderSide: BorderSide(color: p.ink, width: 2.4),
        seed: 4,
        gapColor: p.bg,
      ),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      iconColor: p.ink,
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodySmall,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.ink,
      inactiveTrackColor: p.hairline,
      thumbColor: p.ink,
      overlayColor: p.ink.withValues(alpha: 0.08),
      trackHeight: 3,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.ink, linearTrackColor: p.hairline),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: p.faint,
      shape: rough(21, 26),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      shape: rough(23, 20),
      titleTextStyle: text.titleLarge,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.ink,
      contentTextStyle: TextStyle(color: p.bg, fontFamily: handFont, fontSize: 17),
      shape: rough(29, 16).copyWith(side: BorderSide.none),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: p.surface,
        selectedBackgroundColor: p.highlight,
        selectedForegroundColor: p.ink,
        foregroundColor: p.ink,
        side: pen,
        shape: rough(31, 18),
        textStyle: text.labelLarge,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: rough(37, 12),
      elevation: 0,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: ShapeDecoration(
        color: p.ink,
        shape: rough(41, 10).copyWith(side: BorderSide.none),
      ),
      textStyle: TextStyle(color: p.bg, fontFamily: handFont, fontSize: 15),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.ink,
      unselectedLabelColor: p.muted,
      dividerColor: p.hairline,
      indicatorColor: p.ink,
      labelStyle: text.labelLarge,
      unselectedLabelStyle: text.labelLarge,
    ),
    expansionTileTheme: ExpansionTileThemeData(
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: p.muted,
      collapsedIconColor: p.muted,
    ),
  );
}
