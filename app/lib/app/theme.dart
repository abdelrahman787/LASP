import 'package:flutter/material.dart';

/// Minimal clean theme for the rebuild skeleton. The full legacy "Liquid Glass"
/// design system (glass cards, periwinkle palette, bundled IBM Plex Sans Arabic
/// + KFGQPC fonts) is migrated together with the UI screens (Phase 3) so the
/// fonts and decor assets move in one coherent step.
class AppTheme {
  static const _seed = Color(0xFF4F5BD5); // periwinkle-ish seed

  static ThemeData light() => _base(Brightness.light);
  static ThemeData dark() => _base(Brightness.dark);

  static ThemeData _base(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(seedColor: _seed, brightness: brightness);
    return ThemeData(
      useMaterial3: true,
      colorScheme: scheme,
      // IBM Plex Sans Arabic is bundled with the UI migration; until then the
      // platform Arabic font is used.
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(shape: const StadiumBorder()),
      ),
    );
  }
}
