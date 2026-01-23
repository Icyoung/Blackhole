import 'package:flutter/material.dart';

class ActionButton extends StatelessWidget {
  const ActionButton({
    super.key,
    this.label,
    this.icon,
    this.onTap,
    this.modifier = false,
    this.active = false,
  });

  final String? label;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool modifier;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;

    Color bgColor;
    Color borderColor;

    if (modifier) {
      bgColor = active ? const Color(0xFF284058) : const Color(0xFF141B24);
      borderColor =
          active ? const Color(0xFF4B7AA6) : const Color(0xFF223042);
    } else {
      bgColor = enabled ? const Color(0xFF1B2430) : const Color(0xFF0E131A);
      borderColor =
          enabled ? const Color(0xFF2E3A4A) : const Color(0xFF1A222D);
    }

    final textColor = modifier
        ? (active ? Colors.white : const Color(0xFF9AA6B2))
        : (enabled ? Colors.white : const Color(0xFF6D7785));

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: borderColor),
          boxShadow: (enabled || modifier)
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.2),
                    blurRadius: 4,
                    offset: const Offset(0, 2),
                  )
                ]
              : null,
        ),
        child: icon != null
            ? Icon(icon, size: 16, color: textColor)
            : Text(
                label ?? '',
                style: TextStyle(
                  color: textColor,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
      ),
    );
  }
}
