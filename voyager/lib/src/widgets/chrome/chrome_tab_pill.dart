import 'package:flutter/material.dart';

import 'chrome_tab_shell.dart';

class ChromeTabPill extends StatelessWidget {
  const ChromeTabPill({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
    required this.onClose,
    required this.color,
    required this.overlayColor,
    required this.width,
  });

  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;
  final Color color;
  final Color overlayColor;
  final double width;

  @override
  Widget build(BuildContext context) {
    final textColor = active ? Colors.white : Colors.white38;

    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: ChromeTabShell(
        onTap: onTap,
        color: active ? color : Colors.transparent,
        overlayColor: active ? overlayColor : Colors.transparent,
        inverted: true,
        child: Container(
          width: width,
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 17),
          decoration: active
              ? BoxDecoration(
                  border: Border(
                    top: BorderSide(
                      color: Colors.white.withValues(alpha: 0.1),
                      width: 1,
                    ),
                  ),
                )
              : null,
          child: Row(
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: textColor,
                    fontSize: 10,
                    fontWeight: active ? FontWeight.bold : FontWeight.normal,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
              if (active)
                GestureDetector(
                  onTap: onClose,
                  child: Container(
                    padding: const EdgeInsets.all(2),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.close,
                        size: 10, color: Colors.white70),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
