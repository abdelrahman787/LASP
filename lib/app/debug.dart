import 'package:flutter/foundation.dart';

/// Toggle verbose ASR/recitation diagnostics. Logs go through [debugPrint]
/// (rate-limited, stripped in release) and show as `I/flutter … [ASR] …`.
const bool kDebugAsr = true;

void dlog(String message) {
  if (kDebugAsr) debugPrint('[ASR] $message');
}
