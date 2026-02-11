import 'package:flutter/material.dart';

import 'chrome_tab_shell.dart';

class ChromeTabButton extends StatelessWidget {
  const ChromeTabButton({
    super.key,
    required this.onTap,
    required this.color,
    required this.icon,
    required this.overlayColor,
    this.inverted = false,
  });

  final VoidCallback onTap;
  final Color color;
  final IconData icon;
  final Color overlayColor;
  final bool inverted;

  @override
  Widget build(BuildContext context) {
    return ChromeTabShell(
      onTap: onTap,
      color: color,
      overlayColor: overlayColor,
      inverted: inverted,
      child: SizedBox(
        width: 48,
        height: 28,
        child: Center(
          child: Icon(
            icon,
            color: Colors.white,
            size: 16,
          ),
        ),
      ),
    );
  }
}
