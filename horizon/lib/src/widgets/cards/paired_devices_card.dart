import 'package:flutter/material.dart';

import '../../app.dart';
import '../../controllers/horizon_controller.dart';
import '../common/section_title.dart';

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
            const _EmptyDevicesState()
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
                        color: HorizonColors.border,
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

class _EmptyDevicesState extends StatelessWidget {
  const _EmptyDevicesState();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 24),
      width: double.infinity,
      child: Column(
        children: [
          Icon(
            Icons.devices_other,
            size: 32,
            color: HorizonColors.textMuted.withValues(alpha: 0.4),
          ),
          const SizedBox(height: 12),
          const Text(
            'No paired devices',
            style: TextStyle(
              color: HorizonColors.textTertiary,
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'New devices will require approval',
            style: TextStyle(
              color: HorizonColors.textMuted.withValues(alpha: 0.6),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class DeviceListTile extends StatefulWidget {
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
  State<DeviceListTile> createState() => _DeviceListTileState();
}

class _DeviceListTileState extends State<DeviceListTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final lastSeen = _formatLastSeen(widget.device.lastSeenAt);

    final icon = switch (widget.device.deviceType) {
      DeviceType.mobile => Icons.smartphone,
      DeviceType.desktop => Icons.computer,
      DeviceType.web => Icons.language,
      DeviceType.unknown => Icons.devices,
    };

    final iconColor = switch (widget.device.deviceType) {
      DeviceType.mobile => HorizonColors.textTertiary,
      DeviceType.desktop => HorizonColors.accent,
      DeviceType.web => HorizonColors.textMuted,
      DeviceType.unknown => HorizonColors.textMuted,
    };

    final row = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: widget.flat
            ? EdgeInsets.zero
            : const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: widget.flat
            ? null
            : BoxDecoration(
                color: _hovered
                    ? HorizonColors.surfaceBright
                    : HorizonColors.surfaceVariant,
                borderRadius: BorderRadius.circular(6),
                border:
                    Border.all(color: HorizonColors.borderSubtle),
              ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 16, color: iconColor),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.device.deviceName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: HorizonColors.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'Last seen: $lastSeen',
                    style: const TextStyle(
                      color: HorizonColors.textTertiary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            AnimatedOpacity(
              opacity: _hovered || widget.flat ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 180),
              child: IconButton(
                icon: const Icon(Icons.delete_outline,
                    size: 18, color: HorizonColors.error),
                onPressed: widget.onRemove,
                tooltip: 'Remove device',
              ),
            ),
          ],
        ),
      ),
    );

    return row;
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
