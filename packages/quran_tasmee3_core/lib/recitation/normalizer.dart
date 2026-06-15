/// Text normalization for the recitation **matching** engine.
///
/// IMPORTANT: normalization is used for *matching only* — it must never be
/// used to alter text that is displayed to the user. The mushaf is always
/// rendered from its original Uthmani text (with diacritics); the normalizer
/// exists purely to compare what the student recited against what is expected.
///
/// See Recitation Engine spec, Phase 1a.
library;

/// Tatweel / kashida (U+0640) — purely decorative letter elongation.
const int _tatweel = 0x0640;

/// Superscript (dagger) alef.
const int _superscriptAlef = 0x0670;

/// Returns `true` if [cp] is a combining diacritic / Quranic annotation mark
/// that should be stripped before matching.
///
/// Covers, per spec:
///  - U+064B–U+065F : standard Arabic diacritics (fathatan…) + extended marks
///  - U+06D6–U+06ED : Quranic annotation signs (small high/low marks, sajda…)
///  - U+08D3–U+08FF : Arabic Extended-B combining marks (where present)
///
/// NOTE: the **superscript (dagger) alef U+0670 is NOT stripped here** — it
/// denotes a pronounced long-aa that the rasm omits (e.g. مَٰلِك), and ASR
/// transcribes it as a full alef (مالك). Stripping it produced "ملك" which
/// failed to match the recognized "مالك". It is instead mapped to a real alef
/// in the unification step below.
bool _isDiacritic(int cp) {
  if (cp >= 0x064B && cp <= 0x065F) return true;
  if (cp >= 0x06D6 && cp <= 0x06ED) return true;
  if (cp >= 0x08D3 && cp <= 0x08FF) return true;
  return false;
}

/// Returns `true` if [cp] is an Arabic base letter we keep, or an ASCII/Arabic
/// space. Everything else (punctuation, digits, ayah glyphs, Latin letters…)
/// is stripped in step 7.
bool _isArabicLetterOrSpace(int cp) {
  if (cp == 0x20) return true; // space
  // Arabic letters block (after the unifications below, carriers collapse into
  // this range). 0x0621 (hamza) … 0x064A (ya). We also tolerate 0x0671 etc.
  // but those are remapped before this check runs.
  if (cp >= 0x0621 && cp <= 0x064A) return true;
  return false;
}

/// Normalize [input] for matching. Steps run **in order** (spec Phase 1a):
///  1. Remove tatweel.
///  2. Strip diacritics / Quranic marks.
///  3. Unify alef variants → ا (0627).
///  4. Unify alef maksura ى → ي (064A).
///  5. Unify hamza carriers: ؤ→و, ئ→ي; keep ء.
///  6. Unify ta marbuta ة → ه (0647).
///  7. Drop non-Arabic-letter/non-space chars; collapse spaces; trim.
String normalizeForMatch(String input) {
  final out = StringBuffer();

  for (final cp in input.runes) {
    // 1. tatweel
    if (cp == _tatweel) continue;
    // 2. diacritics / marks
    if (_isDiacritic(cp)) continue;

    int c = cp;
    switch (c) {
      // 3. alef unification (incl. dagger alef U+0670 → full alef, so the
      // rasm's omitted long-aa matches ASR's spelled-out alef, e.g. مَٰلِك→مالك).
      case 0x0623: // أ hamza above
      case 0x0625: // إ hamza below
      case 0x0622: // آ madda
      case 0x0671: // ٱ wasla
      case _superscriptAlef: // ٰ U+0670 dagger alef
        c = 0x0627; // ا
        break;
      // 4. alef maksura → ya
      case 0x0649: // ى
        c = 0x064A; // ي
        break;
      // 5. hamza carriers
      case 0x0624: // ؤ
        c = 0x0648; // و
        break;
      case 0x0626: // ئ
        c = 0x064A; // ي
        break;
      // 6. ta marbuta → ha
      case 0x0629: // ة
        c = 0x0647; // ه
        break;
      default:
        break;
    }

    // 7. keep only Arabic letters / spaces
    if (_isArabicLetterOrSpace(c)) {
      out.writeCharCode(c);
    } else {
      // Replace stripped char with a space so it acts as a token boundary,
      // then collapse below. (e.g. punctuation between words.)
      out.writeCharCode(0x20);
    }
  }

  // collapse multiple spaces + trim
  return out.toString().replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Split an already-normalized string into tokens on whitespace, dropping
/// empty entries.
List<String> tokenize(String normalized) {
  if (normalized.isEmpty) return const [];
  return normalized
      .split(' ')
      .where((t) => t.isNotEmpty)
      .toList(growable: false);
}
