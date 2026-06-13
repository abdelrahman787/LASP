import 'package:flutter/material.dart';

/// Day (warm paper) and Night themes. Text is rendered from fonts (not images),
/// so theming is just colors — mirrors the mushaf viewer's approach.
class AppTheme {
  static ThemeData get day => ThemeData(
        useMaterial3: true,
        brightness: Brightness.light,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1B7A6B),
          brightness: Brightness.light,
        ).copyWith(surface: const Color(0xFFFBF6EC)),
        scaffoldBackgroundColor: const Color(0xFFFBF6EC),
      );

  static ThemeData get night => ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1B7A6B),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF12130F),
      );
}
