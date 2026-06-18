import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

/// Design tokens for "Liquid Glass Arabic Devotional" (design/DESIGN.md).
/// Exact hex values transcribed from the Stitch export; component recipes
/// (glass blur/borders, gradients) live in widgets/glass.dart.
class AppTokens {
  // Core palette.
  static const primary = Color(0xFF002B66);
  static const onPrimary = Color(0xFFFFFFFF);
  static const primaryContainer = Color(0xFF194185);
  static const onPrimaryContainer = Color(0xFF8EB0FB);
  static const secondary = Color(0xFF4459A7);
  static const onSecondary = Color(0xFFFFFFFF);
  static const secondaryContainer = Color(0xFF95AAFE);
  static const onSecondaryContainer = Color(0xFF243B88);
  static const tertiary = Color(0xFF4E2100);
  static const onTertiary = Color(0xFFFFFFFF);
  static const tertiaryContainer = Color(0xFF703200);
  static const onTertiaryContainer = Color(0xFFF59B63);
  static const error = Color(0xFFBA1A1A);
  static const onError = Color(0xFFFFFFFF);
  static const errorContainer = Color(0xFFFFDAD6);
  static const onErrorContainer = Color(0xFF93000A);

  static const surface = Color(0xFFFAF9FF);
  static const onSurface = Color(0xFF1A1B20);
  static const onSurfaceVariant = Color(0xFF434751);
  static const surfaceContainerLowest = Color(0xFFFFFFFF);
  static const surfaceContainerLow = Color(0xFFF4F3F9);
  static const surfaceContainer = Color(0xFFEEEDF4);
  static const surfaceContainerHigh = Color(0xFFE8E7EE);
  static const surfaceContainerHighest = Color(0xFFE2E2E8);
  static const outline = Color(0xFF747782);
  static const outlineVariant = Color(0xFFC4C6D2);
  static const inverseSurface = Color(0xFF2F3035);
  static const onInverseSurface = Color(0xFFF1F0F7);
  static const inversePrimary = Color(0xFFAFC6FF);

  // The Mushaf Exception — cream paper, never glass.
  static const mushafPaper = Color(0xFFFDFBF7);
  static const mushafPaperRaised = Color(0xFFFFFDF9);
  static const mushafBorder = Color(0xFFE8E2D0);
  static const mushafInk = Color(0xFF1A1A17);

  // Glass recipe.
  static const double glassBlur = 32;
  static const glassFill = Color(0x73FFFFFF); // rgba(255,255,255,0.45)
  static const glassBorder = Color(0x66FFFFFF); // rgba(255,255,255,0.4)

  // Radii (rem→px).
  static const double rSm = 4;
  static const double r = 8;
  static const double rMd = 12;
  static const double rLg = 16;
  static const double rXl = 24;

  // Spacing.
  static const double containerPad = 24;
  static const double elementGap = 16;
  static const double stackSpace = 12;
  static const double glassMargin = 8;

  // Progress "liquid" fill gradient (periwinkle → navy).
  static const progressGradient = LinearGradient(
    colors: [Color(0xFF95AAFE), Color(0xFF4459A7)],
  );
}

class AppTheme {
  static ColorScheme get _lightScheme => const ColorScheme(
        brightness: Brightness.light,
        primary: AppTokens.primary,
        onPrimary: AppTokens.onPrimary,
        primaryContainer: AppTokens.primaryContainer,
        onPrimaryContainer: AppTokens.onPrimaryContainer,
        secondary: AppTokens.secondary,
        onSecondary: AppTokens.onSecondary,
        secondaryContainer: AppTokens.secondaryContainer,
        onSecondaryContainer: AppTokens.onSecondaryContainer,
        tertiary: AppTokens.tertiary,
        onTertiary: AppTokens.onTertiary,
        tertiaryContainer: AppTokens.tertiaryContainer,
        onTertiaryContainer: AppTokens.onTertiaryContainer,
        error: AppTokens.error,
        onError: AppTokens.onError,
        errorContainer: AppTokens.errorContainer,
        onErrorContainer: AppTokens.onErrorContainer,
        surface: AppTokens.surface,
        onSurface: AppTokens.onSurface,
        onSurfaceVariant: AppTokens.onSurfaceVariant,
        surfaceContainerLowest: AppTokens.surfaceContainerLowest,
        surfaceContainerLow: AppTokens.surfaceContainerLow,
        surfaceContainer: AppTokens.surfaceContainer,
        surfaceContainerHigh: AppTokens.surfaceContainerHigh,
        surfaceContainerHighest: AppTokens.surfaceContainerHighest,
        outline: AppTokens.outline,
        outlineVariant: AppTokens.outlineVariant,
        inverseSurface: AppTokens.inverseSurface,
        onInverseSurface: AppTokens.onInverseSurface,
        inversePrimary: AppTokens.inversePrimary,
      );

  static const _darkSurface = Color(0xFF121317);

  static ColorScheme get _darkScheme => _lightScheme.copyWith(
        brightness: Brightness.dark,
        surface: _darkSurface,
        onSurface: const Color(0xFFE3E2E9),
        onSurfaceVariant: const Color(0xFFC4C6D2),
        primary: AppTokens.inversePrimary,
        onPrimary: const Color(0xFF002B66),
      );

  static TextTheme _text(ColorScheme cs) {
    final base = ThemeData(brightness: cs.brightness).textTheme;
    // IBM Plex Sans Arabic for all UI; generous line heights (DESIGN.md).
    return GoogleFonts.ibmPlexSansArabicTextTheme(base).apply(
      bodyColor: cs.onSurface,
      displayColor: cs.onSurface,
    );
  }

  static ThemeData _build(ColorScheme cs) {
    final text = _text(cs);
    return ThemeData(
      useMaterial3: true,
      colorScheme: cs,
      textTheme: text,
      // The gradient background is painted by AppBackground; keep scaffolds
      // transparent so the glass reads against it.
      scaffoldBackgroundColor: Colors.transparent,
      appBarTheme: AppBarTheme(
        backgroundColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        foregroundColor: cs.onSurface,
        titleTextStyle: text.titleLarge?.copyWith(
          color: cs.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: cs.primary.withValues(alpha: 0.92),
          foregroundColor: cs.onPrimary,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
          shape: const StadiumBorder(),
          textStyle: text.labelLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: cs.inverseSurface,
        contentTextStyle: text.bodyMedium?.copyWith(color: cs.onInverseSurface),
      ),
    );
  }

  static ThemeData get light => _build(_lightScheme);
  static ThemeData get dark => _build(_darkScheme);
}
