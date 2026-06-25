/// THROWAWAY entrypoint for the Gate-1 sherpa_onnx compatibility check.
///
///     flutter run -t lib/dev/gate1_main.dart
///
/// This does NOT touch the real app (lib/main.dart). Delete once Gate 1 is
/// settled. See lib/dev/gate1_asr_check.dart for what it does and which
/// (gitignored) model/wav files it needs.
library;

import 'package:flutter/material.dart';

import 'gate1_asr_check.dart';

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: GateOneScreen(),
  ));
}
