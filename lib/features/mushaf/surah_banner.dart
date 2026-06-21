import 'package:flutter/material.dart';

/// KFGQPC Uthman Taha Naskh — authentic mushaf Naskh (King Fahd Complex), used
/// for surah names, the ayah-count line, and the Basmala. A complete Naskh
/// typeface, so it renders all three as plain Unicode text — no per-page PUA
/// glyph import needed.
const String kUthmanNaskh = 'KFGQPC Uthman Taha Naskh';

const Color _kInk = Color(0xFF1A1A17);

/// Eastern Arabic-Indic numerals (٠-٩), to match the mushaf's numbering.
String easternDigits(int n) {
  const d = ['٠', '١', '٢', '٣', '٤', '٥', '٦', '٧', '٨', '٩'];
  return n.toString().split('').map((c) {
    final i = int.tryParse(c);
    return i == null ? c : d[i];
  }).join();
}

/// The ayah-count line for a full-page surah opening: "وهي ﴿N﴾ آيات/آية" with the
/// ornate Quranic ornate parentheses (U+FD3E / U+FD3F) and Eastern numerals.
/// Arabic grammar: counts 3–10 take the plural "آيات", otherwise "آية".
String surahAyahCountLabel(int count) {
  final noun = (count >= 3 && count <= 10) ? 'آيات' : 'آية';
  // Logical order: ﴿ (U+FD3E) then number then ﴾ (U+FD3F) — renders with the
  // ornaments correctly enclosing the numeral under RTL shaping.
  return 'وهي ﴿${easternDigits(count)}﴾ $noun';
}

Widget _cartoucheText(String text, {String? fontFamily, FontWeight? weight}) {
  return FittedBox(
    fit: BoxFit.scaleDown,
    child: Text(
      text,
      textAlign: TextAlign.center,
      textScaler: TextScaler.noScaling,
      maxLines: 1,
      style: TextStyle(
        fontFamily: fontFamily ?? kUthmanNaskh,
        fontSize: 40,
        height: 1.0,
        fontWeight: weight ?? FontWeight.w400,
        color: _kInk,
      ),
    ),
  );
}

/// Case A — the general surah-transition banner (mid-page, e.g. Hud/Yunus).
/// One real ornamental asset reused for every surah; the name is drawn on top
/// in [kUthmanNaskh] (crisp, never baked in). The Basmala renders separately
/// below this, per the page layout.
///
/// Keeps the optional [glyph]/[glyphFontFamily] override (a PUA header glyph) as
/// an alternative to the plain [name]; by default the name renders in Naskh.
class SurahBanner extends StatelessWidget {
  final String name;
  final String? glyph;
  final String? glyphFontFamily;

  static const String _asset = 'assets/decor/surah_transition_banner.webp';
  static const double _aspect = 2172 / 724;
  // Measured cartouche box (fractions of the asset).
  static const Rect _cartouche = Rect.fromLTRB(0.255, 0.40, 0.745, 0.66);

  const SurahBanner({
    super.key,
    required this.name,
    this.glyph,
    this.glyphFontFamily,
  });

  @override
  Widget build(BuildContext context) {
    final useGlyph =
        glyph != null && glyph!.isNotEmpty && glyphFontFamily != null;
    return RepaintBoundary(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: AspectRatio(
          aspectRatio: _aspect,
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth, h = c.maxHeight;
              return Stack(
                fit: StackFit.expand,
                children: [
                  const Image(
                    image: AssetImage(_asset),
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                  ),
                  Positioned.fromRect(
                    rect: Rect.fromLTRB(_cartouche.left * w, _cartouche.top * h,
                        _cartouche.right * w, _cartouche.bottom * h),
                    child: Center(
                      child: _cartoucheText(useGlyph ? glyph! : name,
                          fontFamily: useGlyph ? glyphFontFamily : null),
                    ),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

/// Case B — the full-page ornate frame for the OPENING page of Al-Fatiha and
/// Al-Baqarah only. Wraps the page's ayah lines ([content]) inside the inner
/// area, with the surah [name] in the top cartouche and the ayah-count line in
/// the bottom cartouche. (Low reuse, so the heavier 226 KB asset is fine.)
class SurahFramePage extends StatelessWidget {
  final String name;
  final int ayahCount;
  final Widget content;

  static const String _asset = 'assets/decor/fatiha_baqarah_frame.webp';
  static const double _aspect = 968 / 1605;
  // Measured boxes (fractions of the asset).
  static const Rect _top = Rect.fromLTRB(0.345, 0.085, 0.655, 0.215);
  static const Rect _body = Rect.fromLTRB(0.250, 0.265, 0.750, 0.735);
  static const Rect _bottom = Rect.fromLTRB(0.345, 0.780, 0.655, 0.915);

  const SurahFramePage({
    super.key,
    required this.name,
    required this.ayahCount,
    required this.content,
  });

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: Center(
        child: AspectRatio(
          aspectRatio: _aspect,
          child: LayoutBuilder(
            builder: (context, c) {
              final w = c.maxWidth, h = c.maxHeight;
              Positioned box(Rect r, Widget child) => Positioned.fromRect(
                    rect: Rect.fromLTRB(
                        r.left * w, r.top * h, r.right * w, r.bottom * h),
                    child: child,
                  );
              return Stack(
                fit: StackFit.expand,
                children: [
                  const Image(
                    image: AssetImage(_asset),
                    fit: BoxFit.fill,
                    filterQuality: FilterQuality.medium,
                  ),
                  box(_top, Center(child: _cartoucheText(name))),
                  box(_body, content),
                  box(_bottom,
                      Center(child: _cartoucheText(surahAyahCountLabel(ayahCount)))),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
