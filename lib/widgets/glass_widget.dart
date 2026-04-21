import 'package:flutter/material.dart';

/// M3 Expressive surface container. Replaces the former liquid-glass widgets
/// with a solid tonal surface that follows Material 3 Expressive elevation
/// guidance. Older glass parameters (`blur`, `opacity`, `liveBlur`,
/// `lightenAmount`) are accepted for source compatibility but ignored.
class AppLiquidGlass extends StatelessWidget {
  const AppLiquidGlass({
    super.key,
    required this.child,
    this.padding,
    this.blur = 0,
    this.opacity = 0,
    this.borderRadius = const BorderRadius.all(Radius.circular(28)),
    this.tint,
    this.elevation = 0,
    this.liveBlur = false,
    this.lightenAmount,
  });

  final Widget child;
  final EdgeInsetsGeometry? padding;
  final double blur;
  final double opacity;
  final BorderRadius borderRadius;
  final Color? tint;
  final double elevation;
  final bool liveBlur;
  final double? lightenAmount;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    final bg = tint ?? cs.surfaceContainerHigh;

    return Material(
      color: bg,
      shape: RoundedRectangleBorder(borderRadius: borderRadius),
      clipBehavior: Clip.antiAlias,
      elevation: 0,
      shadowColor: Colors.transparent,
      surfaceTintColor: Colors.transparent,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: borderRadius,
          border: Border.all(
            color: cs.outlineVariant.withOpacity(isDark ? 0.18 : 0.28),
            width: 0.6,
          ),
        ),
        padding: padding ?? EdgeInsets.zero,
        child: child,
      ),
    );
  }
}

class AppLiquidGlassPill extends StatelessWidget {
  const AppLiquidGlassPill({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    this.blur = 0,
    this.opacity = 0,
    this.tint,
    this.elevation = 0,
    this.liveBlur = false,
    this.lightenAmount,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double blur;
  final double opacity;
  final Color? tint;
  final double elevation;
  final bool liveBlur;
  final double? lightenAmount;

  @override
  Widget build(BuildContext context) {
    return AppLiquidGlass(
      borderRadius: const BorderRadius.all(Radius.circular(999)),
      tint: tint,
      padding: padding,
      child: child,
    );
  }
}

/// Legacy alias — kept for backward compatibility. Renders a flat M3 surface.
class GlassWidget extends StatelessWidget {
  const GlassWidget({
    super.key,
    required this.child,
    this.blur = 0,
    this.opacity = 0,
    this.borderRadius = 16.0,
    this.borderColor,
    this.borderWidth = 0.6,
  });

  final Widget child;
  final double blur;
  final double opacity;
  final double borderRadius;
  final Color? borderColor;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    return AppLiquidGlass(
      borderRadius: BorderRadius.circular(borderRadius),
      child: child,
    );
  }
}

/// Legacy alias — kept for backward compatibility. Renders a flat M3 surface.
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.blur = 0,
    this.opacity = 0,
    this.borderRadius = 20.0,
    this.gradient,
    this.borderColor,
    this.borderWidth = 0.6,
    this.elevation = 0,
  });

  final Widget child;
  final double blur;
  final double opacity;
  final double borderRadius;
  final Gradient? gradient;
  final Color? borderColor;
  final double borderWidth;
  final double elevation;

  @override
  Widget build(BuildContext context) {
    return AppLiquidGlass(
      borderRadius: BorderRadius.circular(borderRadius),
      child: child,
    );
  }
}

/// Legacy alias — kept for backward compatibility. Renders a flat M3 surface.
class GlassNavigationBar extends StatelessWidget {
  const GlassNavigationBar({
    super.key,
    required this.child,
    this.blur = 0,
    this.opacity = 0,
    this.borderColor,
  });

  final Widget child;
  final double blur;
  final double opacity;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: cs.surface,
        border: Border(
          top: BorderSide(
            color: borderColor ?? cs.outlineVariant.withOpacity(0.4),
            width: 0.6,
          ),
        ),
      ),
      child: child,
    );
  }
}
