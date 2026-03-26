import 'package:flutter/material.dart';

import '../../app.dart';
import '../../controllers/horizon_controller.dart';

class DevModeCard extends StatelessWidget {
  const DevModeCard({
    super.key,
    required this.controller,
    this.flat = false,
  });

  final HorizonController controller;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    const warningColor = HorizonColors.warning;
    final contentPadding = flat
        ? const EdgeInsets.symmetric(vertical: 20)
        : const EdgeInsets.all(20);

    final content = Padding(
      padding: contentPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.warning_amber_rounded, color: warningColor, size: 20),
              const SizedBox(width: 10),
              Text(
                controller.requiresDevModeConfirmation
                    ? 'DEV MODE CONFIRMATION'
                    : 'DEVELOPMENT MODE ACTIVE',
                style: TextStyle(
                  color: warningColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Text(
            controller.requiresDevModeConfirmation
                ? 'Development mode is requested for this release build. This disables authentication on the LAN.'
                : 'Authentication is disabled. Any device on the same network can control this terminal.',
            style: const TextStyle(color: HorizonColors.textSecondary, fontSize: 13),
          ),
          if (controller.requiresDevModeConfirmation) ...[
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: controller.confirmDevMode,
                style: FilledButton.styleFrom(
                  backgroundColor: warningColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8)),
                ),
                child: const Text('Enable Dev Mode'),
              ),
            ),
          ],
        ],
      ),
    );

    if (flat) {
      return content;
    }

    return Card(
      color: warningColor.withValues(alpha: 0.05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: warningColor.withValues(alpha: 0.2)),
      ),
      child: content,
    );
  }
}
