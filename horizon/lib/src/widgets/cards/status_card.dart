import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../controllers/horizon_controller.dart';
import '../common/status_dot.dart';

class StatusCard extends StatelessWidget {
  const StatusCard({super.key, required this.controller});

  final HorizonController controller;

  @override
  Widget build(BuildContext context) {
    final statusText = controller.running ? 'Running' : 'Stopped';
    final canStart = !controller.requiresDevModeConfirmation;
    final sessionId = controller.wormholeSessionId;
    final showSession = controller.wormholeEnabled && controller.running;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                StatusDot(connected: controller.running),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    statusText,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                Switch(
                  value: controller.running,
                  onChanged: (value) {
                    if (value) {
                      if (canStart) controller.start();
                    } else {
                      controller.stop();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                InfoItem(label: 'Port', value: '${controller.port}'),
                const SizedBox(width: 24),
                InfoItem(label: 'Clients', value: '${controller.clientCount}'),
              ],
            ),
            if (showSession) ...[
              const SizedBox(height: 20),
              SessionIdDisplay(sessionId: sessionId),
            ],
            if (controller.error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF5C5C).withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: const Color(0xFFFF5C5C).withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        size: 16, color: Color(0xFFFF5C5C)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        controller.error!,
                        style: const TextStyle(
                            color: Color(0xFFFF5C5C), fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class InfoItem extends StatelessWidget {
  const InfoItem({super.key, required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF9AA6B2),
            fontSize: 11,
            letterSpacing: 0.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class SessionIdDisplay extends StatelessWidget {
  const SessionIdDisplay({super.key, required this.sessionId});

  final String? sessionId;

  @override
  Widget build(BuildContext context) {
    final id = sessionId;
    final hasId = id != null && id.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2A3A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
      ),
      child: Row(
        children: [
          const Icon(Icons.vpn_key_outlined,
              size: 18, color: Color(0xFF4B7AA6)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'WORMHOLE SESSION',
                  style: TextStyle(
                    color: Color(0xFF9AA6B2),
                    fontSize: 10,
                    letterSpacing: 0.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasId ? id : 'Connecting...',
                  style: const TextStyle(
                    fontFamily: 'Menlo',
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: Colors.white,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
          if (hasId)
            IconButton(
              icon: const Icon(Icons.copy,
                  size: 20, color: Color(0xFF9AA6B2)),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: id));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Session ID copied'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}
