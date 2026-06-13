import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/app.dart';

// NOTE (SWAP POINT 2 — Firebase): when wiring Firebase, this becomes:
//   WidgetsFlutterBinding.ensureInitialized();
//   await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
//   FirebaseFirestore.instance.settings =
//       const Settings(persistenceEnabled: true);
// (DefaultFirebaseOptions comes from the firebase_options.dart that
//  `flutterfire configure` generates.)
void main() {
  runApp(const ProviderScope(child: QuranTasmee3App()));
}
