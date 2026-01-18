import 'package:flutter/material.dart';

import '../../controllers/horizon_controller.dart';
import '../common/section_title.dart';
import '../common/status_message.dart';

class AddressCard extends StatelessWidget {
  const AddressCard({super.key, required this.controller});

  final HorizonController controller;

  @override
  Widget build(BuildContext context) {
    final addresses = controller.addresses;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle(title: 'LAN Access', icon: Icons.lan_outlined),
            const SizedBox(height: 16),
            if (!controller.lanEnabled)
              const StatusMessage(
                  message: 'LAN is disabled in connection modes.',
                  isError: false)
            else if (addresses.isEmpty)
              const StatusMessage(
                  message: 'No LAN IPv4 addresses detected.', isError: true)
            else
              ...addresses.map(
                (addr) => Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                          color: Colors.white.withValues(alpha: 0.05)),
                    ),
                    child: Row(
                      children: [
                        const Icon(Icons.link,
                            size: 14, color: Color(0xFF9AA6B2)),
                        const SizedBox(width: 10),
                        Text(
                          'ws://$addr:${controller.port}',
                          style: const TextStyle(
                            fontFamily: 'Menlo',
                            fontSize: 13,
                            color: Color(0xFF41C87A),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
