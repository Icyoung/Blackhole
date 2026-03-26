import 'package:flutter/material.dart';

import '../../app.dart';
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
          _ConfigSection(
            icon: Icons.wifi,
            child: ConfigRow(
              label: 'LAN Connection',
              subtitle: 'Allow direct connections on local network',
              value: controller.lanEnabled,
              onChanged: (v) => controller.setLanEnabled(v),
            ),
          ),
          const SizedBox(height: 8),
          _FadingDivider(),
          const SizedBox(height: 8),
          _ConfigSection(
            icon: Icons.cloud_outlined,
            child: ConfigRow(
              label: 'Wormhole Connection',
              subtitle: 'Enable secure remote access via relay',
              value: controller.wormholeEnabled,
              onChanged: (v) => controller.setWormholeEnabled(v),
            ),
          ),
          AnimatedCrossFade(
            firstChild: const SizedBox.shrink(),
            secondChild: _buildWormholeSettings(),
            crossFadeState: controller.wormholeEnabled
                ? CrossFadeState.showSecond
                : CrossFadeState.showFirst,
            duration: const Duration(milliseconds: 250),
            sizeCurve: Curves.easeInOut,
          ),
        ],
      ),
    );

    if (flat) {
      return content;
    }

    return Card(child: content);
  }

  Widget _buildWormholeSettings() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
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
        const SizedBox(height: 16),
        _FadingDivider(),
        const SizedBox(height: 16),
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
    );
  }
}

class _ConfigSection extends StatelessWidget {
  const _ConfigSection({required this.icon, required this.child});

  final IconData icon;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: HorizonColors.surfaceVariant.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: HorizonColors.borderSubtle),
      ),
      child: Row(
        children: [
          Icon(icon, size: 16, color: HorizonColors.textMuted),
          const SizedBox(width: 12),
          Expanded(child: child),
        ],
      ),
    );
  }
}

class _FadingDivider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.transparent,
            HorizonColors.border,
            HorizonColors.border,
            Colors.transparent,
          ],
          stops: const [0.0, 0.2, 0.8, 1.0],
        ),
      ),
    );
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
                  color: HorizonColors.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: const TextStyle(
                  color: HorizonColors.textTertiary,
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
