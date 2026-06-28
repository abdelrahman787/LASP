import 'package:flutter/material.dart';
import 'package:flutter_gen/gen_l10n/app_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../shared/placeholder_screen.dart';

/// Bottom-nav shell: الرئيسية / الخطط / الإحصائيات / الإعدادات.
///
/// Tabs are placeholders in the skeleton; each is replaced as its feature lands
/// (mushaf reader from a pushed route, plans/report migrated from legacy).
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final l = L10n.of(context);
    final tabs = [
      PlaceholderScreen(title: l.homeTitle),
      PlaceholderScreen(title: l.navPlans),
      PlaceholderScreen(title: l.navStats),
      PlaceholderScreen(title: l.navSettings),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          NavigationDestination(icon: const Icon(Icons.home_outlined), label: l.navHome),
          NavigationDestination(icon: const Icon(Icons.event_note_outlined), label: l.navPlans),
          NavigationDestination(icon: const Icon(Icons.bar_chart_outlined), label: l.navStats),
          NavigationDestination(icon: const Icon(Icons.settings_outlined), label: l.navSettings),
        ],
      ),
    );
  }
}
