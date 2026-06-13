import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'theme.dart';
import '../features/dashboard/dashboard_screen.dart';

class QuranTasmee3App extends ConsumerWidget {
  const QuranTasmee3App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Quran Tasmee3',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.day,
      darkTheme: AppTheme.night,
      themeMode: themeMode,
      // App is Arabic-first → default to RTL.
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: child!,
      ),
      home: const DashboardScreen(),
    );
  }
}
