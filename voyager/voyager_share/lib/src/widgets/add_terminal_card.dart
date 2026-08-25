import 'package:flutter/material.dart';

import 'common/focusable_tap_region.dart';
import 'design_tokens.dart';

class AddTerminalCard extends StatelessWidget {
  const AddTerminalCard({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return FocusableTapRegion(
      onTap: onTap,
      semanticLabel: 'New session',
      builder: (context, focused, hovered, pressed) {
        final active = focused || hovered || pressed;

        return AnimatedScale(
          duration: AppDurations.fast,
          scale: focused ? 1.03 : 1,
          child: AnimatedContainer(
            duration: AppDurations.normal,
            decoration: BoxDecoration(
              color: active ? AppColors.surfaceVariant : AppColors.surfaceDim,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: focused ? AppColors.borderFocus : AppColors.border,
                width: focused ? 2 : 1.0,
              ),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  padding: const EdgeInsets.all(AppSpacing.md),
                  decoration: BoxDecoration(
                    color:
                        focused
                            ? AppColors.borderFocus
                            : AppColors.borderSubtle,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.add_rounded,
                    size: 24,
                    color: AppColors.textMuted,
                  ),
                ),
                const SizedBox(height: AppSpacing.md),
                const Text(
                  'NEW SESSION',
                  style: TextStyle(
                    color: AppColors.textMuted,
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
