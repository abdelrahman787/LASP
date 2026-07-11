# Continuation prompt — fix 4 real bugs in DevAsrScreen found via code review

Copy everything below the line into the other session/tool.

---

A human tester reached the dev ASR screen successfully (the 7-tap gesture
fix works) but reported: WAV mode loads the model, shows a VAD threshold
slider and Stop button, but "Results", "Last RTF", "Avg RTF" all stay at
`0`/`0.000` forever. Live Mic mode requested mic permission correctly, but
also produced zero results. There is also no visible "Logs" tab at all —
only what the earlier PROGRESS.md description called "Results/Logs tabs".

A code review (not a guess — read every line cited below) found **four
distinct, concrete bugs**, all in files from commit `730bf9a`/earlier. Fix
all four. Do not just patch symptoms — these are real logic errors.

## Bug 1 — `TabBarView` has no `TabController` (likely explains missing "Logs" tab)

`lib/features/dev_asr/dev_asr_screen.dart`, `_buildResultsAndLogs()`:

```dart
Widget _buildResultsAndLogs() {
  return TabBarView(
    children: [
      _buildResultsTab(),
      _buildLogsTab(),
    ],
  );
}
```

`TabBarView` requires a `TabController` — either passed explicitly via its
`controller:` parameter, or resolved from an ancestor `DefaultTabController`.
Neither exists anywhere in this file (`grep -n "DefaultTabController\|
TabController\|TabBar(" lib/features/dev_asr/dev_asr_screen.dart` returns
nothing). This throws a `FlutterError` ("No TabController for TabBarView")
at build time. There is also no `TabBar` widget anywhere to show tab labels
— even if the crash were somehow avoided, the user would have no way to
switch to the "Logs" tab, which matches the exact symptom reported (no Logs
tab visible at all).

**Fix:** convert `DevAsrScreen` to use a `TabController` properly. Simplest
correct approach — wrap the state class with `SingleTickerProviderStateMixin`
and create a `TabController` in `initState()`:

```dart
class _DevAsrScreenState extends State<DevAsrScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
    _asrService.onLog = _onLog;
  }

  @override
  void dispose() {
    _tabController.dispose();
    _asrService.stop();
    _resultsScrollController.dispose();
    _logsScrollController.dispose();
    super.dispose();
  }
```

Add a visible `TabBar` (e.g. inside the `AppBar`'s `bottom:` or directly
above `_buildResultsAndLogs()`) so the user can actually switch tabs:

```dart
appBar: AppBar(
  title: const Text('Dev ASR Testing (Gate 1/2)'),
  bottom: TabBar(
    controller: _tabController,
    tabs: const [
      Tab(text: 'Results'),
      Tab(text: 'Logs'),
    ],
  ),
  actions: [ /* existing clear-logs button */ ],
),
```

And wire the controller into `_buildResultsAndLogs()`:

```dart
Widget _buildResultsAndLogs() {
  return TabBarView(
    controller: _tabController,
    children: [
      _buildResultsTab(),
      _buildLogsTab(),
    ],
  );
}
```

## Bug 2 — `onResultCallback` is never set in WAV-file mode (Gate 1 always shows 0 results)

`lib/features/dev_asr/dev_asr_screen.dart`, `_start()`:

```dart
if (_mode == DevAsrMode.wavFile) {
  await _runWavTest();
} else {
  // Live mic mode — start mic capture via StreamingAsrService.start()
  // We don't use start() because it sets _onResult internally.
  // Instead, we set up the callback and start the mic manually.
  _asrService.onResultCallback = (result) {
    _onResult(result.text, result.confidence, 0.0);
  };
  await _asrService.startMicRecording();
}
```

`onResultCallback` is assigned ONLY in the `else` (live-mic) branch. In WAV
mode, it is never set, so it stays `null`. In
`lib/services/streaming_asr_service.dart`'s `_handleIsolateMessage`:

```dart
case 'result':
  if (_onResult != null && !_paused) {
    ...
    _onResult!(AsrResult(text, confidence));
  }
```

`_onResult` is a getter for `onResultCallback`. Since it's `null` in WAV
mode, this branch is silently skipped for every result the isolate produces
— explaining exactly why "Results: 0" never changes in WAV mode regardless
of whether the model actually transcribes anything.

**Fix:** set `_asrService.onResultCallback` unconditionally, before the
mode branch, in `_start()`:

```dart
_asrService.onResultCallback = (result) {
  _onResult(result.text, result.confidence, result.rtf); // see Bug 3 for .rtf
};

if (_mode == DevAsrMode.wavFile) {
  await _runWavTest();
} else {
  await _asrService.startMicRecording();
}
```

## Bug 3 — RTF is hardcoded to `0.0` and the real value from the isolate is discarded

The isolate's documented protocol
(`lib/services/asr/asr_isolate.dart` header comment, line 19) says it sends:

```
{'type': 'result', 'text': String, 'confidence': double, 'rtf': double}
```

But `streaming_asr_service.dart`'s `_handleIsolateMessage` only reads `text`
and `confidence`:

```dart
case 'result':
  if (_onResult != null && !_paused) {
    final text = message['text'] as String? ?? '';
    final confidence = (message['confidence'] as num?)?.toDouble() ?? 0.0;
    _onResult!(AsrResult(text, confidence));
  }
```

`message['rtf']` is never read. `AsrResult` (from the core package,
`quran_tasmee3_core/recitation/asr_service.dart`) also has no `rtf` field —
it only carries `text` and `confidence`. And separately, in
`dev_asr_screen.dart`'s live-mic callback, RTF is hardcoded:
`_onResult(result.text, result.confidence, 0.0)`.

