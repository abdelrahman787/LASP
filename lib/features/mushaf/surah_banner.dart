import 'package:flutter/material.dart';

/// The decorative surah-name banner shown at the start of a surah.
///
/// The ornament is ONE shared, self-authored raster frame
/// (`assets/decor/surah_banner_frame.webp`, ~18 KB, transparent margins, no
/// text baked in) reused for every surah. The surah name is drawn on TOP as
/// real font text so it is always crisp and correctly shaped — never baked into
/// a lossy image. See `tools/art/make_surah_banner.py` for the frame source.
///
/// Text rendering honors the project's "use the real QCF V2 glyphs" preference
/// with a graceful fallback (the same pattern as the page fonts): when a
/// KFGQPC surah-header [glyph] + [glyphFontFamily] are supplied (from the seed
/// pipeline), they are used; otherwise the plain Arabic [name] is rendered in
/// the bundled IBM Plex Sans Arabic. Either way the text is font-rendered.
class SurahBanner extends StatelessWidget {
  /// Plain Arabic surah name (e.g. "البقرة") — the always-available fallback.
  final String name;

  /// Optional KFGQPC surah-header glyph string (a PUA code point) for this
  /// surah, rendered in [glyphFontFamily]. When null, [name] is used instead.
  final String? glyph;

  /// Font family registered for [glyph] (e.g. the loaded QBSML header font).
  final String? glyphFontFamily;

  /// Aspect ratio of the frame asset (1200x300).
  static const double _aspect = 1200 / 300;

  /// Asset path of the shared frame.
  static const String _frameAsset = 'assets/decor/surah_banner_frame.webp';

  const SurahBanner({
    super.key,
    required this.name,
    this.glyph,
    this.glyphFontFamily,
  });

  @override
  Widget build(BuildContext context) {
    final useGlyph = glyph != null && glyph!.isNotEmpty && glyphFontFamily != null;
    // RepaintBoundary: the banner never changes during paging/reveal, so isolate
    // it from the constantly-repainting page so swipes/reveals stay cheap.
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: AspectRatio(
          aspectRatio: _aspect,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // The ornamental frame fills the box; transparent margins let the
              // cream page show through around it.
              const Image(
                image: AssetImage(_frameAsset),
                fit: BoxFit.fill,
                filterQuality: FilterQuality.medium,
              ),
              // Surah name centered over the cartouche. The cartouche spans the
              // central ~40% of the frame width; constrain the text to it so a
              // long name shrinks instead of spilling onto the ornament.
              Center(
                child: FractionallySizedBox(
                  widthFactor: 0.38,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      useGlyph ? glyph! : name,
                      textAlign: TextAlign.center,
                      textScaler: TextScaler.noScaling,
                      maxLines: 1,
                      style: TextStyle(
                        fontFamily: useGlyph ? glyphFontFamily : 'IBM Plex Sans Arabic',
                        fontSize: 26,
                        height: 1.0,
                        fontWeight: useGlyph ? FontWeight.normal : FontWeight.w700,
                        color: const Color(0xFF1A1A17), // ink, on the cream cartouche
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
