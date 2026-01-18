import 'package:flutter/material.dart';

import '../../controllers/horizon_controller.dart';
import '../common/section_title.dart';
import '../common/status_message.dart';

class PairedDevicesCard extends StatelessWidget {
  const PairedDevicesCard({super.key, required this.controller});

  final HorizonController controller;

  @override
  Widget build(BuildContext context) {
    final devices = controller.pairedDevices;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle(title: 'Paired Devices', icon: Icons.devices_outlined),
            const SizedBox(height: 16),
            if (devices.isEmpty)
              const StatusMessage(
                message: 'No paired devices. New devices will require approval.',
                isError: false,
              )
            else
              ...devices.map(
                (device) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: DeviceListTile(
                    device: device,
                    onRemove: () =>
                        controller.removePairedDevice(device.deviceKey),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class DeviceListTile extends StatelessWidget {
  const DeviceListTile({super.key, required this.device, required this.onRemove});

  final PairedDevice device;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final lastSeen = _formatLastSeen(device.lastSeenAt);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          const Icon(Icons.smartphone, size: 18, color: Color(0xFF4B7AA6)),
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
      ),
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
