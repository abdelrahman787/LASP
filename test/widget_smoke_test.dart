import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quran_tasmee3/app/app.dart';

void main() {
  testWidgets('app boots to the dashboard on fake data', (tester) async {
    await tester.pumpWidget(const ProviderScope(child: QuranTasmee3App()));
    await tester.pumpAndSettle();

    // AppBar title + the "start review" CTA render from real (fake-backed) data.
    expect(find.text('قرآن تسميع'), findsOneWidget);
    expect(find.text('ابدأ المراجعة'), findsOneWidget);
    // No weak items yet → empty-state hint shown.
    expect(find.textContaining('لا توجد أخطاء'), findsOneWidget);
  });
}
