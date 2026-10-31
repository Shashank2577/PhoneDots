import 'package:flutter/material.dart';

/// Burrow · Hand-drawn Minimal (from Shashank2577/Android-Showcase,
/// design/burrow-a/theme/tokens.json): white paper, ink, one marker-yellow
/// accent, Caveat hand-lettering over a quiet body voice.
@immutable
class Palette extends ThemeExtension<Palette> {
  const Palette({
    required this.paper,
    required this.ink,
    required this.pencil,
    required this.graphite,
    required this.rule,
    required this.smudge,
    required this.marker,
    required this.markerInk,
    required this.redPen,
  });

  final Color paper;
  final Color ink;

  /// Meta lines and secondary text.
  final Color pencil;

  /// Placeholders, disabled items.
  final Color graphite;

  /// Sketchy hairline dividers.
  final Color rule;

  /// The only fill: input wells, the selected row.
  final Color smudge;

  /// The single highlight per screen.
  final Color marker;
  final Color markerInk;

  /// Private and destructive states only.
  final Color redPen;

  // Role names used across the app, mapped onto Burrow's tokens.
  Color get bg => paper;
  Color get surface => paper;
  Color get surfaceAlt => smudge;
  Color get stroke => ink;
  Color get muted => pencil;
  Color get faint => graphite;
  Color get hairline => rule;
  Color get dot => ink;
  Color get danger => redPen;
  Color get warn => pencil;
  Color get highlight => marker;

  static const light = Palette(
    paper: Color(0xFFFFFFFF),
    ink: Color(0xFF1A1A1A),
    pencil: Color(0xFF6B6B6B),
    graphite: Color(0xFFA3A3A3),
    rule: Color(0x261A1A1A),
    smudge: Color(0xFFF4F3EF),
    marker: Color(0xFFFFE45C),
    markerInk: Color(0xFF1A1A1A),
    redPen: Color(0xFFDC2626),
  );

