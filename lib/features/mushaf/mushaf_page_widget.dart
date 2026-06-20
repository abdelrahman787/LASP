import 'package:flutter/material.dart';

import '../../app/data/quran_repository.dart';
import '../../app/theme.dart';
import 'mushaf_page_controller.dart';
import 'page_font_loader.dart';
import 'surah_banner.dart';

// The Mushaf Exception (DESIGN.md): cream paper, never glass.
const Color _kCream = AppTokens.mushafPaper;
const Color _kInk = AppTokens.mushafInk;
const Color _kBar = Color(0xFFF3ECDB);
const Color _kAccent = AppTokens.secondary;

/// Pixel-faithful (font-based) mushaf page: 15 lines stretched edge-to-edge,
/// RTL, justified, each word a QCF V2 `code_v2` glyph in the page font. Words
/// toggle visibility via [MushafPageController] so the recitation engine can
/// hide the page and reveal words one-by-one.
///
/// NOTE: exact justification metrics / per-line font scaling are approximated
/// here and want on-device tuning; the data + reveal contract are exact.
class MushafPageWidget extends StatefulWidget {
  final int pageNumber;
  final List<PageGlyph> glyphs;
  final MushafPageController controller;

  /// Glyph position to highlight as the recitation cursor (optional).
  final int? currentPosition;

  /// Chrome.
  final String surahName;
  final int? juz;
  final int? hizb;
  final VoidCallback? onHome;
  final VoidCallback? onBookmark;

  /// When false, the widget's own top bar is omitted (the host screen, e.g. the
  /// recitation session, already provides an AppBar — avoids a duplicate).
  final bool showTopBar;

  /// surah id → Arabic name, for the surah-start banner (optional).
  final Map<int, String>? surahNames;

  /// If provided, a تسميع button is shown in the bottom bar (reader mode).
  final VoidCallback? onTasmee;

  const MushafPageWidget({
    super.key,
    required this.pageNumber,
    required this.glyphs,
    required this.controller,
    this.currentPosition,
    this.surahName = '',
    this.juz,
    this.hizb,
    this.onHome,
    this.onBookmark,
    this.showTopBar = true,
    this.surahNames,
    this.onTasmee,
  });

  @override
  State<MushafPageWidget> createState() => _MushafPageWidgetState();
}

class _MushafPageWidgetState extends State<MushafPageWidget> {
  late Future<bool> _fontReady;

  @override
  void initState() {
    super.initState();
    _fontReady = PageFontLoader.ensure(widget.pageNumber);
  }

  @override
  Widget build(BuildContext context) {
    // Build a slot ONLY for line numbers that actually have glyphs on this page
    // (sorted). These slots then stretch to fill 100% of the height — no dead
    // blank flex slots, so no large empty gap regardless of how many lines a
    // page uses (e.g. the framed Al-Fatiha page uses fewer than 15).
    final lines =
        widget.glyphs.map((g) => g.lineNumber).where((l) => l > 0).toSet().toList()
          ..sort();
    return Column(
      children: [
        if (widget.showTopBar) _topBar(context),
        Expanded(
          child: Container(
            color: _kCream,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: FutureBuilder<bool>(
              future: _fontReady,
              builder: (context, snap) {
                final fontReady = snap.data ?? false;
                if (lines.isEmpty) return const SizedBox.shrink();
                // Lines stretch (Expanded); a surah-start banner + Basmala are
                // inserted as fixed-height blocks before the line that begins a
                // new surah.
                final children = <Widget>[];
                for (final line in lines) {
                  final first = _firstGlyphOf(line);
                  if (first != null &&
                      first.type == 'word' &&
                      first.ayah == 1 &&
                      _isFirstWord(first)) {
                    children.add(_surahBanner(first.surah));
                    if (first.surah != 1 && first.surah != 9) {
                      children.add(_basmala());
                    }
                  }
                  children.add(Expanded(child: _line(line, fontReady)));
                }
                return Column(children: children);
              },
            ),
          ),
        ),
        _bottomBar(context),
      ],
    );
  }

