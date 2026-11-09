import 'package:flutter/material.dart';

/// Design tokens ("Kashmir University", docs/design/README.md) resolved for
/// one brightness. Reach them with `Theme.of(context).extension<CtmsColors>()!`
/// or the `context.ctms` shortcut.
@immutable
class CtmsColors extends ThemeExtension<CtmsColors> {
  const CtmsColors({
    required this.olive,
    required this.maroon,
    required this.gold,
    required this.blue,
    required this.bg,
    required this.surface,
    required this.text,
    required this.muted,
    required this.border,
    required this.onTime,
    required this.delayed,
    required this.breakdown,
    required this.stale,
  });

  final Color olive, maroon, gold, blue;
  final Color bg, surface, text, muted, border;

  /// Semantic bus status colours. Always pair with text or an icon.
  final Color onTime, delayed, breakdown, stale;

  static const light = CtmsColors(
    olive: Color(0xFF5C7D1F),
    maroon: Color(0xFF7C1E21),
    gold: Color(0xFFD79B28),
    blue: Color(0xFF3170CD),
    bg: Color(0xFFFBFAF5),
    surface: Color(0xFFFFFFFF),
    text: Color(0xFF213021),
    muted: Color(0xFF687768),
    border: Color(0xFFDDE5D7),
    onTime: Color(0xFF2E7D4F),
    delayed: Color(0xFFB26A00),
    breakdown: Color(0xFF7C1E21),
    stale: Color(0xFF8D8D8D),
  );

  static const dark = CtmsColors(
    olive: Color(0xFFA3C964),
    maroon: Color(0xFF7C1E21),
    gold: Color(0xFFD79B28),
    blue: Color(0xFF6B9BE6),
    bg: Color(0xFF121A14),
    surface: Color(0xFF1D2A20),
    text: Color(0xFFF4F7EC),
    muted: Color(0xFFB8C5B6),
    border: Color(0xFF3B4A3C),
    onTime: Color(0xFF7FD3A0),
    delayed: Color(0xFFE8B04A),
    breakdown: Color(0xFFF08A8C),
    stale: Color(0xFF9AA79A),
  );

  @override
  CtmsColors copyWith({
    Color? olive,
    Color? maroon,
    Color? gold,
    Color? blue,
    Color? bg,
    Color? surface,
    Color? text,
    Color? muted,
    Color? border,
    Color? onTime,
    Color? delayed,
    Color? breakdown,
    Color? stale,
  }) => CtmsColors(
    olive: olive ?? this.olive,
    maroon: maroon ?? this.maroon,
    gold: gold ?? this.gold,
    blue: blue ?? this.blue,
    bg: bg ?? this.bg,
    surface: surface ?? this.surface,
    text: text ?? this.text,
    muted: muted ?? this.muted,
    border: border ?? this.border,
    onTime: onTime ?? this.onTime,
    delayed: delayed ?? this.delayed,
    breakdown: breakdown ?? this.breakdown,
    stale: stale ?? this.stale,
  );

  @override
  CtmsColors lerp(ThemeExtension<CtmsColors>? other, double t) {
    if (other is! CtmsColors) return this;
    Color l(Color a, Color b) => Color.lerp(a, b, t)!;
    return CtmsColors(
      olive: l(olive, other.olive),
      maroon: l(maroon, other.maroon),
      gold: l(gold, other.gold),
      blue: l(blue, other.blue),
      bg: l(bg, other.bg),
      surface: l(surface, other.surface),
      text: l(text, other.text),
      muted: l(muted, other.muted),
      border: l(border, other.border),
      onTime: l(onTime, other.onTime),
      delayed: l(delayed, other.delayed),
      breakdown: l(breakdown, other.breakdown),
      stale: l(stale, other.stale),
    );
  }
}

extension CtmsThemeContext on BuildContext {
  /// The design tokens for the current theme.
  CtmsColors get ctms => Theme.of(this).extension<CtmsColors>()!;
}

/// Font helpers for the three design families. Colours are left to the
/// caller (or the surrounding [DefaultTextStyle]).
class CtmsText {
  CtmsText._();

  static const _tabular = [FontFeature.tabularFigures()];

  /// IBM Plex Mono with tabular figures: ETAs, clocks, distances, counts.
  static TextStyle data(
    BuildContext context,
    double size, [
    FontWeight weight = FontWeight.w500,
  ]) => TextStyle(
    fontFamily: 'IBMPlexMono',
    fontSize: size,
    fontWeight: weight,
    fontFeatures: _tabular,
  );

