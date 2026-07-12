import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';

void main() {
  // Firebase.initializeApp(...) is added in Phase 4 (cloud sync). The app is
  // fully usable offline without it.
  runApp(const ProviderScope(child: QuranTasmee3App()));
}
