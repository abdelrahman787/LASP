import 'package:flutter/services.dart';

/// Loads QCF V2 per-page fonts at runtime from bundled assets
/// (`assets/quran/fonts/p{page}.ttf`) under family `QCF_P{page}`.
///
/// Done at runtime (FontLoader) rather than 604 pubspec font entries, so the
/// app builds without the fonts present (they're gitignored / fetched locally),
/// and pages whose font is missing fall back to the Uthmani text gracefully.
class PageFontLoader {
  static final Set<int> _loaded = <int>{};
  static final Set<int> _failed = <int>{};

  static String family(int page) => 'QCF_P$page';

  /// Ensure the page font is registered. Returns true if usable.
  static Future<bool> ensure(int page) async {
    if (_loaded.contains(page)) return true;
    if (_failed.contains(page)) return false;
    try {
      final bytes = await rootBundle.load('assets/quran/fonts/p$page.ttf');
      final loader = FontLoader(family(page))..addFont(Future.value(bytes));
      await loader.load();
      _loaded.add(page);
      return true;
    } catch (_) {
      _failed.add(page);
      return false;
    }
  }
}