  /// Newsreader serif for screen titles and big statements.
  static TextStyle headline(
    BuildContext context,
    double size, [
    FontWeight weight = FontWeight.w600,
  ]) => TextStyle(
    fontFamily: 'Newsreader',
    fontSize: size,
    fontWeight: weight,
    height: 1.1,
    letterSpacing: -0.5,
    color: Theme.of(context).extension<CtmsColors>()!.text,
  );

  /// Geist for UI text, with tabular figures so counters do not jitter.
  static TextStyle ui(
    BuildContext context,
    double size, [
    FontWeight weight = FontWeight.w400,
  ]) => TextStyle(
    fontFamily: 'Geist',
    fontSize: size,
    fontWeight: weight,
    fontFeatures: _tabular,
    color: Theme.of(context).extension<CtmsColors>()!.text,
  );
}

/// Calm olive/cream design system with light and dark themes.
class AppTheme {
  /// Brand seed (ku-olive, light).
  static const seed = Color(0xFF5C7D1F);

  /// Bus status colours, shared by the map and lists. Widgets that react to
  /// the theme should read [CtmsColors] instead.
  static const onTime = Color(0xFF2E7D4F);
  static const delayed = Color(0xFFB26A00);
  static const breakdown = Color(0xFF7C1E21);
  static const stale = Color(0xFF8D8D8D);

  static ThemeData light() => _build(Brightness.light, CtmsColors.light);

  static ThemeData dark() => _build(Brightness.dark, CtmsColors.dark);

  /// The driver workspace always uses the dark theme (night driving).
  static ThemeData driverDark() => dark();

  static const _radius = 14.0;