  /// A night notebook, not white-on-black: warm charcoal and chalky ink.
  static const dark = Palette(
    paper: Color(0xFF1E1D1B),
    ink: Color(0xFFE8E3D8),
    pencil: Color(0xFFB9B3A8),
    graphite: Color(0xFF948E84),
    rule: Color(0x4DE8E3D8),
    smudge: Color(0xFF2D2B28),
    marker: Color(0xFFD9BF45),
    markerInk: Color(0xFF1E1D1B),
    redPen: Color(0xFFFF8A80),
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
const caveat = 'Caveat';

/// Max content width, so pages stay centred on a Fold's inner screen.
const maxColumn = 560.0;
const gutter = 24.0;

/// How handwritten the quiet text under the Caveat headlines is.
enum Voice {
  formal('formal', 'Inter, a crisp sans', 'Inter', 1.0),
  friendly('friendly', 'Nunito, a rounded sans', 'Nunito', 1.02),
  neat('neat hand', 'Shantell Sans, marker-neat', 'ShantellSans', 0.98, informality: 0),
  loose('loose hand', 'Shantell Sans, informal', 'ShantellSans', 0.98, informality: 100),
  handwritten('all handwritten', 'Patrick Hand', 'PatrickHand', 1.14);

  const Voice(this.label, this.note, this.family, this.scale, {this.informality});

  final String label;
  final String note;
  final String family;
  final double scale;

  /// Shantell Sans' INFM axis; null for static fonts.
  final double? informality;

  List<FontVariation>? get variations => informality == null ? null : [FontVariation('INFM', informality!)];
}

/// Hand-lettered styles (Caveat) that have no Material role.
class Hand {
  static const display = TextStyle(fontFamily: caveat, fontWeight: FontWeight.w700, fontSize: 52, height: 54 / 52);
  static const headline = TextStyle(fontFamily: caveat, fontWeight: FontWeight.w700, fontSize: 40, height: 42 / 40);
  static const title = TextStyle(fontFamily: caveat, fontWeight: FontWeight.w700, fontSize: 30, height: 33 / 30);
  static const door = TextStyle(fontFamily: caveat, fontWeight: FontWeight.w600, fontSize: 28, height: 32 / 28);
  static const label = TextStyle(fontFamily: caveat, fontWeight: FontWeight.w600, fontSize: 21, height: 24 / 21);
  static const small = TextStyle(fontFamily: caveat, fontWeight: FontWeight.w600, fontSize: 18, height: 21 / 18);
}

ThemeData buildTheme(Brightness brightness, {Voice voice = Voice.neat}) {
  final p = brightness == Brightness.light ? Palette.light : Palette.dark;
  final scheme = ColorScheme(
    brightness: brightness,
    primary: p.ink,
    onPrimary: p.paper,
    secondary: p.pencil,
    onSecondary: p.paper,
    error: p.redPen,
    onError: p.paper,
    surface: p.paper,
    onSurface: p.ink,
    surfaceContainerLowest: p.paper,
    surfaceContainerLow: p.paper,
    surfaceContainer: p.paper,
    surfaceContainerHigh: p.smudge,
    surfaceContainerHighest: p.smudge,
    outline: p.ink,
    outlineVariant: p.rule,
    onSurfaceVariant: p.pencil,
  );
  TextStyle body(double size, double line, {FontWeight weight = FontWeight.w400, Color? color}) => TextStyle(
    fontFamily: voice.family,
    fontVariations: voice.variations,
    fontWeight: weight,
    fontSize: size * voice.scale,
    height: line / size,
    color: color ?? p.ink,
  );
  final text = TextTheme(
    displayLarge: Hand.display.copyWith(fontSize: 64, height: 1, color: p.ink),
    displayMedium: Hand.display.copyWith(color: p.ink),
    displaySmall: Hand.headline.copyWith(color: p.ink),
    headlineLarge: Hand.headline.copyWith(color: p.ink),
    headlineMedium: Hand.title.copyWith(fontSize: 34, height: 36 / 34, color: p.ink),
    headlineSmall: Hand.title.copyWith(color: p.ink),
    titleLarge: Hand.title.copyWith(color: p.ink),
    titleMedium: Hand.door.copyWith(fontSize: 24, height: 27 / 24, color: p.ink),
    titleSmall: Hand.label.copyWith(color: p.ink),
    bodyLarge: body(16, 23),
    bodyMedium: body(15, 21),
    bodySmall: body(13, 18, color: p.pencil),
    labelLarge: Hand.label.copyWith(fontSize: 20, color: p.ink),
    labelMedium: body(12, 16, weight: FontWeight.w500, color: p.pencil),
    labelSmall: body(11, 14, weight: FontWeight.w500, color: p.pencil),
  );
  const pill = StadiumBorder();
  final pen = BorderSide(color: p.ink, width: 1.6);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    fontFamily: voice.family,
    textTheme: text,
    extensions: [p],
    scaffoldBackgroundColor: p.paper,
    splashFactory: NoSplash.splashFactory,
    highlightColor: p.smudge,
    dividerTheme: DividerThemeData(color: p.rule, thickness: 1, space: 1),
    appBarTheme: AppBarTheme(
      backgroundColor: p.paper,
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      centerTitle: false,
      titleTextStyle: Hand.title.copyWith(color: p.ink),
      iconTheme: IconThemeData(color: p.ink, size: 24),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        backgroundColor: p.ink,
        foregroundColor: p.paper,
        disabledBackgroundColor: p.ink.withValues(alpha: 0.35),
        disabledForegroundColor: p.paper,
        shape: pill,
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 28),
        textStyle: Hand.label.copyWith(fontSize: 23),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        side: pen,
        shape: pill,
        minimumSize: const Size(0, 44),
        padding: const EdgeInsets.symmetric(horizontal: 18),
        textStyle: Hand.label,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.ink,
        textStyle: Hand.label,
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(6))),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: p.ink)),
    chipTheme: ChipThemeData(
      backgroundColor: p.paper,
      side: BorderSide(color: p.rule, width: 1.2),
      shape: pill,
      labelStyle: Hand.small.copyWith(color: p.ink),
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.smudge,
      hintStyle: text.bodyMedium?.copyWith(color: p.graphite),
      labelStyle: text.bodyMedium?.copyWith(color: p.pencil),
      floatingLabelStyle: text.bodySmall?.copyWith(color: p.pencil),
      helperStyle: text.labelMedium,
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
        borderSide: BorderSide.none,
      ),
      enabledBorder: const OutlineInputBorder(
        borderRadius: BorderRadius.all(Radius.circular(radius)),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: const BorderRadius.all(Radius.circular(radius)),
        borderSide: BorderSide(color: p.ink, width: 1.4),
      ),
    ),
    listTileTheme: ListTileThemeData(
      contentPadding: const EdgeInsets.symmetric(horizontal: gutter),
      iconColor: p.ink,
      titleTextStyle: text.bodyLarge,
      subtitleTextStyle: text.bodySmall,
    ),
    sliderTheme: SliderThemeData(
      activeTrackColor: p.ink,
      inactiveTrackColor: p.rule,
      thumbColor: p.ink,
      overlayColor: p.ink.withValues(alpha: 0.06),
      trackHeight: 2,
    ),
    progressIndicatorTheme: ProgressIndicatorThemeData(
      color: p.ink,
      linearTrackColor: p.rule,
      circularTrackColor: Colors.transparent,
    ),
    bottomSheetTheme: BottomSheetThemeData(
      backgroundColor: p.paper,
      surfaceTintColor: Colors.transparent,
      showDragHandle: true,
      dragHandleColor: p.graphite,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(28))),
    ),
    dialogTheme: DialogThemeData(
      backgroundColor: p.paper,
      surfaceTintColor: Colors.transparent,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(22))),
      titleTextStyle: Hand.title.copyWith(color: p.ink),
      contentTextStyle: text.bodyMedium?.copyWith(color: p.pencil),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.ink,
      contentTextStyle: Hand.label.copyWith(color: p.paper),
      shape: pill,
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: SegmentedButton.styleFrom(
        backgroundColor: p.paper,
        selectedBackgroundColor: p.ink,
        selectedForegroundColor: p.paper,
        foregroundColor: p.ink,
        side: pen,
        shape: pill,
        textStyle: Hand.label,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: p.paper,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: p.rule),
      ),
      textStyle: Hand.label.copyWith(color: p.ink),
      elevation: 1,
    ),
    tooltipTheme: TooltipThemeData(
      decoration: ShapeDecoration(color: p.ink, shape: pill),
      textStyle: text.bodySmall?.copyWith(color: p.paper),
    ),
    tabBarTheme: TabBarThemeData(
      labelColor: p.ink,
      unselectedLabelColor: p.pencil,
      dividerColor: p.rule,
      indicatorColor: p.ink,
      labelStyle: Hand.label,
      unselectedLabelStyle: Hand.label,
    ),
    expansionTileTheme: ExpansionTileThemeData(
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: p.pencil,
      collapsedIconColor: p.pencil,
    ),
  );
}
