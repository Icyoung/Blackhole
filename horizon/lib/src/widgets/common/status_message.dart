import 'package:flutter/material.dart';

import '../../app.dart';

class StatusMessage extends StatelessWidget {
  const StatusMessage(
      {super.key, required this.message, required this.isError});

  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final statusColor =
        isError ? HorizonColors.error : HorizonColors.textTertiary;

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: statusColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
        border: Border(
          left: BorderSide(color: statusColor.withValues(alpha: 0.6), width: 3),
        ),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.warning_amber_rounded : Icons.info_outline,
            size: 18,
            color: statusColor,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: statusColor, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}
