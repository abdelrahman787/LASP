import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quran_tasmee3_core/review/repositories.dart';
import 'package:quran_tasmee3_core/review/settings.dart';

import 'package:quran_tasmee3/app/app.dart';
import 'package:quran_tasmee3/app/data/auth_service.dart';
import 'package:quran_tasmee3/app/providers.dart';

void main() {
  testWidgets('boots to dashboard when signed in (fakes, no Firebase)',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        // Inject fakes so no real Firebase/ASR is touched.
        overrides: [
          authServiceProvider
              .overrideWithValue(FakeAuthService(signedIn: true)),
          weakItemRepositoryProvider
              .overrideWithValue(InMemoryWeakItemRepository()),
          planRepositoryProvider.overrideWithValue(InMemoryPlanRepository()),
          reviewHistoryRepositoryProvider
              .overrideWithValue(InMemoryReviewHistoryRepository()),
          settingsRepositoryProvider
              .overrideWithValue(InMemorySettingsRepository()),
          // Resolve Quran data immediately (no path_provider/SQLite in tests),
          // so the reader tab doesn't sit on an indefinite loading spinner.
          quranDataProvider.overrideWith((ref) => null),
        ],
        child: const QuranTasmee3App(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('القرآن الكريم'), findsWidgets); // home app bar title
    expect(find.text('إكمال التسميع'), findsOneWidget); // continue card
    // Bottom-nav shell is present.
    expect(find.text('الرئيسية'), findsWidgets);
  });

  testWidgets('shows login screen when signed out', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authServiceProvider.overrideWithValue(FakeAuthService()),
        ],
        child: const QuranTasmee3App(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('تسجيل الدخول'), findsOneWidget);
  });
}
