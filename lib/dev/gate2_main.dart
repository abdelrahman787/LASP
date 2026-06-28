/// THROWAWAY entrypoint for the Gate-2 live-mic streaming ASR check.
///
///     flutter run -t lib/dev/gate2_main.dart
///
/// Required files (gitignored — download from Muno459/fastconformer-quran-streaming):
///   assets/models/streaming/encoder.onnx
///   assets/models/streaming/decoder.onnx
///   assets/models/streaming/joiner.onnx
///   assets/models/streaming/tokens.txt
///
/// Also reuses:
///   assets/models/tarteel/silero_vad.onnx  (already present from Gate-1)
///
/// Delete once Gate 2 is settled. See lib/dev/gate2_screen.dart for the UI.
library;

import 'package:flutter/material.dart';

import 'gate2_screen.dart';

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: GateTwoScreen(),
  ));
}
