import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app.dart';
import '../../controllers/horizon_controller.dart';
import '../common/status_dot.dart';

class StatusCard extends StatelessWidget {
  const StatusCard({
    super.key,
    required this.controller,
    this.flat = false,
  });

  final HorizonController controller;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final statusText = controller.running ? 'Running' : 'Stopped';
    final canStart = !controller.requiresDevModeConfirmation;
    final sessionId = controller.wormholeSessionId;
    final showSession = controller.wormholeEnabled && controller.running;
    final contentPadding = flat
        ? const EdgeInsets.symmetric(vertical: 20)
        : const EdgeInsets.all(20);

    final content = Container(
      decoration: controller.running
          ? BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  HorizonColors.accent.withValues(alpha: 0.03),
                  Colors.transparent,
                ],
              ),
              border: flat
                  ? null
                  : const Border(
                      top: BorderSide(
                        color: HorizonColors.accent,
                        width: 2,
                      ),
                    ),
            )
          : null,
      child: Padding(
        padding: contentPadding,
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
                _InfoChip(label: 'Port', value: '${controller.port}'),
                const SizedBox(width: 12),
                _InfoChip(
                    label: 'Connections',
                    value: '${controller.clientCount}'),
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
                  color: HorizonColors.error.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: HorizonColors.error.withValues(alpha: 0.2),
                  ),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline,
                        size: 16, color: HorizonColors.error),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        controller.error!,
                        style: const TextStyle(
                            color: HorizonColors.error, fontSize: 13),
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

    if (flat) {
      return content;
    }

    return Card(
      clipBehavior: Clip.antiAlias,
      child: content,
    );
  }
}

class _InfoChip extends StatelessWidget {
  const _InfoChip({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: HorizonColors.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label.toUpperCase(),
            style: const TextStyle(
              color: HorizonColors.textTertiary,
              fontSize: 10,
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
      ),
    );
  }
}

class SessionIdDisplay extends StatefulWidget {
  const SessionIdDisplay({super.key, required this.sessionId});

  final String? sessionId;

  @override
  State<SessionIdDisplay> createState() => _SessionIdDisplayState();
}

class _SessionIdDisplayState extends State<SessionIdDisplay> {
  bool _copied = false;

  void _copySessionId(String id) {
    Clipboard.setData(ClipboardData(text: id));
    setState(() => _copied = true);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final id = widget.sessionId;
    final hasId = id != null && id.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF2D2E30),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: HorizonColors.border),
      ),
      child: Row(
        children: [
          const Icon(Icons.vpn_key_outlined,
              size: 18, color: HorizonColors.textMuted),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'WORMHOLE SESSION',
                  style: TextStyle(
                    color: HorizonColors.textTertiary,
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
                    fontSize: 22,
                    color: Colors.white,
                    letterSpacing: 4.0,
                  ),
                ),
              ],
            ),
          ),
          if (hasId)
            IconButton(
              icon: AnimatedSwitcher(
                duration: const Duration(milliseconds: 200),
                child: _copied
                    ? const Icon(Icons.check,
                        key: ValueKey('check'),
                        size: 20,
                        color: HorizonColors.accent)
                    : const Icon(Icons.copy,
                        key: ValueKey('copy'),
                        size: 20,
                        color: HorizonColors.textTertiary),
              ),
              onPressed: () => _copySessionId(id),
            ),
        ],
      ),
    );
  }
}
