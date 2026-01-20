import 'package:flutter/material.dart';

import '../controllers/horizon_controller.dart';
import 'cards/connection_card.dart';
import 'cards/dev_mode_card.dart';
import 'cards/paired_devices_card.dart';
import 'cards/status_card.dart';

class HorizonAdvancedPanel extends StatelessWidget {
  const HorizonAdvancedPanel({
    super.key,
    required this.controller,
    required this.wormholeUrlController,
    required this.wormholeTokenController,
    required this.customSessionController,
  });

  final HorizonController controller;
  final TextEditingController wormholeUrlController;
  final TextEditingController wormholeTokenController;
  final TextEditingController customSessionController;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (controller.devModeRequested)
          DevModeCard(controller: controller, flat: true),
        if (controller.devModeRequested) const SizedBox(height: 16),
        StatusCard(controller: controller, flat: true),
        const SizedBox(height: 16),
        ConnectionCard(
          controller: controller,
          wormholeUrlController: wormholeUrlController,
          wormholeTokenController: wormholeTokenController,
          customSessionController: customSessionController,
          flat: true,
        ),
        if (controller.wormholeEnabled) ...[
          const SizedBox(height: 16),
          PairedDevicesCard(controller: controller, flat: true),
        ],
      ],
    );
  }
}
