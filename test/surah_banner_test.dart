import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quran_tasmee3/features/mushaf/surah_banner.dart';

void main() {
  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  testWidgets('renders the plain name (font fallback) when no glyph given',
      (tester) async {
    await tester.pumpWidget(host(const SurahBanner(name: 'البقرة')));
    expect(find.text('البقرة'), findsOneWidget);
    // The shared ornamental frame is drawn behind the text.
    expect(find.byType(Image), findsOneWidget);
  });

  testWidgets('uses the QCF header glyph + font when supplied', (tester) async {
    const g = '\uF600'; // a PUA surah-header glyph code point
    await tester.pumpWidget(host(const SurahBanner(
      name: 'البقرة',
      glyph: g,
      glyphFontFamily: 'QCF_QBSML',
    )));
    // Glyph supersedes the plain name.
    expect(find.text(g), findsOneWidget);
    expect(find.text('البقرة'), findsNothing);
    final txt = tester.widget<Text>(find.text(g));
    expect(txt.style?.fontFamily, 'QCF_QBSML');
  });
}
