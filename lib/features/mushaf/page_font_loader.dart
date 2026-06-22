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
  static bool _preloadStarted = false;

  static String family(int page) => 'QCF_P$page';

  /// True if the page font is already registered (so a render won't trigger a
  /// load + global systemFonts re-layout on the visible/swipe frame).
  static bool isLoaded(int page) => _loaded.contains(page);

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

  /// Register ALL page fonts up-front (once per app run), so that swiping never
  /// triggers a font load — every FontLoader.load fires a GLOBAL systemFonts
  /// re-layout, and doing that during a swipe is the page-turn jank. Loading
  /// here (off the swipe, ordered nearest-first) moves all of it ahead of time.
  /// A tiny gap between loads spreads the re-layouts so they don't bunch into a
  /// visible stutter. Idempotent; safe to call on every reader open.
  static Future<void> preloadAll(List<int> pages) async {
    if (_preloadStarted) return;
    _preloadStarted = true;
    for (final p in pages) {
      if (_loaded.contains(p) || _failed.contains(p)) continue;
      await ensure(p);
      await Future<void>.delayed(const Duration(milliseconds: 6));
    }
  }
}
