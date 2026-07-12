import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quran_tasmee3/app/app.dart';

void main() {
  testWidgets('app boots to the home shell with a bottom nav', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: QuranTasmee3App()));
    await tester.pumpAndSettle();

    // The skeleton shell shows a 4-tab NavigationBar.
    expect(find.byType(NavigationBar), findsOneWidget);
  });
}
