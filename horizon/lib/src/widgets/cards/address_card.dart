import 'package:flutter/material.dart';

import '../../app.dart';
import '../../controllers/horizon_controller.dart';
import '../common/section_title.dart';
import '../common/status_message.dart';

class AddressCard extends StatelessWidget {
  const AddressCard({
    super.key,
    required this.controller,
    this.flat = false,
  });

  final HorizonController controller;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final addresses = controller.addresses;
    final contentPadding = flat
        ? const EdgeInsets.symmetric(vertical: 20)
        : const EdgeInsets.all(20);

    final content = Padding(
      padding: contentPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(title: 'URL Access', icon: Icons.lan_outlined),
          const SizedBox(height: 16),
          if (!controller.lanEnabled)
            const StatusMessage(
                message: 'LAN is disabled in connection modes.', isError: false)
          else if (addresses.isEmpty)
            const StatusMessage(
                message: 'No LAN IPv4 addresses detected.', isError: true)
          else
            ...addresses.map(
              (addr) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: HorizonColors.surfaceVariant,
                    borderRadius: BorderRadius.circular(6),
                    border:
                        Border.all(color: HorizonColors.border),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.link,
                          size: 14, color: HorizonColors.textTertiary),
                      const SizedBox(width: 10),
                      Text(
                        'ws://$addr:${controller.port}',
                        style: const TextStyle(
                          fontFamily: 'Menlo',
                          fontSize: 13,
                          color: HorizonColors.success,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (flat) {
      return content;
    }

    return Card(child: content);
  }
}
