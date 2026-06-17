import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quran_tasmee3/app/data/quran_repository.dart';
import 'package:quran_tasmee3/features/mushaf/mushaf_page_controller.dart';
import 'package:quran_tasmee3/features/mushaf/mushaf_page_widget.dart';

List<PageGlyph> sampleGlyphs() => const [
      PageGlyph(positionInPage: 0, lineNumber: 1, type: 'word', text: 'بِسْمِ', isCodeV2: false, wordId: '1:1:1', surah: 1, ayah: 1),
      PageGlyph(positionInPage: 1, lineNumber: 1, type: 'word', text: 'ٱللَّهِ', isCodeV2: false, wordId: '1:1:2', surah: 1, ayah: 1),
      PageGlyph(positionInPage: 2, lineNumber: 1, type: 'ayah_end', text: '١', isCodeV2: false, wordId: null, surah: 1, ayah: 1),
      PageGlyph(positionInPage: 3, lineNumber: 2, type: 'word', text: 'ٱلْحَمْدُ', isCodeV2: false, wordId: '1:2:1', surah: 1, ayah: 2),
    ];

void main() {
  group('MushafPageController reveal API', () {
    test('starts hidden; reveal/hide/range/showAll toggle visibility', () {
      final c = MushafPageController();
      var notifications = 0;
      c.addListener(() => notifications++);

      expect(c.isVisible(0), isFalse);

      c.revealWord(0);
      expect(c.isVisible(0), isTrue);
      expect(notifications, 1);

      c.revealWord(0); // no-op, already visible → no notify
      expect(notifications, 1);

      c.revealRange([1, 2]);
      expect(c.isVisible(1) && c.isVisible(2), isTrue);

      c.hideWord(1);
      expect(c.isVisible(1), isFalse);

      c.hideAllWords();
      expect(c.isVisible(0) || c.isVisible(2), isFalse);

      c.showAllWords([0, 1, 2, 3]);
      expect([0, 1, 2, 3].every(c.isVisible), isTrue);
    });

    test('keyFor returns a stable key per position', () {
      final c = MushafPageController();
      expect(identical(c.keyFor(5), c.keyFor(5)), isTrue);
      expect(identical(c.keyFor(5), c.keyFor(6)), isFalse);
    });
  });

  testWidgets('renderer hides all then reveals a word; wordRect measures it',
      (tester) async {
    final c = MushafPageController()..hideAllWords();
    final glyphs = sampleGlyphs();

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MushafPageWidget(
          pageNumber: 1,
          glyphs: glyphs,
          controller: c,
          surahName: 'الفاتحة',
          juz: 1,
        ),
      ),
    ));
    await tester.pumpAndSettle();

    // Chrome renders.
    expect(find.text('الفاتحة'), findsOneWidget);
    expect(find.text('1'), findsOneWidget); // page pill

    // All words present in the tree (opacity 0 while hidden, but laid out).
    expect(find.text('بِسْمِ'), findsOneWidget);

    // Reveal a word → its rect becomes measurable.
    c.revealWord(0);
    await tester.pumpAndSettle();
    final rect = c.wordRect(0);
    expect(rect, isNotNull);
    expect(rect!.width, greaterThan(0));
    expect(rect.height, greaterThan(0));
  });
}
