import 'package:flutter/material.dart';
import 'package:liquid_glass/liquid_glass.dart';

class AppLiquidGlass extends StatelessWidget {
  const AppLiquidGlass({
    super.key,
    required this.child,
    this.padding,
    this.blur = 40,
    this.opacity = 0.2,
    this.borderRadius = const BorderRadius.all(Radius.circular(28)),
    this.tint,
    this.elevation = 18,
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
    final baseTint = tint ?? cs.surface;
    final glassTint = Color.lerp(
      baseTint,
      Colors.white,
      lightenAmount ?? (isDark ? 0.18 : 0.58),
    )!;

    final decorated = Container(
      decoration: BoxDecoration(
        borderRadius: borderRadius,
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.18 : 0.06),
            blurRadius: elevation,
            offset: Offset(0, elevation * 0.35),
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: isDark ? 0.015 : 0.08),
            blurRadius: elevation * 0.4,
            offset: const Offset(0, 1),
          ),
        ],
        border: Border.all(
          color:
              isDark
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.white.withValues(alpha: 0.36),
        ),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            glassTint.withValues(alpha: isDark ? 0.20 : 0.18),
            glassTint.withValues(alpha: isDark ? 0.12 : 0.10),
          ],
        ),
      ),
      foregroundDecoration: BoxDecoration(
        borderRadius: borderRadius,
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            Color.fromARGB(34, 255, 255, 255),
            Color.fromARGB(8, 255, 255, 255),
            Color.fromARGB(0, 255, 255, 255),
          ],
          stops: [0, 0.28, 0.85],
        ),
      ),
      child: Padding(
        padding: padding ?? EdgeInsets.zero,
        child: child,
      ),
    );

    if (!liveBlur) return decorated;

    return RepaintBoundary(
      child: LiquidGlass(
        blur: blur,
        opacity: isDark ? opacity + 0.03 : opacity + 0.015,
        borderRadius: borderRadius,
        tint: glassTint,
        child: decorated,
      ),
    );
  }
}

class AppLiquidGlassPill extends StatelessWidget {
  const AppLiquidGlassPill({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
    this.blur = 32,
    this.opacity = 0.18,
    this.tint,
    this.elevation = 10,
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
      blur: blur,
      opacity: opacity,
      borderRadius: const BorderRadius.all(Radius.circular(999)),
      tint: tint,
      elevation: elevation,
      liveBlur: liveBlur,
      lightenAmount: lightenAmount,
      padding: padding,
      child: child,
    );
  }
}

/// A custom glass widget that provides glass morphism effects
class GlassWidget extends StatelessWidget {
  const GlassWidget({
    super.key,
    required this.child,
    this.blur = 20.0,
    this.opacity = 0.1,
    this.borderRadius = 16.0,
    this.borderColor,
    this.borderWidth = 1.0,
  });

  final Widget child;
  final double blur;
  final double opacity;
  final double borderRadius;
  final Color? borderColor;
  final double borderWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    return AppLiquidGlass(
      blur: blur,
      opacity: opacity,
      borderRadius: BorderRadius.circular(borderRadius),
      tint: colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(borderRadius),
          border: Border.all(
            color: borderColor ?? colorScheme.outline.withOpacity(0.2),
            width: borderWidth,
          ),
          boxShadow: [
            BoxShadow(
              color: colorScheme.shadow.withOpacity(0.1),
              blurRadius: 10,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: child,
      ),
    );
  }
}

/// A glass container with enhanced visual effects
class GlassContainer extends StatelessWidget {
  const GlassContainer({
    super.key,
    required this.child,
    this.blur = 15.0,
    this.opacity = 0.15,
    this.borderRadius = 20.0,
    this.gradient,
    this.borderColor,
    this.borderWidth = 0.5,
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
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(borderRadius),
        boxShadow: elevation > 0 ? [
          BoxShadow(
            color: colorScheme.shadow.withOpacity(0.1),
            blurRadius: elevation * 2,
            offset: Offset(0, elevation),
          ),
        ] : null,
      ),
      child: AppLiquidGlass(
        blur: blur,
        opacity: opacity,
        borderRadius: BorderRadius.circular(borderRadius),
        tint: colorScheme.surface,
        child: DecoratedBox(
          decoration: BoxDecoration(
            gradient: gradient ?? LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [
                colorScheme.surface.withOpacity(opacity),
                colorScheme.surface.withOpacity(opacity * 0.8),
              ],
            ),
            borderRadius: BorderRadius.circular(borderRadius),
            border: Border.all(
              color: borderColor ?? colorScheme.outline.withOpacity(0.15),
              width: borderWidth,
            ),
          ),
          child: child,
        ),
      ),
    );
  }
}

/// A glass navigation bar specifically designed for iOS-style navigation
class GlassNavigationBar extends StatelessWidget {
  const GlassNavigationBar({
    super.key,
    required this.child,
    this.blur = 25.0,
    this.opacity = 0.8,
    this.borderColor,
  });

  final Widget child;
  final double blur;
  final double opacity;
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;

    return AppLiquidGlass(
      blur: blur,
      opacity: opacity,
      borderRadius: BorderRadius.zero,
      tint: colorScheme.surface,
      child: DecoratedBox(
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(
              color: borderColor ?? colorScheme.outline.withOpacity(0.1),
              width: 0.5,
            ),
          ),
        ),
        child: child,
      ),
    );
  }
}
