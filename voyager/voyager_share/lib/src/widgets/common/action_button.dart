import 'package:flutter/material.dart';

import '../design_tokens.dart';

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
      bgColor = active ? AppColors.border : AppColors.borderSubtle;
      borderColor =
          active ? AppColors.borderFocus : AppColors.divider;
    } else {
      bgColor = enabled ? AppColors.borderSubtle : AppColors.surfaceDim;
      borderColor =
          enabled ? AppColors.divider : AppColors.border;
    }

    final textColor = modifier
        ? (active ? AppColors.textPrimary : AppColors.textTertiary)
        : (enabled ? AppColors.textPrimary : AppColors.textMuted);

    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: AppDurations.normal,
        padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md, vertical: 10),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(AppRadius.sm),
          border: Border.all(color: borderColor),
          boxShadow: (enabled || modifier)
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.06),
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
