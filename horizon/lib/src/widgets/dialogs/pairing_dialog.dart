import 'package:flutter/material.dart';

import '../../controllers/horizon_controller.dart';

class PairingDialog extends StatelessWidget {
  const PairingDialog({
    super.key,
    required this.pending,
    required this.onApprove,
    required this.onReject,
  });

  final PendingPairing pending;
  final void Function(bool remember) onApprove;
  final VoidCallback onReject;

  @override
  Widget build(BuildContext context) {
    final accentColor = const Color(0xFF4B7AA6);
    final errorColor = const Color(0xFFFF5C5C);

    return Dialog(
      backgroundColor: const Color(0xFF111620),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Container(
        width: 320,
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Icon(Icons.phonelink, color: accentColor, size: 20),
                ),
                const SizedBox(width: 12),
                const Text(
                  'Connection Request',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.smartphone,
                      size: 16, color: Color(0xFF9AA6B2)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      pending.deviceName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                        fontFamily: 'Menlo',
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'A new device is attempting to pair with this Horizon instance. Do you want to grant access?',
              style: TextStyle(color: Color(0xFF9AA6B2), fontSize: 13, height: 1.5),
            ),
            const SizedBox(height: 24),
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                FilledButton(
                  onPressed: () => onApprove(true),
                  style: FilledButton.styleFrom(
                    backgroundColor: accentColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Approve & Remember',
                      style: TextStyle(fontWeight: FontWeight.bold)),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => onApprove(false),
                        style: OutlinedButton.styleFrom(
                          side:
                              BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Allow Once'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: TextButton(
                        onPressed: onReject,
                        style: TextButton.styleFrom(
                          foregroundColor: errorColor,
                          padding: const EdgeInsets.symmetric(vertical: 14),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8)),
                        ),
                        child: const Text('Reject'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
