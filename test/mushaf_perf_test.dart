import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Micro-benchmark for the page-swipe jank fix.
///
/// The old mushaf line layout called `TextPainter.layout()` for EVERY glyph on
/// EVERY build (and re-ran on each reveal / constraint change). The fix measures
/// each glyph once at a reference font size and derives the natural width by
/// linear scaling, so subsequent builds do zero layouts.
///
/// This test reproduces both strategies over a synthetic full page (15 lines ×
/// ~10 glyphs) across many simulated rebuilds, and reports wall-time +
/// TextPainter.layout() counts so the improvement is a concrete number, not a
/// claim. (Run with `flutter test --plain-name page-swipe` to see the print.)
void main() {
  test('page-swipe layout cost: cached vs per-build re-measure', () {
    // A representative page: 15 lines, ~10 glyph strings each.
    const sample = [
      'ٱلْحَمْدُ', 'لِلَّهِ', 'رَبِّ', 'ٱلْعَٰلَمِينَ', 'ٱلرَّحْمَٰنِ',
      'ٱلرَّحِيمِ', 'مَٰلِكِ', 'يَوْمِ', 'ٱلدِّينِ', 'إِيَّاكَ',
    ];
    const lines = 15;
    const rebuilds = 30; // a few seconds of paging/reveal activity
    const refFs = 10.0;
    const fs = 24.0; // a typical fitted size

    final page = <List<String>>[
      for (var l = 0; l < lines; l++) sample,
    ];

    double measure(String s, double size) {
      final tp = TextPainter(
        text: TextSpan(text: s, style: TextStyle(fontSize: size, height: 1.0)),
        textDirection: ui.TextDirection.rtl,
        maxLines: 1,
      )..layout();
      final w = tp.width;
      tp.dispose();
      return w;
    }

    // --- OLD: re-measure every glyph on every build ---------------------------
    var oldLayouts = 0;
    final swOld = Stopwatch()..start();
    for (var b = 0; b < rebuilds; b++) {
      for (final line in page) {
        var natural = 0.0;
        for (final g in line) {
          natural += measure(g, fs);
          oldLayouts++;
        }
        // (fit math omitted — identical for both)
        natural.toString();
      }
    }
    swOld.stop();

    // --- NEW: measure once at refFs, cache, then scale linearly --------------
    var newLayouts = 0;
    final sum10 = <int, double>{};
    final swNew = Stopwatch()..start();
    for (var b = 0; b < rebuilds; b++) {
      for (var li = 0; li < page.length; li++) {
        final cached = sum10[li] ??= () {
          var s = 0.0;
          for (final g in page[li]) {
            s += measure(g, refFs);
            newLayouts++;
          }
          return s;
        }();
        final natural = cached * fs / refFs;
        natural.toString();
      }
    }
    swNew.stop();

    // ignore: avoid_print
    print('PAGE-SWIPE BENCH ($lines lines × ${sample.length} glyphs, '
        '$rebuilds rebuilds):\n'
        '  OLD re-measure : ${swOld.elapsedMicroseconds / 1000} ms, '
        '$oldLayouts TextPainter.layout() calls\n'
        '  NEW cached     : ${swNew.elapsedMicroseconds / 1000} ms, '
        '$newLayouts TextPainter.layout() calls\n'
        '  speedup        : ${(swOld.elapsedMicroseconds / swNew.elapsedMicroseconds).toStringAsFixed(1)}×, '
        'layouts ${oldLayouts ~/ newLayouts}× fewer');

    // The cache must do exactly one measure pass total (lines × glyphs), vs the
    // old approach's (rebuilds ×) that — and be faster.
    expect(newLayouts, lines * sample.length);
    expect(oldLayouts, rebuilds * lines * sample.length);
    expect(swNew.elapsedMicroseconds, lessThan(swOld.elapsedMicroseconds));
  });
}
