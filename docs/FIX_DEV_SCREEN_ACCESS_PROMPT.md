# Continuation prompt — fix the unreliable dev-screen gesture in `abdelrahman787/quran-tasmee3-rebuild`

Copy everything below the line into the other session/tool.

---

A human tester installed `app-release.apk` (commit `b05fad8`) on a real
Android device. Two things were reported:
1. The Recite tab starts producing text on its own with no mic activity and
   no permission prompt — this is **expected, not a bug**: `providers.dart:37`
   correctly still returns `FakeAsrServiceImpl()`, which is a scripted
   `Timer`-based fake with zero mic access, by design, pending Gate 2.
2. **The hidden dev-ASR screen could not be reached at all** — the
   documented gesture (5x long-press the Settings bottom-nav icon within 3
   seconds) never opened `DevAsrScreen` on the real device. This blocks
   Gate 1/2 entirely, since there's no way to reach the real ASR pipeline
   without it.

## Root cause (found by code review, not yet device-confirmed — verify it)

`lib/features/home/home_screen.dart:99-105`:

```dart
BottomNavigationBarItem(
  icon: GestureDetector(
    onLongPress: _onSettingsLongPress,
    child: const Icon(Icons.settings),
  ),
  label: 'إعدادات',
),
```

This wraps only the small `Icon` widget in a `GestureDetector`, nested
inside a `BottomNavigationBarItem`. Two known-fragile properties of this
pattern:
1. **Tiny hit-test area** — only the icon glyph itself, not the label text
   or the rest of the tab's tappable region a user naturally presses.
2. **Gesture arena conflict with `BottomNavigationBar`'s own tap handling**
   — `BottomNavigationBar` has its own internal `InkResponse`/tap-recognition
   per item (this is what drives `onTap: (index) => ...`). A long-press
   `GestureDetector` nested inside one item's `icon` competes with that for
   the gesture arena, and in practice (this is a documented, recurring
   Flutter behavior across versions/devices) can fail to register reliably,
   especially for `onLongPress` specifically, which has stricter win
   conditions than a simple tap.

This is very likely why the gesture "sometimes works, mostly doesn't" or
doesn't work at all on a real device, even though it may have appeared to
work in whatever environment it was last informally checked in (a simulator/
emulator's more forgiving touch/pointer handling can mask exactly this kind
of real-device touch-precision issue).

## Fix: move the trigger to a proven-reliable pattern

Do not try to patch the existing bottom-nav gesture — replace it with the
same mechanism Android itself uses for "Developer options": **tap a
specific row/value 7 times in a row within the Settings screen**, not on the
bottom navigation bar at all. This avoids all gesture-arena conflicts with
`BottomNavigationBar` entirely, since it's a plain tap (not long-press) on
an ordinary widget inside a normal screen.

1. In `lib/features/settings/settings_screen.dart`, find (or add, if it
   doesn't already show one) a version/about row — something like "الإصدار
   1.0.0" or an "About" list tile near the bottom of the settings list.
2. Wrap that row in a plain `GestureDetector` (or use `ListTile`'s `onTap`
   directly, which is simpler and doesn't have the nesting problem the
   bottom-nav icon has) with a tap counter:

```dart
int _versionTapCount = 0;
DateTime? _firstVersionTapTime;

void _onVersionTap() {
  final now = DateTime.now();
  if (_firstVersionTapTime != null &&
      now.difference(_firstVersionTapTime!).inSeconds > 3) {
    _versionTapCount = 0;
  }
  if (_versionTapCount == 0) _firstVersionTapTime = now;
  _versionTapCount++;

  if (_versionTapCount >= 7) {
    _versionTapCount = 0;
    _firstVersionTapTime = null;
    Navigator.of(context).push(
      MaterialPageRoute(builder: (context) => const DevAsrScreen()),
    );
  }
}
```

   Use `onTap` (regular tap, not `onLongPress`) — 7 quick taps is both the
   familiar Android convention and avoids long-press's stricter gesture-arena
   resolution entirely.
3. Delete the old `_onSettingsLongPress`/`_settingsLongPressCount`/
   `_firstLongPressTime` state and the `GestureDetector` wrapping the
   Settings tab icon in `home_screen.dart` — don't leave two competing
   trigger mechanisms in the codebase.
4. Update the doc comment at the top of `home_screen.dart` (currently says
   "long-press the Settings tab icon 5 times") and any mention of this in
   `PROGRESS.md`'s smoke-test script (Part 6, section I) to describe the new
   "tap the version/about row in Settings 7 times within 3 seconds"
   mechanism instead.
5. Rebuild the release APK (`flutter build apk --release`, same signing
   config already wired in commit `b05fad8`) and report the real build
   output, same evidence standard as always.
6. **You cannot verify the new gesture actually works on a real device from
   this sandbox** — say so explicitly. The human will install the new APK
   and confirm. Do not claim this fix is verified until they report back.

## After this fix is confirmed reachable — resume Gate 1/2

Once the human confirms the dev screen opens reliably with the new
mechanism, proceed exactly as laid out in the prior Gate 1/2 handoff
instructions already in `PROGRESS.md`: WAV mode (Gate 1) → live mic mode +
VAD tuning (Gate 2) → human confirms transcription accuracy → flip
`asrServiceProvider` from `FakeAsrServiceImpl` to `StreamingAsrService`.
