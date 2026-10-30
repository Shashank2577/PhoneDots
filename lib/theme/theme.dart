import 'package:flutter/material.dart';

/// Design tokens. Monochrome with hairlines; the only colour is the green
/// "on device" dot and red for destructive actions.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.bg,
    required this.surface,
    required this.surfaceAlt,
    required this.ink,
    required this.muted,
    required this.faint,
    required this.hairline,
    required this.dot,
    required this.danger,
    required this.warn,
  });

  final Color bg;
  final Color surface;
  final Color surfaceAlt;
  final Color ink;
  final Color muted;
  final Color faint;
  final Color hairline;
  final Color dot;
  final Color danger;
  final Color warn;

  static const light = Palette(
    bg: Color(0xFFFAFAF9),
    surface: Color(0xFFFFFFFF),
    surfaceAlt: Color(0xFFF2F2F0),
    ink: Color(0xFF0C0C0D),
    muted: Color(0xFF6B6B70),
    faint: Color(0xFFA1A1A6),
    hairline: Color(0xFFE6E6E3),
    dot: Color(0xFF16A34A),
    danger: Color(0xFFDC2626),
    warn: Color(0xFFD97706),
  );

  static const dark = Palette(
    bg: Color(0xFF0B0B0C),
    surface: Color(0xFF141416),
    surfaceAlt: Color(0xFF1D1D20),
    ink: Color(0xFFF4F4F5),
    muted: Color(0xFF9B9BA1),
    faint: Color(0xFF5F5F66),
    hairline: Color(0xFF27272B),
    dot: Color(0xFF22C55E),
    danger: Color(0xFFF87171),
    warn: Color(0xFFFBBF24),
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
    outline: p.hairline,
    outlineVariant: p.hairline,
    onSurfaceVariant: p.muted,
  );
  final base = ThemeData(useMaterial3: true, colorScheme: scheme, brightness: brightness);
  final t = base.textTheme;
  final text = t.copyWith(
    displaySmall: t.displaySmall?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -1, color: p.ink),
    headlineMedium: t.headlineMedium?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.6, color: p.ink, fontSize: 26),
    titleLarge: t.titleLarge?.copyWith(fontWeight: FontWeight.w600, letterSpacing: -0.3, fontSize: 19, color: p.ink),
    titleMedium: t.titleMedium?.copyWith(fontWeight: FontWeight.w600, fontSize: 15.5, color: p.ink),
    bodyLarge: t.bodyLarge?.copyWith(fontSize: 15.5, height: 1.5, color: p.ink),
    bodyMedium: t.bodyMedium?.copyWith(fontSize: 14, height: 1.45, color: p.ink),
    bodySmall: t.bodySmall?.copyWith(fontSize: 12.5, color: p.muted),
    labelLarge: t.labelLarge?.copyWith(fontWeight: FontWeight.w600, fontSize: 14),
    labelMedium: t.labelMedium?.copyWith(fontSize: 12.5, color: p.muted),
    labelSmall: t.labelSmall?.copyWith(fontSize: 11, letterSpacing: 0.6, color: p.muted, fontWeight: FontWeight.w600),
  );
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius));
  final pill = RoundedRectangleBorder(borderRadius: BorderRadius.circular(999));
  return base.copyWith(
    extensions: [p],
    scaffoldBackgroundColor: p.bg,
    textTheme: text,
    splashFactory: InkSparkle.splashFactory,
    dividerTheme: DividerThemeData(color: p.hairline, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: text.titleLarge,
      iconTheme: IconThemeData(color: p.ink, size: 22),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      indicatorColor: p.surfaceAlt,
      height: 64,
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (s) => TextStyle(
          fontSize: 11.5,
          fontWeight: s.contains(WidgetState.selected) ? FontWeight.w600 : FontWeight.w500,
          color: s.contains(WidgetState.selected) ? p.ink : p.muted,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (s) => IconThemeData(size: 22, color: s.contains(WidgetState.selected) ? p.ink : p.muted),
      ),
    ),
    cardTheme: CardThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(radius), side: BorderSide(color: p.hairline)),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.ink,
        foregroundColor: p.bg,
        shape: pill,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        textStyle: text.labelLarge,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        side: BorderSide(color: p.hairline),
        shape: pill,
        minimumSize: const Size(0, 40),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        textStyle: text.labelLarge,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(foregroundColor: p.ink, shape: pill, textStyle: text.labelLarge),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: p.ink)),
    chipTheme: ChipThemeData(
      backgroundColor: p.surface,
      side: BorderSide(color: p.hairline),
      shape: pill,
      labelStyle: text.labelMedium?.copyWith(color: p.ink),
      padding: const EdgeInsets.symmetric(horizontal: 4),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.surface,
      hintStyle: TextStyle(color: p.faint),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: p.hairline)),
      enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: p.hairline)),
      focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(radius), borderSide: BorderSide(color: p.ink)),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: 20),
      iconColor: p.ink,
      titleTextStyle: text.bodyLarge?.copyWith(fontWeight: FontWeight.w500),
      subtitleTextStyle: text.bodySmall,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.bg : p.faint),
      trackColor: WidgetStateProperty.resolveWith((s) => s.contains(WidgetState.selected) ? p.ink : p.surfaceAlt),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.ink,
      inactiveTrackColor: p.hairline,
      thumbColor: p.ink,
      overlayColor: p.ink.withValues(alpha: 0.08),
      trackHeight: 2,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(color: p.ink, linearTrackColor: p.hairline),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: p.hairline,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(22))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.bg,
      surfaceTintColor: Colors.transparent,
      shape: shape,
      titleTextStyle: text.titleLarge,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.ink,
      contentTextStyle: TextStyle(color: p.bg),
      shape: shape,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: p.surface,
        selectedBackgroundColor: p.ink,
        selectedForegroundColor: p.bg,
        foregroundColor: p.ink,
        side: BorderSide(color: p.hairline),
        visualDensity: VisualDensity.compact,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.surface,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12), side: BorderSide(color: p.hairline)),
      elevation: 2,
    ),
  );
}
