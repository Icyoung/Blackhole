import 'package:flutter/material.dart';

import '../common/focusable_tap_region.dart';
import '../design_tokens.dart';
import 'tab_clipper.dart';

class ChromeTabShell extends StatelessWidget {
  const ChromeTabShell({
    super.key,
    required this.onTap,
    required this.color,
    required this.overlayColor,
    required this.child,
    this.inverted = false,
  });

  final VoidCallback onTap;
  final Color color;
  final Color overlayColor;
  final Widget child;
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    return FocusableTapRegion(
      onTap: onTap,
      builder: (context, focused, hovered, pressed) {
        final focusOverlay =
            focused
                ? AppColors.borderFocus.withValues(alpha: 0.18)
                : hovered || pressed
                ? AppColors.textPrimary.withValues(alpha: 0.06)
                : Colors.transparent;

        return AnimatedScale(
          duration: AppDurations.fast,
          scale: focused ? 1.02 : 1,
          child: ClipPath(
            clipper: inverted ? TabClipperInverted() : TabClipper(),
            child: DecoratedBox(
              decoration: BoxDecoration(color: color),
              child: DecoratedBox(
                decoration: BoxDecoration(color: overlayColor),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: focusOverlay),
                  child: child,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
