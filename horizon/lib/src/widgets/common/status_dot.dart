import 'package:flutter/material.dart';

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.connected, this.size = 10});

  final bool connected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final color = connected ? const Color(0xFF41C87A) : const Color(0xFFFF5C5C);
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
