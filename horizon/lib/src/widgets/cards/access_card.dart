import 'package:flutter/material.dart';

import '../../controllers/horizon_controller.dart';
import '../common/section_title.dart';

class AccessCard extends StatelessWidget {
  const AccessCard({super.key, required this.controller});

  final HorizonController controller;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SectionTitle(
                title: 'Filesystem', icon: Icons.folder_open_outlined),
            const SizedBox(height: 12),
            const Text(
              'Grant access to your home folder so Voyager can browse and manage files.',
              style: TextStyle(color: Color(0xFF9AA6B2), fontSize: 13),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                ElevatedButton.icon(
                  onPressed: controller.requestFolderAccess,
                  icon: const Icon(Icons.add_moderator_outlined, size: 18),
                  label: const Text('Grant Access'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF284058),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                if (controller.accessMessage != null) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      controller.accessMessage!,
                      style: const TextStyle(
                          color: Color(0xFF41C87A), fontSize: 13),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}
