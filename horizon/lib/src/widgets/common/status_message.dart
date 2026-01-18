import 'package:flutter/material.dart';

class StatusMessage extends StatelessWidget {
  const StatusMessage({super.key, required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (isError ? const Color(0xFFFF5C5C) : const Color(0xFF9AA6B2))
            .withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.warning_amber_rounded : Icons.info_outline,
            size: 16,
            color: isError ? const Color(0xFFFF5C5C) : const Color(0xFF9AA6B2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color:
                    isError ? const Color(0xFFFF5C5C) : const Color(0xFF9AA6B2),
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