**Fix:** the dev screen needs the real per-segment RTF for its stats bar,
but `AsrResult` (the production `AsrService` contract) intentionally doesn't
carry it — don't change the core-facing contract. Instead, add a
**dev-screen-only** callback path that carries RTF alongside the normal
result:

1. In `streaming_asr_service.dart`, add a second, optional callback used
   only by the dev screen:
   ```dart
   /// Dev-screen-only: receives (text, confidence, rtf) for every result.
   /// Production code should use [onResultCallback] instead, which only
   /// carries the AsrService-contract (text, confidence).
   void Function(String text, double confidence, double rtf)? onDevResult;
   ```
2. In `_handleIsolateMessage`'s `case 'result':`, read `message['rtf']` and
   call both callbacks:
   ```dart
   case 'result':
     final text = message['text'] as String? ?? '';
     final confidence = (message['confidence'] as num?)?.toDouble() ?? 0.0;
     final rtf = (message['rtf'] as num?)?.toDouble() ?? 0.0;
     if (!_paused) {
       _onResult?.call(AsrResult(text, confidence));
       onDevResult?.call(text, confidence, rtf);
     }
   ```
3. In `dev_asr_screen.dart`'s `_start()`, use `onDevResult` instead of
   `onResultCallback` directly for the dev screen's own display (so it gets
   the real RTF), for BOTH modes (fixes Bug 2 at the same time):
   ```dart
   _asrService.onDevResult = _onResult; // _onResult(text, confidence, rtf)
   ```
   (Remove the old `onResultCallback = (result) => _onResult(result.text,
   result.confidence, 0.0)` assignment entirely — replaced by the line
   above, which now also fixes Bug 2 since it's set unconditionally for
   both WAV and mic modes.)

## Bug 4 — `stop()` kills the isolate before it can flush and deliver the final result

`lib/services/streaming_asr_service.dart`, `stop()`:

```dart
Future<void> stop() async {
  _running = false;
  onResultCallback = null;   // <-- cleared immediately

  await _micSubscription?.cancel();
  ...
  if (_isolateSendPort != null) {
    _isolateSendPort!.send({'type': 'stop'});   // fire-and-forget
  }
  _isolate?.kill(priority: Isolate.immediate);   // <-- killed right away
  ...
}
```

The isolate's own `stop()` handler (`asr_isolate.dart`) correctly tries to
flush any buffered segment and run one last inference before releasing
resources — but the main isolate doesn't wait for that to finish before
calling `_isolate?.kill(priority: Isolate.immediate)`, and clears the result
callback before sending `'stop'` at all. Any speech buffered right up to the
moment "Stop" is pressed is lost, and even if the isolate raced to finish in
time, the callback is already null so the result would be dropped anyway.

**Fix:** wait for the isolate to acknowledge `'stopped'` before killing it,
and clear the callback only after that (or accept the last result if one
arrives during shutdown):

```dart
Future<void> stop() async {
  _running = false;

  await _micSubscription?.cancel();
  _micSubscription = null;
  try {
    await _recorder?.stop();
  } catch (_) {}
  await _recorder?.dispose();
  _recorder = null;

  if (_isolateSendPort != null) {
    final stopped = Completer<void>();
    // Temporarily listen for the 'stopped' ack (and let any final 'result'
    // still flow through the existing _handleIsolateMessage handler).
    void onStoppedAck(message) {
      if (message is Map && message['type'] == 'stopped') {
        if (!stopped.isCompleted) stopped.complete();
      }
    }
    // _mainReceivePort already has a listener from init(); reuse the same
    // dispatch path — _handleIsolateMessage's 'stopped' case should now
    // complete a completer stored on the instance rather than doing
    // nothing, OR simplest: give the isolate a short grace period.
    _isolateSendPort!.send({'type': 'stop'});
    await stopped.future.timeout(
      const Duration(milliseconds: 500),
      onTimeout: () {},
    );
  }

  onResultCallback = null;
  onDevResult = null;
  _isolate?.kill(priority: Isolate.immediate);
  _isolate = null;
  _mainReceivePort?.close();
  _mainReceivePort = null;
  _isolateSendPort = null;
  _initialized = false;
}
```

You will need to make `_handleIsolateMessage`'s `case 'stopped':` complete a
stored `Completer<void>?` field instead of its current no-op, and store the
`Completer` created above on the instance so both places can see it. Use
whatever clean implementation fits the existing code style — the key
requirement is: **don't kill the isolate immediately; give it a short grace
period (a few hundred ms is enough) to flush and deliver its final result
first, and don't null out the callbacks until after that grace period.**

## After fixing all four

1. Rebuild the release APK, paste real build output (same evidence standard
   as every prior round).
2. State plainly that none of these fixes have been verified on a real
   device from this sandbox — the human must reinstall and re-test Gate 1
   (WAV mode: expect non-zero results, a real RTF number, and a visible
   Logs tab) and Gate 2 (Live Mic: expect the same, plus confirm stopping
   mid-speech doesn't silently drop the last utterance).
3. Update `PROGRESS.md` with what was fixed and why, using the same
   evidence rules as every prior round (quote the actual diffs, don't just
   assert "fixed").
4. **Commit all changes and push to `origin/main` on
   `abdelrahman787/quran-tasmee3-rebuild` — do not stop at a local commit.**
   Report back the actual commit hash AND confirm the push succeeded (e.g.
   by showing the `git push` output showing the remote ref update, the same
   way every prior round in this project reported it). If the push fails
   for any reason (auth, network, etc.), say so explicitly rather than
   reporting the fix as "done" — a fix that only exists locally in the
   sandbox is not reviewable and is not done.
