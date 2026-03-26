import 'package:flutter/material.dart';

import '../design_tokens.dart';

class StatusDot extends StatelessWidget {
  const StatusDot({
    super.key,
    required this.connected,
    this.size = 10,
    this.overrideColor,
  });

  final bool connected;
  final double size;
  final Color? overrideColor;

  static const green = AppColors.statusGreen;
  static const yellow = AppColors.statusYellow;
  static const red = AppColors.statusRed;

  @override
  Widget build(BuildContext context) {
    final color = overrideColor ?? (connected ? green : red);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withValues(alpha: 0.4),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}
