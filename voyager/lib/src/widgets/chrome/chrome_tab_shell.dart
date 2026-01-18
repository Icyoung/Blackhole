import 'package:flutter/material.dart';

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
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.translucent,
      child: ClipPath(
        clipper: inverted ? TabClipperInverted() : TabClipper(),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color),
          child: DecoratedBox(
            decoration: BoxDecoration(color: overlayColor),
            child: child,
          ),
        ),
      ),
    );
  }
}
