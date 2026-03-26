import 'package:flutter/material.dart';

import '../../app.dart';
import '../../controllers/horizon_controller.dart';
import '../common/section_title.dart';

class AccessCard extends StatelessWidget {
  const AccessCard({
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
    final contentPadding = flat ? EdgeInsets.zero : const EdgeInsets.all(20);
    final content = Padding(
      padding: contentPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showHeader) ...[
            const SectionTitle(
                title: 'File Access', icon: Icons.folder_open_outlined),
            const SizedBox(height: 12),
          ],
          const Text(
            'Grant access to your home folder so Voyager can browse and manage files.',
            style: TextStyle(color: HorizonColors.textTertiary, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: controller.requestFolderAccess,
                icon: const Icon(Icons.add_moderator_outlined, size: 18),
                label: const Text('Grant Access'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: HorizonColors.accent,
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
                        color: HorizonColors.success, fontSize: 13),
                  ),
                ),
              ],
            ],
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
