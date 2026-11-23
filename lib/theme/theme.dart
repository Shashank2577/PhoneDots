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
    pencil: Color(0xFF555555),
    graphite: Color(0xFF6B6B6B),
    rule: Color(0x331A1A1A),
    smudge: Color(0xFFF4F3EF),
    marker: Color(0xFFFFE45C),
    markerInk: Color(0xFF1A1A1A),
    redPen: Color(0xFFC81E1E),
  );

  /// A night notebook, not white-on-black: warm charcoal and chalky ink.
  static const dark = Palette(
    paper: Color(0xFF1E1D1B),
    ink: Color(0xFFE8E3D8),
    pencil: Color(0xFFB9B3A8),
    graphite: Color(0xFFA39D92),
    rule: Color(0x59E8E3D8),
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

/// Muted pencil-box tones for speakers and charts, one set per theme
/// (tokens 2.0.0 `series` and `seriesDark`).
const seriesLight = <Color>[
  Color(0xFF1A1A1A),
  Color(0xFF8A6D1F),
  Color(0xFF3E6B5A),
  Color(0xFF7A4A6B),
  Color(0xFF4A5E85),
  Color(0xFF9A4B3C),
  Color(0xFF5F6B2E),
  Color(0xFF6B6B6B),
];
const seriesDark = <Color>[
  Color(0xFFE8E3D8),
  Color(0xFFBD9834),
  Color(0xFF6EA691),
  Color(0xFFB890AC),
  Color(0xFF8E9DBC),
  Color(0xFFC98E82),
  Color(0xFF92A34D),
  Color(0xFF9B9B9B),
];

Color seriesColor(int index, Brightness brightness) {
  final set = brightness == Brightness.dark ? seriesDark : seriesLight;
  return set[index % set.length];
}

extension PaletteX on BuildContext {
  Palette get pal => Theme.of(this).extension<Palette>()!;
  TextTheme get text => Theme.of(this).textTheme;

  /// The body-face roles (see [TypeRoles]); prefer these over [text].
  TypeRoles get type => Theme.of(this).extension<TypeRoles>()!;
}

const radius = 14.0;
const caveat = 'Caveat';

/// Max content width, so pages stay centred on a Fold's inner screen.
const maxColumn = 560.0;
const gutter = 24.0;

/// Long-form text (answers, summaries) never runs wider than this.
const readingColumn = 600.0;

/// From this width the words along the bottom become a rail on the left.
const railBreakpoint = 1000.0;
const railWidth = 200.0;

/// Minimum touch target.
const minTap = 48.0;

/// The two ways the app is set. Handwritten is the default: the reading
/// text is in a hand voice and titles, tags and names are hand-lettered
/// (Caveat). Formal sets everything you read in a plain sans and keeps
/// hand-lettering for headings and buttons only.
enum TypeStyle {
  handwritten('handwritten', 'Titles, tags and names are hand-lettered, and the text you read is in a marker hand.'),
  formal('formal', 'Everything you read is in a plain font. Only headings and buttons stay hand-lettered.');

  const TypeStyle(this.label, this.note);
  final String label;
  final String note;

  /// The voices that belong to this style, in the order settings lists them.
  List<Voice> get voices => [
    for (final v in Voice.values)
      if (v.style == this) v,
  ];

  /// The voice a tap on this style's pill picks.
  Voice get first => this == handwritten ? Voice.neat : Voice.friendly;
}

/// How the text you read is set. A voice belongs to one [TypeStyle]: the
/// hand voices to handwritten, the sans voices to formal. Headlines and
/// buttons are Caveat in both.
enum Voice {
  neat('neat hand', 'Shantell Sans, marker-neat', 'ShantellSans', hand: true, informality: 0),
  loose('loose hand', 'Shantell Sans, informal', 'ShantellSans', hand: true, informality: 100),
  handwritten('all handwritten', 'Patrick Hand', 'PatrickHand', hand: true, scale: 1.14),
  friendly('friendly', 'Nunito, a rounded sans', 'Nunito'),
  formal('crisp', 'Inter, a crisp sans', 'Inter');

  const Voice(this.label, this.note, this.family, {this.hand = false, this.scale = 1, this.informality});

  final String label;
  final String note;
  final String family;

  /// A hand voice: the roles in [TypeRoles] that formal sets in the plain
  /// face (row and content titles, tags, chips, notes) are Caveat.
  final bool hand;

  /// Patrick Hand draws small for its size; it is set a little larger.
  final double scale;

  /// Shantell Sans' INFM axis; null for static fonts.
  final double? informality;

  List<FontVariation>? get variations => informality == null ? null : [FontVariation('INFM', informality!)];

  TypeStyle get style => hand ? TypeStyle.handwritten : TypeStyle.formal;

  /// The voice of a fresh install.
  static const fallback = Voice.neat;

  static Voice byName(String name) => Voice.values.asNameMap()[name] ?? fallback;
}

/// Hand-lettered styles (Caveat). Headings and buttons use these in both
/// styles; in the handwritten style the title, tag and chip roles of
/// [TypeRoles] are Caveat too.
class Hand {
  static const display = TextStyle(fontFamily: caveat, fontWeight: FontWeight.w700, fontSize: 52, height: 58 / 52);
  static const headline = TextStyle(fontFamily: caveat, fontWeight: FontWeight.w700, fontSize: 38, height: 42 / 38);
  static const title = TextStyle(fontFamily: caveat, fontWeight: FontWeight.w700, fontSize: 30, height: 34 / 30);
  static const door = TextStyle(fontFamily: caveat, fontWeight: FontWeight.w600, fontSize: 24, height: 28 / 24);
  static const label = TextStyle(fontFamily: caveat, fontWeight: FontWeight.w600, fontSize: 24, height: 28 / 24);

  /// The small hand of tags and chips in the handwritten style.
  static const small = TextStyle(fontFamily: caveat, fontWeight: FontWeight.w600, fontSize: 18, height: 21 / 18);

  /// Headings follow the system text size up to 1.3x, so they never push the
  /// content off the screen; body text follows it fully.
  static TextScaler scaler(BuildContext context) => MediaQuery.textScalerOf(context).clamp(maxScaleFactor: 1.3);
}

const monoFamily = 'monospace';
const monoFallback = ['Menlo', 'SF Mono', 'Roboto Mono', 'Consolas', 'DejaVu Sans Mono', 'Courier New'];

/// The type roles screens use. This is the one place that decides which
/// face each kind of text gets: with a hand voice the title, note, tag, chip
/// and toast roles are Caveat (as they were before 0.9.0); with a sans voice
/// they are the plain face. The other roles are always the voice's own font.
@immutable
class TypeRoles extends ThemeExtension<TypeRoles> {
  const TypeRoles({
    required this.hand,
    required this.contentTitle,
    required this.reading,
    required this.rowTitle,
    required this.rowNote,
    required this.proseHead,
    required this.body,
    required this.meta,
    required this.caption,
    required this.dataLabel,
    required this.tag,
    required this.chip,
    required this.toast,
    required this.mono,
  });

  /// True in the handwritten style.
  final bool hand;

  /// A talk, article or person on its own page. Hand: Caveat 30/34 700.
  /// Formal: 22/28 600.
  final TextStyle contentTitle;

  /// Summaries, answers, article text. 17/26.
  final TextStyle reading;

  /// The title of a content row (a model, a file, a saved item).
  /// Hand: Caveat 24/28 600. Formal: 17/24 600.
  final TextStyle rowTitle;

  /// A row whose title is a sentence the user wrote (a remembered fact).
  /// Hand: Caveat 24/28 600. Formal: 16/24.
  final TextStyle rowNote;

  /// A heading inside an answer: always the reading face. 17/24 600.
  final TextStyle proseHead;

  /// Sentences, intros, field text. 16/24.
  final TextStyle body;

  /// Second line of a row, notes under a head. 14/20 pencil.
  final TextStyle meta;

  /// Timestamps, counts, sizes. 13/18 pencil.
  final TextStyle caption;

  /// Column heads and speaker names: always the reading face. 13/18 600.
  final TextStyle dataLabel;

  /// Tags, step numbers, badges. Hand: Caveat 18/21 600. Formal: 13/18 600.
  final TextStyle tag;

  /// The name on an attachment chip. Hand: Caveat 18/21 600. Formal: 13/18.
  final TextStyle chip;

  /// The line in a toast, in paper on ink. Hand: Caveat 24/28 600.
  /// Formal: 16/24.
  final TextStyle toast;

  /// Logs, tool calls. 13/20 ink.
  final TextStyle mono;

  factory TypeRoles.of(Palette p, Voice voice) {
    TextStyle s(double size, double line, {FontWeight weight = FontWeight.w400, Color? color}) => TextStyle(
      fontFamily: voice.family,
      fontVariations: voice.variations,
      fontWeight: weight,
      fontSize: size * voice.scale,
      height: line / size,
      color: color ?? p.ink,
    );
    // The roles 0.9.0 moved to the plain face: Caveat again with a hand voice.
    TextStyle moved(TextStyle hand, TextStyle plain) => voice.hand ? hand.copyWith(color: p.ink) : plain;
    return TypeRoles(
      hand: voice.hand,
      contentTitle: moved(Hand.title, s(22, 28, weight: FontWeight.w600)),
      reading: s(17, 26),
      rowTitle: moved(Hand.label, s(17, 24, weight: FontWeight.w600)),
      rowNote: moved(Hand.label, s(16, 24)),
      proseHead: s(17, 24, weight: FontWeight.w600),
      body: s(16, 24),
      meta: s(14, 20, color: p.pencil),
      caption: s(13, 18, color: p.pencil),
      dataLabel: s(13, 18, weight: FontWeight.w600),
      tag: moved(Hand.small, s(13, 18, weight: FontWeight.w600)),
      chip: moved(Hand.small, s(13, 18)),
      toast: moved(Hand.label, s(16, 24)).copyWith(color: p.paper),
      mono: TextStyle(
        fontFamily: monoFamily,
        fontFamilyFallback: monoFallback,
        fontSize: 13,
        height: 20 / 13,
        color: p.ink,
      ),
    );
  }

  @override
  TypeRoles copyWith() => this;

  @override
  TypeRoles lerp(TypeRoles? other, double t) => t < 0.5 || other == null ? this : other;
}

ThemeData buildTheme(Brightness brightness, {Voice voice = Voice.fallback}) {
  final p = brightness == Brightness.light ? Palette.light : Palette.dark;
  final t = TypeRoles.of(p, voice);
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
  // Material roles mapped onto the type roles: nothing under 13sp.
  final text = TextTheme(
    displayLarge: Hand.display.copyWith(color: p.ink),
    displayMedium: Hand.display.copyWith(color: p.ink),
    displaySmall: Hand.headline.copyWith(color: p.ink),
    headlineLarge: Hand.headline.copyWith(color: p.ink),
    headlineMedium: Hand.headline.copyWith(color: p.ink),
    headlineSmall: Hand.title.copyWith(color: p.ink),
    titleLarge: Hand.title.copyWith(color: p.ink),
    titleMedium: Hand.door.copyWith(color: p.ink),
    titleSmall: Hand.label.copyWith(color: p.ink),
    bodyLarge: t.reading,
    bodyMedium: t.body,
    bodySmall: t.meta,
    labelLarge: Hand.label.copyWith(color: p.ink),
    labelMedium: t.caption,
    labelSmall: t.caption,
  );
  const pill = StadiumBorder();
  final pen = BorderSide(color: p.ink, width: 1.6);
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    brightness: brightness,
    fontFamily: voice.family,
    textTheme: text,
    extensions: [p, t],
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
        disabledBackgroundColor: p.smudge,
        disabledForegroundColor: p.graphite,
        shape: pill,
        minimumSize: const Size(0, 56),
        padding: const EdgeInsets.symmetric(horizontal: 28),
        textStyle: Hand.label,
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        foregroundColor: p.ink,
        side: pen,
        shape: pill,
        disabledForegroundColor: p.graphite,
        minimumSize: const Size(0, 48),
        padding: const EdgeInsets.symmetric(horizontal: 20),
        textStyle: Hand.label,
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        foregroundColor: p.ink,
        disabledForegroundColor: p.graphite,
        textStyle: Hand.label,
        minimumSize: const Size(48, 48),
        shape: const RoundedRectangleBorder(borderRadius: BorderRadius.all(Radius.circular(6))),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(style: IconButton.styleFrom(foregroundColor: p.ink)),
    chipTheme: ChipThemeData(
      backgroundColor: p.smudge,
      side: BorderSide.none,
      shape: pill,
      labelStyle: t.tag,
      padding: const EdgeInsets.symmetric(horizontal: 6),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: p.smudge,
      hintStyle: t.body.copyWith(color: p.graphite),
      labelStyle: t.body.copyWith(color: p.pencil),
      floatingLabelStyle: t.meta,
      helperStyle: t.caption,
      helperMaxLines: 3,
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
      titleTextStyle: t.rowTitle,
      subtitleTextStyle: t.meta,
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
      contentTextStyle: t.body,
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: p.ink,
      contentTextStyle: t.toast,
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
      textStyle: t.caption.copyWith(color: p.paper),
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
