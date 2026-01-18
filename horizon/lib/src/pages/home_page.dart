import 'dart:io';

import 'package:flutter/material.dart';

import '../controllers/horizon_controller.dart';
import '../models/dev_mode_config.dart';
import '../widgets/cards/access_card.dart';
import '../widgets/cards/address_card.dart';
import '../widgets/cards/connection_card.dart';
import '../widgets/cards/dev_mode_card.dart';
import '../widgets/cards/paired_devices_card.dart';
import '../widgets/cards/status_card.dart';
import '../widgets/common/status_dot.dart';
import '../widgets/dialogs/pairing_dialog.dart';

class HorizonHome extends StatefulWidget {
  const HorizonHome({super.key, required this.devModeConfig});

  final DevModeConfig devModeConfig;

  @override
  State<HorizonHome> createState() => _HorizonHomeState();
}

class _HorizonHomeState extends State<HorizonHome> {
  late final HorizonController _controller;
  late final TextEditingController _wormholeUrlController;
  late final TextEditingController _wormholeTokenController;
  late final TextEditingController _customSessionController;
  bool _pairingDialogShown = false;

  @override
  void initState() {
    super.initState();
    _controller = HorizonController(
      devModeRequested: widget.devModeConfig.requested,
      requireDevModeConfirmation: widget.devModeConfig.requiresConfirmation,
    );
    _wormholeUrlController =
        TextEditingController(text: _controller.wormholeBaseUrl);
    _wormholeTokenController =
        TextEditingController(text: _controller.wormholeToken);
    _customSessionController =
        TextEditingController(text: _controller.customSessionId);
    _wormholeUrlController.addListener(_syncWormholeConfig);
    _wormholeTokenController.addListener(_syncWormholeConfig);
    _customSessionController.addListener(_syncCustomSession);
    if (!_controller.requiresDevModeConfirmation) {
      _controller.start();
    }
  }

  @override
  void dispose() {
    _wormholeUrlController.removeListener(_syncWormholeConfig);
    _wormholeTokenController.removeListener(_syncWormholeConfig);
    _customSessionController.removeListener(_syncCustomSession);
    _wormholeUrlController.dispose();
    _wormholeTokenController.dispose();
    _customSessionController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _syncWormholeConfig() {
    _controller.updateWormholeConfig(
      baseUrl: _wormholeUrlController.text,
      token: _wormholeTokenController.text,
    );
  }

  void _syncCustomSession() {
    _controller.setCustomSessionId(_customSessionController.text);
  }

  void _showPairingDialog(PendingPairing pending) {
    if (_pairingDialogShown) return;
    _pairingDialogShown = true;

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (context) => PairingDialog(
        pending: pending,
        onApprove: (remember) {
          Navigator.of(context).pop();
          _pairingDialogShown = false;
          _controller.approvePairing(remember: remember);
        },
        onReject: () {
          Navigator.of(context).pop();
          _pairingDialogShown = false;
          _controller.rejectPairing();
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final pending = _controller.pendingPairing;
        if (pending != null && !_pairingDialogShown) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showPairingDialog(pending);
          });
        }

        return Scaffold(
          appBar: AppBar(
            title: const Text('Horizon'),
            actions: [
              if (_controller.running)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: StatusDot(connected: _controller.running),
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_controller.devModeRequested)
                  DevModeCard(controller: _controller),
                if (_controller.devModeRequested) const SizedBox(height: 16),
                StatusCard(controller: _controller),
                const SizedBox(height: 16),
                ConnectionCard(
                  controller: _controller,
                  wormholeUrlController: _wormholeUrlController,
                  wormholeTokenController: _wormholeTokenController,
                  customSessionController: _customSessionController,
                ),
                if (Platform.isMacOS) ...[
                  const SizedBox(height: 16),
                  AccessCard(controller: _controller),
                ],
                const SizedBox(height: 16),
                AddressCard(controller: _controller),
                if (_controller.wormholeEnabled) ...[
                  const SizedBox(height: 16),
                  PairedDevicesCard(controller: _controller),
                ],
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }
}
