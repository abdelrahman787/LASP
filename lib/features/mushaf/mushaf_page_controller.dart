import 'package:flutter/widgets.dart';

/// Reveal API for the mushaf page renderer (Mushaf viewer Phase 2 contract).
///
/// The recitation engine drives this: on session start it calls
/// [hideAllWords]; as words are recited correctly it calls [revealWord] /
/// [revealRange]. Positions are `positionInPage` (0-based reading order across
/// ALL glyphs on the page — words + ayah-end medallions + pause marks).
class MushafPageController extends ChangeNotifier {
  final Set<int> _visible = <int>{};
  final Map<int, GlobalKey> _keys = <int, GlobalKey>{};

  bool isVisible(int positionInPage) => _visible.contains(positionInPage);

  /// Stable key per glyph so [wordRect] can measure its laid-out rect.
  GlobalKey keyFor(int positionInPage) =>
      _keys.putIfAbsent(positionInPage, () => GlobalKey());

  void hideAllWords() {
    if (_visible.isEmpty) return;
    _visible.clear();
    notifyListeners();
  }

  /// Make every position in [allPositions] visible (normal reading).
  void showAllWords(Iterable<int> allPositions) {
    _visible
      ..clear()
      ..addAll(allPositions);
    notifyListeners();
  }

  void revealWord(int positionInPage) {
    if (_visible.add(positionInPage)) notifyListeners();
  }

  void hideWord(int positionInPage) {
    if (_visible.remove(positionInPage)) notifyListeners();
  }

  void revealRange(Iterable<int> positions) {
    var changed = false;
    for (final p in positions) {
      changed = _visible.add(p) || changed;
    }
    if (changed) notifyListeners();
  }

  /// The laid-out rect of a glyph (global coords), or null if not built yet.
  /// Satisfies the engine's "bbox" reference without external pixel JSON.
  Rect? wordRect(int positionInPage) {
    final ctx = _keys[positionInPage]?.currentContext;
    final box = ctx?.findRenderObject();
    if (box is! RenderBox || !box.attached) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }
}
