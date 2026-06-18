import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:quran_tasmee3/app/widgets/glass.dart';

void main() {
  testWidgets('GlassCard wrapping a ListTile raises no ListTile/ink assertion',
      (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            children: [
              GlassCard(
                padding: EdgeInsets.zero,
                child: ListTile(
                  title: const Text('عنصر'),
                  subtitle: const Text('وصف'),
                  onTap: () {},
                ),
              ),
              GlassCard(
                child: SwitchListTile(
                  title: const Text('تبديل'),
                  value: true,
                  onChanged: (_) {},
                ),
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The framework assertion ("ListTile background color or ink splashes may
    // be invisible…") would surface here as a thrown exception.
    expect(tester.takeException(), isNull);
    expect(find.text('عنصر'), findsOneWidget);

    // Tapping the list tile (ink ripple) must not throw either.
    await tester.tap(find.text('عنصر'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
