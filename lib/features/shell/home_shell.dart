import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../dashboard/dashboard_screen.dart';
import '../mushaf/mushaf_reader_screen.dart';
import '../plans/plans_screen.dart';
import '../settings/settings_screen.dart';

/// Persistent bottom-navigation shell around the main tabs
/// (المصحف / الخطط / الإحصائيات / الإعدادات). Each tab is its own Scaffold;
/// IndexedStack keeps their state alive across switches.
class HomeShell extends ConsumerStatefulWidget {
  const HomeShell({super.key});

  @override
  ConsumerState<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends ConsumerState<HomeShell> {
  // Default to the dashboard (الإحصائيات) tab.
  int _index = 2;

  static const _tabs = <Widget>[
    MushafReaderScreen(),
    PlansScreen(),
    DashboardScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(index: _index, children: _tabs),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
              icon: Icon(Icons.menu_book_outlined),
              selectedIcon: Icon(Icons.menu_book),
              label: 'المصحف'),
          NavigationDestination(
              icon: Icon(Icons.list_alt_outlined),
              selectedIcon: Icon(Icons.list_alt),
              label: 'الخطط'),
          NavigationDestination(
              icon: Icon(Icons.bar_chart_outlined),
              selectedIcon: Icon(Icons.bar_chart),
              label: 'الإحصائيات'),
          NavigationDestination(
              icon: Icon(Icons.settings_outlined),
              selectedIcon: Icon(Icons.settings),
              label: 'الإعدادات'),
        ],
      ),
    );
  }
}
