# Quran Tasmee3 — rebuilt app (`app/`)

The clean-slate Flutter app (blueprint hybrid approach). It sits **alongside**
the legacy app (repo-root `lib/`) and consumes the unchanged pure-Dart engine at
`../packages/quran_tasmee3_core`.

Authored without a Flutter SDK in the build environment, so **you run the Flutter
SDK steps locally**. The Dart source, structure, providers (DI swap points),
localization, and CI are all in place; only platform folders + `pub get` are
yours to generate.

## First-time setup (run once, on your machine)

```bash
cd app

# 1) Generate the native platform folders (android/ios/web/...).
#    This also overwrites some of the committed files with Flutter's templates.
flutter create --project-name quran_tasmee3 --org com.example .

# 2) Restore the authored files that step 1 clobbered (pubspec, main.dart,
#    analysis_options, .gitignore, README) back to the versions in git.
#    The new untracked platform folders are kept.
git checkout -- pubspec.yaml analysis_options.yaml .gitignore README.md lib/main.dart

# 3) Resolve dependencies (also generates l10n from lib/l10n/*.arb).
flutter pub get

# 4) Run.
flutter run            # or: flutter run -d <device>
flutter analyze
flutter test
```

If `flutter create` complains the dir is non-empty, that's fine — it fills in
only the missing native folders.

## What's here (skeleton)

```
app/
  pubspec.yaml            # core path dep + riverpod + l10n; ASR/db/firebase per phase
  l10n.yaml               # arb-dir=lib/l10n, class L10n
  analysis_options.yaml
  lib/
    main.dart             # ProviderScope → QuranTasmee3App
    app/
      app.dart            # MaterialApp (Arabic-first, RTL, M3, l10n)
      providers.dart      # DI swap points (ASR=fake, repos=in-memory)
      theme.dart          # minimal theme (full Liquid Glass migrates with UI)
    features/
      home/home_shell.dart   # bottom-nav shell (placeholder tabs)
    shared/
      placeholder_screen.dart
    l10n/
      app_en.arb, app_ar.arb
```

## Status & next steps (see `../docs/REBUILD_BLUEPRINT.md`)

- ✅ Phase 0: core frozen at 0.9.0, `../docs/CORE_API.md` written.
- 🟡 Phase 1: this skeleton (infra/DI/l10n/CI). Boots to a placeholder shell.
- ⬜ Phase 2: `StreamingAsrService` (sherpa OnlineRecognizer, isolate) at
  `asrServiceProvider`. Gate-1 on device first.
- ⬜ Phase 3: migrate mushaf / recitation / report / plans from legacy
  (rendering logic + device-tuned values preserved; data via new providers).
- ⬜ Phase 4: Firebase auth + Firestore (swap the in-memory repos).

The legacy app under repo-root `lib/` stays until each screen is migrated, then
it is removed.
