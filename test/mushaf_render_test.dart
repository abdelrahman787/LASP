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

  testWidgets('read-only path (interactive:false) drops the per-glyph reveal '
      'machinery but still renders every word', (tester) async {
    Widget page(bool interactive) => MaterialApp(
          home: Scaffold(
            body: MushafPageWidget(
              pageNumber: 1,
              glyphs: sampleGlyphs(),
              controller: MushafPageController()..showAllWords([0, 1, 2, 3]),
              showTopBar: false,
              interactive: interactive,
            ),
          ),
        );

    await tester.pumpWidget(page(true));
    await tester.pumpAndSettle();
    final interactiveBuilders =
        find.byType(AnimatedBuilder).evaluate().length;

    await tester.pumpWidget(page(false));
    await tester.pumpAndSettle();
    final staticBuilders = find.byType(AnimatedBuilder).evaluate().length;

    // Words still render in the static path (now one Text per line)...
    expect(find.textContaining('بِسْمِ'), findsOneWidget);
    expect(find.textContaining('ٱلْحَمْدُ'), findsOneWidget);
    // ...with strictly fewer AnimatedBuilders (per-glyph machinery removed) —
    // the page-swipe build-cost reduction.
    expect(staticBuilders, lessThan(interactiveBuilders));
  });

  testWidgets('flashPosition outlines the mis-said word in red', (tester) async {
    final c = MushafPageController()..showAllWords([0, 1, 2, 3]);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MushafPageWidget(
          pageNumber: 1,
          glyphs: sampleGlyphs(),
          controller: c,
          showTopBar: false,
          flashPosition: 0, // flag word 0 as a just-confirmed substitution
        ),
      ),
    ));
    await tester.pumpAndSettle();
    final hasRed = tester.widgetList<Container>(find.byType(Container)).any((w) {
      final d = w.decoration;
      return d is BoxDecoration &&
          d.border?.top.color == const Color(0xFFD32F2F);
    });
    expect(hasRed, isTrue, reason: 'the flashed word gets a red outline');
  });

  testWidgets('a dense line in a narrow width does not overflow', (tester) async {
    // Many words on one line → the old spaceBetween + height-derived font size
    // overflowed horizontally. The per-line measure-and-shrink must prevent it.
    final glyphs = [
      for (var i = 0; i < 14; i++)
        PageGlyph(
          positionInPage: i,
          lineNumber: 1,
          type: 'word',
          text: 'كلمةٌطويلة$i',
          isCodeV2: false,
          wordId: '2:1:${i + 1}',
          surah: 2,
          ayah: 1,
        ),
    ];
    final c = MushafPageController()
      ..showAllWords(glyphs.map((g) => g.positionInPage));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          height: 640,
          child: MushafPageWidget(
            pageNumber: 2,
            glyphs: glyphs,
            controller: c,
            showTopBar: false,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull); // no RenderFlex overflow
  });
}
