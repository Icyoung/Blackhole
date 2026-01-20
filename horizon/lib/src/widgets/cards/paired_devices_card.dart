import 'package:flutter/material.dart';

import '../../controllers/horizon_controller.dart';
import '../common/section_title.dart';
import '../common/status_message.dart';

class PairedDevicesCard extends StatelessWidget {
  const PairedDevicesCard({
    super.key,
    required this.controller,
    this.flat = false,
    this.showHeader = true,
  });

  final HorizonController controller;
  final bool flat;
  final bool showHeader;

  @override
  Widget build(BuildContext context) {
    final devices = controller.pairedDevices;
    final contentPadding = flat ? EdgeInsets.zero : const EdgeInsets.all(20);

    final content = Padding(
      padding: contentPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeader) ...[
            const SectionTitle(
                title: 'Paired Devices', icon: Icons.devices_outlined),
            const SizedBox(height: 16),
          ],
          if (devices.isEmpty)
            const StatusMessage(
              message: 'No paired devices. New devices will require approval.',
              isError: false,
            )
          else
            ...devices.asMap().entries.map((entry) {
              final index = entry.key;
              final device = entry.value;
              final isLast = index == devices.length - 1;
              return Column(
                children: [
                  DeviceListTile(
                    device: device,
                    onRemove: () =>
                        controller.removePairedDevice(device.deviceKey),
                    flat: flat,
                  ),
                  if (!isLast)
                    Padding(
                      padding: EdgeInsets.only(
                        top: flat ? 12 : 8,
                        bottom: flat ? 12 : 0,
                      ),
                      child: Divider(
                        height: 1,
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                ],
              );
            }),
        ],
      ),
    );

    if (flat) {
      return content;
    }

    return Card(child: content);
  }
}

class DeviceListTile extends StatelessWidget {
  const DeviceListTile({
    super.key,
    required this.device,
    required this.onRemove,
    this.flat = false,
  });

  final PairedDevice device;
  final VoidCallback onRemove;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final lastSeen = _formatLastSeen(device.lastSeenAt);

    final icon = switch (device.deviceType) {
      DeviceType.mobile => Icons.smartphone,
      DeviceType.desktop => Icons.computer,
      DeviceType.web => Icons.language,
      DeviceType.unknown => Icons.devices,
    };

    final row = Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF4B7AA6)),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                device.deviceName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                'Last seen: $lastSeen',
                style: const TextStyle(
                  color: Color(0xFF9AA6B2),
                  fontSize: 11,
                ),
              ),
            ],
          ),
        ),
        IconButton(
          icon:
              const Icon(Icons.delete_outline, size: 18, color: Color(0xFFFF5C5C)),
          onPressed: onRemove,
          tooltip: 'Remove device',
        ),
      ],
    );

    if (flat) {
      return row;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: row,
    );
  }

  String _formatLastSeen(DateTime lastSeen) {
    final now = DateTime.now();
    final diff = now.difference(lastSeen);

    if (diff.inMinutes < 1) {
      return 'Just now';
    } else if (diff.inHours < 1) {
      return '${diff.inMinutes}m ago';
    } else if (diff.inDays < 1) {
      return '${diff.inHours}h ago';
    } else {
      return '${diff.inDays}d ago';
    }
  }
}
