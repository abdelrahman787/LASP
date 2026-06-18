import 'dart:ui';

import 'package:flutter/material.dart';

import '../theme.dart';

/// Soft periwinkle/navy gradient backdrop the glass reads against
/// (DESIGN.md: radial tints over #faf9ff). Wrap a screen body in this.
class AppBackground extends StatelessWidget {
  final Widget child;
  const AppBackground({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: dark
            ? const LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [Color(0xFF15171C), Color(0xFF101116)],
              )
            : const LinearGradient(
                begin: Alignment.topRight,
                end: Alignment.bottomLeft,
                colors: [Color(0xFFE9EEFF), Color(0xFFFAF9FF), Color(0xFFF1ECFF)],
                stops: [0.0, 0.5, 1.0],
              ),
      ),
      child: child,
    );
  }
}

/// Frosted "liquid glass" surface: 32px backdrop blur, translucent fill, a
/// light top/right-leaning hairline border, rounded (default 1rem).
class GlassCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;
  final VoidCallback? onTap;
  final Color? fill;

  const GlassCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(AppTokens.elementGap),
    this.radius = AppTokens.rLg,
    this.onTap,
    this.fill,
  });

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final br = BorderRadius.circular(radius);
    final fillColor = fill ??
        (dark ? Colors.white.withValues(alpha: 0.06) : AppTokens.glassFill);
    final borderColor =
        dark ? Colors.white.withValues(alpha: 0.10) : AppTokens.glassBorder;
    return ClipRRect(
      borderRadius: br,
      child: BackdropFilter(
        filter: ImageFilter.blur(
            sigmaX: AppTokens.glassBlur / 2, sigmaY: AppTokens.glassBlur / 2),
        // Paint the glass fill + hairline border via the Material itself (not a
        // DecoratedBox) so a child ListTile/SwitchListTile/ExpansionTile paints
        // its own background + ink ripples correctly on top of it.
        child: Material(
          color: fillColor,
          shape: RoundedRectangleBorder(
            borderRadius: br,
            side: BorderSide(color: borderColor, width: 1),
          ),
          child: InkWell(
            onTap: onTap,
            customBorder: RoundedRectangleBorder(borderRadius: br),
            child: Padding(padding: padding, child: child),
          ),
        ),
      ),
    );
  }
}

/// Pill status chip (e.g. plan item status, error category counts).
class StatusChip extends StatelessWidget {
  final String label;
  final Color color;
  final Color? onColor;
  const StatusChip(this.label, {super.key, required this.color, this.onColor});

  @override
  Widget build(BuildContext context) {
    final fg = onColor ?? color;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.16),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(color: fg, fontWeight: FontWeight.w600),
      ),
    );
  }
}

/// Pill-shaped "liquid" progress track with a glowing periwinkle fill.
class LiquidProgress extends StatelessWidget {
  final double value; // 0..1
  final double height;
  const LiquidProgress({super.key, required this.value, this.height = 10});

  @override
  Widget build(BuildContext context) {
    final v = value.clamp(0.0, 1.0);
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: LayoutBuilder(
        builder: (context, c) => Stack(
          children: [
            Container(height: height, color: AppTokens.surfaceContainerHighest),
            Container(
              height: height,
              width: c.maxWidth * v,
              decoration: const BoxDecoration(gradient: AppTokens.progressGradient),
            ),
          ],
        ),
      ),
    );
  }
}

/// Three-way recitation mode selector (سهل / عادي / صارم) — the pill row used
/// on both the recitation and settings screens.
class ModeSelector<T> extends StatelessWidget {
  final List<({T value, String label})> options;
  final T selected;
  final ValueChanged<T> onChanged;
  const ModeSelector({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: cs.surfaceContainerLow,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: cs.outlineVariant.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final o in options)
            GestureDetector(
              onTap: () => onChanged(o.value),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 6),
                decoration: BoxDecoration(
                  color: o.value == selected
                      ? cs.secondaryContainer
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  o.label,
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: o.value == selected
                            ? cs.onSecondaryContainer
                            : cs.onSurfaceVariant,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
