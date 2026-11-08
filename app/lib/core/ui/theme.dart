import 'package:flutter/material.dart';

/// Calm, neutral palette for a university service: a muted deep green seed
/// (Kashmir valley / campus green) on neutral surfaces, with light and dark.
class AppTheme {
  static const seed = Color(0xFF2F5D50);

  /// Bus status colours, shared by the map and lists (P8).
  static const onTime = Color(0xFF2E7D32);
  static const delayed = Color(0xFFB26A00);
  static const breakdown = Color(0xFFC62828);
  static const stale = Color(0xFF8D8D8D);

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static ThemeData _build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: seed,
      brightness: brightness,
      dynamicSchemeVariant: DynamicSchemeVariant.tonalSpot,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      visualDensity: VisualDensity.standard,
      appBarTheme: AppBarTheme(
        centerTitle: false,
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(minimumSize: const Size.fromHeight(48)),
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
      ),
      snackBarTheme: const SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
      ),
    );
  }
}
