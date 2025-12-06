import 'package:flutter/material.dart';

import 'full_player_overlay.dart';
import 'full_player_page.dart';

/// Persistent host that keeps the full player alive in the widget tree and
/// simply animates it on/off-screen. This removes the overhead of repeatedly
/// creating/destroying a bottom sheet.
class FullPlayerHost extends StatelessWidget {
  const FullPlayerHost({super.key});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    const duration = Duration(milliseconds: 260);

    return ValueListenableBuilder<bool>(
      valueListenable: FullPlayerOverlay.isVisible,
      builder: (_, visible, __) {
        return IgnorePointer(
          ignoring: !visible,
          child: AnimatedSlide(
            duration: duration,
            curve: visible ? Curves.easeOutCubic : Curves.easeInCubic,
            offset: visible ? Offset.zero : const Offset(0, 1.0),
            child: AnimatedOpacity(
              duration: duration,
              curve: Curves.easeInOut,
              opacity: visible ? 1.0 : 0.0,
              child: Align(
                alignment: Alignment.bottomCenter,
                child: FractionallySizedBox(
                  heightFactor: 0.95,
                  widthFactor: 1.0,
                  child: ClipRRect(
                    borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
                    child: ColoredBox(
                      color: cs.surface,
                      child: const RepaintBoundary(
                        child: FullPlayerPage(),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

