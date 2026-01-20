import 'package:flutter/material.dart';

import '../../controllers/horizon_controller.dart';
import '../common/section_title.dart';
import '../common/styled_text_field.dart';

class ConnectionCard extends StatelessWidget {
  const ConnectionCard({
    super.key,
    required this.controller,
    required this.wormholeUrlController,
    required this.wormholeTokenController,
    required this.customSessionController,
    this.flat = false,
  });

  final HorizonController controller;
  final TextEditingController wormholeUrlController;
  final TextEditingController wormholeTokenController;
  final TextEditingController customSessionController;
  final bool flat;

  @override
  Widget build(BuildContext context) {
    final contentPadding = flat
        ? const EdgeInsets.symmetric(vertical: 20)
        : const EdgeInsets.all(20);
    final content = Padding(
      padding: contentPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(
            title: 'Connection Modes',
            icon: Icons.settings_input_component_outlined,
          ),
          const SizedBox(height: 12),
          ConfigRow(
            label: 'LAN Connection',
            subtitle: 'Allow direct connections on local network',
            value: controller.lanEnabled,
            onChanged: (v) => controller.setLanEnabled(v),
          ),
          const Divider(height: 24, color: Colors.white10),
          ConfigRow(
            label: 'Wormhole Connection',
            subtitle: 'Enable secure remote access via relay',
            value: controller.wormholeEnabled,
            onChanged: (v) => controller.setWormholeEnabled(v),
          ),
          if (controller.wormholeEnabled) ...[
            const SizedBox(height: 24),
            const SectionTitle(
              title: 'Wormhole Settings',
              icon: Icons.hub_outlined,
            ),
            const SizedBox(height: 16),
            StyledTextField(
              controller: wormholeUrlController,
              label: 'Base URL',
              hint: 'wss://wormhole.example.com',
            ),
            const SizedBox(height: 16),
            StyledTextField(
              controller: wormholeTokenController,
              label: 'Access Token',
              hint: 'Optional authentication token',
              isPassword: true,
            ),
            const Divider(height: 32, color: Colors.white10),
            ConfigRow(
              label: 'Custom Session ID',
              subtitle: 'Use a fixed 6-character code (requires token)',
              value: controller.customSessionEnabled,
              onChanged: (v) => controller.setCustomSessionEnabled(v),
            ),
            if (controller.customSessionEnabled) ...[
              const SizedBox(height: 16),
              StyledTextField(
                controller: customSessionController,
                label: 'Session ID',
                hint: 'e.g., ABC123',
                maxLength: 6,
                textCapitalization: TextCapitalization.characters,
              ),
            ],
          ],
        ],
      ),
    );

    if (flat) {
      return content;
    }

    return Card(child: content);
  }
}

class ConfigRow extends StatelessWidget {
  const ConfigRow({
    super.key,
    required this.label,
    required this.subtitle,
    required this.value,
    required this.onChanged,
  });

  final String label;
  final String subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  color: Color(0xFF9AA6B2),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        Switch(value: value, onChanged: onChanged),
      ],
    );
  }
}