  static ThemeData _build(Brightness brightness, CtmsColors c) {
    final isLight = brightness == Brightness.light;
    final scheme = ColorScheme(
      brightness: brightness,
      primary: c.olive,
      onPrimary: isLight ? Colors.white : const Color(0xFF14210A),
      primaryContainer: isLight
          ? const Color(0xFFE6ECD6)
          : const Color(0xFF2C3D1A),
      onPrimaryContainer: c.text,
      secondary: c.blue,
      onSecondary: Colors.white,
      secondaryContainer: isLight
          ? const Color(0xFFDCE7F7)
          : const Color(0xFF22344F),
      onSecondaryContainer: c.text,
      tertiary: c.gold,
      onTertiary: const Color(0xFF2A1D00),
      error: c.maroon,
      onError: Colors.white,
      errorContainer: isLight
          ? const Color(0xFFF4DCDC)
          : const Color(0xFF4A1D1F),
      onErrorContainer: isLight
          ? const Color(0xFF4A1214)
          : const Color(0xFFFFDAD9),
      surface: c.bg,
      onSurface: c.text,
      onSurfaceVariant: c.muted,
      surfaceContainerLowest: c.surface,
      surfaceContainerLow: c.surface,
      surfaceContainer: c.surface,
      surfaceContainerHigh: c.surface,
      surfaceContainerHighest: isLight
          ? const Color(0xFFEEF1E6)
          : const Color(0xFF263629),
      outline: c.muted,
      outlineVariant: c.border,
      shadow: Colors.black,
      scrim: Colors.black,
      inverseSurface: isLight
          ? const Color(0xFF253426)
          : const Color(0xFFF4F7EC),
      onInverseSurface: isLight
          ? const Color(0xFFF4F7EC)
          : const Color(0xFF213021),
      inversePrimary: isLight
          ? const Color(0xFFA3C964)
          : const Color(0xFF5C7D1F),
      surfaceTint: Colors.transparent,
    );

    final base = ThemeData(brightness: brightness, useMaterial3: true);
    final text = _textTheme(base.textTheme, c);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_radius),
    );
    final hairline = BorderSide(color: c.border);
    OutlineInputBorder inputBorder(Color color, [double w = 1]) =>
        OutlineInputBorder(
          borderRadius: BorderRadius.circular(_radius),
          borderSide: BorderSide(color: color, width: w),
        );

    return ThemeData(
      brightness: brightness,
      useMaterial3: true,
      colorScheme: scheme,
      scaffoldBackgroundColor: c.bg,
      canvasColor: c.bg,
      fontFamily: 'Geist',
      textTheme: text,
      primaryTextTheme: text,
      visualDensity: VisualDensity.standard,
      dividerTheme: DividerThemeData(color: c.border, space: 1, thickness: 1),
      extensions: [c],
      appBarTheme: AppBarTheme(
        centerTitle: false,
        elevation: 0,
        scrolledUnderElevation: 0,
        backgroundColor: c.bg,
        foregroundColor: c.text,
        surfaceTintColor: Colors.transparent,
        titleTextStyle: text.titleLarge?.copyWith(
          fontFamily: 'Newsreader',
          fontWeight: FontWeight.w600,
          fontSize: 22,
        ),
      ),
      cardTheme: CardThemeData(
        color: c.surface,
        elevation: 0,
        margin: EdgeInsets.zero,
        surfaceTintColor: Colors.transparent,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius + 4),
          side: hairline,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: shape,
          textStyle: const TextStyle(
            fontFamily: 'Geist',
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          elevation: 0,
          shape: shape,
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size.fromHeight(52),
          shape: shape,
          side: BorderSide(color: c.border),
          foregroundColor: c.text,
          textStyle: const TextStyle(
            fontFamily: 'Geist',
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: c.olive,
          textStyle: const TextStyle(
            fontFamily: 'Geist',
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: c.surface,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: inputBorder(c.border),
        enabledBorder: inputBorder(c.border),
        focusedBorder: inputBorder(c.olive, 1.5),
        errorBorder: inputBorder(scheme.error),
        focusedErrorBorder: inputBorder(scheme.error, 1.5),
        labelStyle: TextStyle(color: c.muted),
        hintStyle: TextStyle(color: c.muted),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: c.surface,
        selectedColor: scheme.primaryContainer,
        side: hairline,
        shape: const StadiumBorder(),
        labelStyle: TextStyle(
          fontFamily: 'Geist',
          fontSize: 13,
          fontWeight: FontWeight.w500,
          color: c.text,
        ),
        showCheckmark: false,
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        height: 68,
        indicatorColor: Colors.transparent,
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => TextStyle(
            fontFamily: 'Geist',
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color: states.contains(WidgetState.selected) ? c.olive : c.muted,
          ),
        ),
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            size: 24,
            color: states.contains(WidgetState.selected) ? c.olive : c.muted,
          ),
        ),
      ),
      navigationRailTheme: NavigationRailThemeData(
        backgroundColor: c.bg,
        indicatorColor: scheme.primaryContainer,
        selectedIconTheme: IconThemeData(color: c.olive),
        unselectedIconTheme: IconThemeData(color: c.muted),
        selectedLabelTextStyle: TextStyle(
          fontFamily: 'Geist',
          fontWeight: FontWeight.w600,
          color: c.olive,
        ),
        unselectedLabelTextStyle: TextStyle(
          fontFamily: 'Geist',
          color: c.muted,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: scheme.inverseSurface,
        contentTextStyle: TextStyle(
          fontFamily: 'Geist',
          color: scheme.onInverseSurface,
        ),
        shape: shape,
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_radius + 6),
          side: hairline,
        ),
        titleTextStyle: text.titleLarge?.copyWith(
          fontFamily: 'Newsreader',
          fontWeight: FontWeight.w600,
        ),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: c.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          side: hairline,
        ),
      ),
      listTileTheme: ListTileThemeData(iconColor: c.muted, textColor: c.text),
      tabBarTheme: TabBarThemeData(
        labelColor: c.olive,
        unselectedLabelColor: c.muted,
        indicatorColor: c.olive,
        dividerColor: c.border,
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: c.olive),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? scheme.onPrimary : c.muted,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? c.olive : c.border,
        ),
      ),
    );
  }

  /// Geist for UI, Newsreader for display/headline, tabular figures on data.
  static TextTheme _textTheme(TextTheme base, CtmsColors c) {
    const tab = [FontFeature.tabularFigures()];
    TextStyle? serif(TextStyle? s) => s?.copyWith(
      fontFamily: 'Newsreader',
      fontWeight: FontWeight.w600,
      letterSpacing: -0.5,
      color: c.text,
    );
    TextStyle? ui(TextStyle? s, [Color? color]) => s?.copyWith(
      fontFamily: 'Geist',
      fontFeatures: tab,
      color: color ?? c.text,
    );
    return base.copyWith(
      displayLarge: serif(base.displayLarge),
      displayMedium: serif(base.displayMedium),
      displaySmall: serif(base.displaySmall),
      headlineLarge: serif(base.headlineLarge),
      headlineMedium: serif(base.headlineMedium),
      headlineSmall: serif(base.headlineSmall),
      titleLarge: ui(base.titleLarge)?.copyWith(fontWeight: FontWeight.w600),
      titleMedium: ui(base.titleMedium)?.copyWith(fontWeight: FontWeight.w600),
      titleSmall: ui(base.titleSmall)?.copyWith(fontWeight: FontWeight.w600),
      bodyLarge: ui(base.bodyLarge),
      bodyMedium: ui(base.bodyMedium),
      bodySmall: ui(base.bodySmall, c.muted),
      labelLarge: ui(base.labelLarge)?.copyWith(fontWeight: FontWeight.w600),
      labelMedium: ui(base.labelMedium, c.muted),
      labelSmall: ui(base.labelSmall, c.muted),
    );
  }
}
