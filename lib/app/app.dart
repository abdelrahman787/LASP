import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'providers.dart';
import 'theme.dart';
import 'widgets/glass.dart';
import '../features/auth/auth_gate.dart';
import '../features/mushaf/page_font_loader.dart';

class QuranTasmee3App extends ConsumerWidget {
  const QuranTasmee3App({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Warm ALL QCF page fonts once, here at the top of the app while only the
    // light auth/dashboard screens are visible. Each FontLoader.load fires a
    // global systemFonts re-layout — doing all 604 now (cheap re-layouts) means
    // the reader never loads a font mid-swipe, which was the page-turn jank.
    ref.listen(quranDataProvider, (prev, next) {
      next.whenData((data) {
        if (data != null) PageFontLoader.preloadAll(data.pages);
      });
    });
    final themeMode = ref.watch(themeModeProvider);
    return MaterialApp(
      title: 'Quran Tasmee3',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.light,
      darkTheme: AppTheme.dark,
      themeMode: themeMode,
      // App is Arabic-first → default to RTL, and paint the gradient backdrop
      // behind every (transparent) scaffold so the glass reads against it.
      builder: (context, child) => Directionality(
        textDirection: TextDirection.rtl,
        child: AppBackground(child: child!),
      ),
      home: const AuthGate(),
    );
  }
}