  Widget _line(int line, bool fontReady) {
    final glyphs = widget.glyphs.where((g) => g.lineNumber == line).toList()
      ..sort((a, b) => a.positionInPage.compareTo(b.positionInPage));
    if (glyphs.isEmpty) return const SizedBox.shrink();

    return Directionality(
      textDirection: TextDirection.rtl,
      child: LayoutBuilder(
        builder: (context, c) {
          // Start from a height-derived size, then SHRINK it so the line's
          // natural width never exceeds the available width — guarantees no
          // horizontal RenderFlex overflow. spaceBetween then distributes the
          // remaining space so the line still fills edge-to-edge.
          var fs = (c.maxHeight * 0.6).clamp(10.0, 40.0);
          // Reserve per-glyph horizontal padding (2px) + the cursor-highlight
          // border (~3px, always reserved so it's cursor-independent) + a few
          // px of layout rounding slack.
          final budget =
              (c.maxWidth - glyphs.length * 2 - 12).clamp(1.0, c.maxWidth);
          var natural = 0.0;
          for (final g in glyphs) {
            natural += _measureGlyph(g, fs, fontReady);
          }
          // Always derive fs from the fit ratio (×0.97 safety), so even a line
          // whose natural width is just under budget can't overflow from
          // measurement-vs-layout rounding. No lower clamp.
          if (natural > 0) {
            final ratio = (budget / natural) * 0.97;
            if (ratio < 1) fs = (fs * ratio).clamp(1.0, c.maxHeight);
          }
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [for (final g in glyphs) _glyph(g, fs, fontReady)],
          );
        },
      ),
    );
  }

  /// Measure a glyph's natural width at [fontSize] (page font for code_v2).
  double _measureGlyph(PageGlyph g, double fontSize, bool fontReady) {
    final fam =
        (g.isCodeV2 && fontReady) ? PageFontLoader.family(widget.pageNumber) : null;
    final tp = TextPainter(
      text: TextSpan(
        text: g.text,
        style: TextStyle(fontFamily: fam, fontSize: fontSize, height: 1.0),
      ),
      textDirection: TextDirection.rtl,
      maxLines: 1,
    )..layout();
    return tp.width;
  }

  Widget _glyph(PageGlyph g, double fontSize, bool fontReady) {
    final usePageFont = g.isCodeV2 && fontReady;
    return AnimatedBuilder(
      animation: widget.controller,
      builder: (context, _) {
        final visible = widget.controller.isVisible(g.positionInPage);
        final isCursor = g.positionInPage == widget.currentPosition;
        // The glyph slot always reserves the word's natural size (keyed for
        // wordRect). The Text stays laid out even when hidden so the
        // placeholder pill matches the REAL per-word dimensions (correction #7)
        // rather than an arbitrary width.
        return Container(
          key: widget.controller.keyFor(g.positionInPage),
          padding: const EdgeInsets.symmetric(horizontal: 1),
          decoration: isCursor
              ? BoxDecoration(
                  border: Border.all(color: _kAccent, width: 1.5),
                  borderRadius: BorderRadius.circular(4),
                )
              : null,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Text(
                g.text,
                textAlign: TextAlign.center,
                // Mushaf text must not follow the system font-scale, and this
                // matches the TextPainter measurement (which is unscaled), so
                // the fit calc and the actual render agree → no overflow.
                textScaler: TextScaler.noScaling,
                style: TextStyle(
                  fontFamily: usePageFont
                      ? PageFontLoader.family(widget.pageNumber)
                      : null,
                  fontSize: fontSize,
                  color: visible ? _kInk : Colors.transparent,
                  height: 1.0,
                ),
              ),
              if (!visible)
                Positioned.fill(
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 220),
                    margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 1),
                    decoration: BoxDecoration(
                      color: _kInk.withValues(alpha: 0.07),
                      borderRadius: BorderRadius.circular(6),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _topBar(BuildContext context) {
    return Container(
      color: _kBar,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.home, color: _kInk),
            tooltip: 'الرئيسية',
            onPressed: widget.onHome,
          ),
          Expanded(
            child: Text(
              widget.surahName,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: _kInk, fontSize: 18, fontWeight: FontWeight.w600),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.bookmark_border, color: _kInk),
            tooltip: 'إشارة مرجعية',
            onPressed: widget.onBookmark,
          ),
        ],
      ),
    );
  }

  // wordId is "<surah>:<ayah>:<wordIndex>"; surah start = ayah 1, word 1.
  bool _isFirstWord(PageGlyph g) => g.wordId?.endsWith(':1') ?? false;

  PageGlyph? _firstGlyphOf(int line) {
    PageGlyph? best;
    for (final g in widget.glyphs) {
      if (g.lineNumber != line) continue;
      if (best == null || g.positionInPage < best.positionInPage) best = g;
    }
    return best;
  }

  Widget _surahBanner(int surah) {
    final name = widget.surahNames?[surah] ?? 'سورة $surah';
    return SurahBanner(name: name);
  }

  Widget _basmala() {
    return const Padding(
      padding: EdgeInsets.only(bottom: 4),
      child: Text(
        'بِسْمِ اللَّهِ الرَّحْمَٰنِ الرَّحِيمِ',
        textAlign: TextAlign.center,
        textScaler: TextScaler.noScaling,
        style: TextStyle(color: _kInk, fontSize: 18),
      ),
    );
  }

  Widget _bottomBar(BuildContext context) {
    Widget side(Widget child, AlignmentGeometry a) =>
        Expanded(child: Align(alignment: a, child: child));
    final juzLabel = Text(widget.juz != null ? 'الجزء ${widget.juz}' : '',
        style: const TextStyle(color: _kInk, fontSize: 13));
    // Right side: تسميع button in reader mode, otherwise the hizb label.
    final Widget rightSide = widget.onTasmee != null
        ? FilledButton.icon(
            onPressed: widget.onTasmee,
            icon: const Icon(Icons.mic, size: 18),
            label: const Text('تسميع'),
            style: FilledButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            ),
          )
        : Text(widget.hizb != null ? 'الحزب ${widget.hizb}' : '',
            style: const TextStyle(color: _kInk, fontSize: 13));

    return Container(
      color: _kBar,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          side(juzLabel, AlignmentDirectional.centerStart),
          // Truly centered page pill (both sides are equal-width Expanded).
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            decoration: BoxDecoration(
              color: _kAccent,
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text('${widget.pageNumber}',
                style: const TextStyle(color: Colors.white, fontSize: 13)),
          ),
          side(rightSide, AlignmentDirectional.centerEnd),
        ],
      ),
    );
  }
}
