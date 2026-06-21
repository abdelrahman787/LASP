import 'package:flutter/scheduler.dart';

import 'debug.dart';

/// Lightweight on-device frame profiler. Flutter DevTools can't be attached in
/// every environment, so this logs REAL per-frame build vs. raster times via
/// the engine's timing callback — enough to tell whether jank during a page
/// swipe is CPU/build-bound or GPU/raster-bound, with numbers from the actual
/// device.
///
/// Usage: `final p = FrameTimingProbe('swipe')..start();` then `p.stop()`.
/// Only frames slower than [thresholdMs] are logged (to avoid spam); a 60 Hz
/// budget is 16.7 ms, so anything ≥ [thresholdMs] dropped a frame.
class FrameTimingProbe {
  final String label;
  final double thresholdMs;
  TimingsCallback? _cb;

  FrameTimingProbe(this.label, {this.thresholdMs = 20});

  void start() {
    if (_cb != null) return;
    _cb = (List<FrameTiming> timings) {
      for (final t in timings) {
        final total = t.totalSpan.inMicroseconds / 1000.0;
        if (total < thresholdMs) continue;
        final build = t.buildDuration.inMicroseconds / 1000.0;
        final raster = t.rasterDuration.inMicroseconds / 1000.0;
        final bound = build >= raster ? 'BUILD' : 'RASTER';
        dlog('FRAME[$label] ${total.toStringAsFixed(1)}ms '
            '(build=${build.toStringAsFixed(1)} '
            'raster=${raster.toStringAsFixed(1)}) → $bound-bound');
      }
    };
    SchedulerBinding.instance.addTimingsCallback(_cb!);
  }

  void stop() {
    final cb = _cb;
    if (cb != null) {
      SchedulerBinding.instance.removeTimingsCallback(cb);
      _cb = null;
    }
  }
}
