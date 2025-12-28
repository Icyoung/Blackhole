import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/horizon_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final devMode = _resolveDevMode();
  runApp(HorizonApp(devModeConfig: devMode));
}

DevModeConfig _resolveDevMode() {
  final envEnabled = Platform.environment['BLACKHOLE_DEV'] == '1';
  final argsEnabled = Platform.executableArguments.contains('--dev-mode');
  final requested = envEnabled || argsEnabled;
  final requiresConfirmation = kReleaseMode && requested;
  return DevModeConfig(
    requested: requested,
    requiresConfirmation: requiresConfirmation,
  );
}

class DevModeConfig {
  const DevModeConfig({
    required this.requested,
    required this.requiresConfirmation,
  });

  final bool requested;
  final bool requiresConfirmation;
}

class HorizonApp extends StatelessWidget {
  const HorizonApp({super.key, required this.devModeConfig});

  final DevModeConfig devModeConfig;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Blackhole Horizon',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F141B),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A2A3A),
          brightness: Brightness.dark,
          surface: const Color(0xFF111620),
        ),
        cardTheme: CardTheme(
          color: const Color(0xFF111620),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: Colors.white.withOpacity(0.05),
              width: 1,
            ),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0F141B),
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        useMaterial3: true,
      ),
      home: HorizonHome(devModeConfig: devModeConfig),
    );
  }
}

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
    _wormholeUrlController.addListener(_syncWormholeConfig);
    _wormholeTokenController.addListener(_syncWormholeConfig);
    if (!_controller.requiresDevModeConfirmation) {
      _controller.start();
    }
  }

  @override
  void dispose() {
    _wormholeUrlController.removeListener(_syncWormholeConfig);
    _wormholeTokenController.removeListener(_syncWormholeConfig);
    _wormholeUrlController.dispose();
    _wormholeTokenController.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _syncWormholeConfig() {
    _controller.updateWormholeConfig(
      baseUrl: _wormholeUrlController.text,
      token: _wormholeTokenController.text,
    );
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Horizon'),
            actions: [
              if (_controller.running)
                Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: _StatusDot(connected: _controller.running),
                ),
            ],
          ),
          body: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_controller.devModeRequested)
                  _DevModeCard(controller: _controller),
                if (_controller.devModeRequested) const SizedBox(height: 16),
                _StatusCard(controller: _controller),
                const SizedBox(height: 16),
                _ConnectionCard(
                  controller: _controller,
                  wormholeUrlController: _wormholeUrlController,
                  wormholeTokenController: _wormholeTokenController,
                ),
                // Only show access card on macOS (folder access dialog)
                if (Platform.isMacOS) ...[
                  const SizedBox(height: 16),
                  _AccessCard(controller: _controller),
                ],
                const SizedBox(height: 16),
                _AddressCard(controller: _controller),
                const SizedBox(height: 24),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.connected});

  final bool connected;

  @override
  Widget build(BuildContext context) {
    final color = connected ? const Color(0xFF41C87A) : const Color(0xFFFF5C5C);
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(
            color: color.withOpacity(0.4),
            blurRadius: 6,
            spreadRadius: 1,
          ),
        ],
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.controller});

  final HorizonController controller;

  @override
  Widget build(BuildContext context) {
    final statusText = controller.running ? 'Running' : 'Stopped';
    final canStart = !controller.requiresDevModeConfirmation;
    final sessionId = controller.wormholeSessionId;
    final showSession = controller.wormholeEnabled && controller.running;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _StatusDot(connected: controller.running),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    statusText,
                    style: const TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                Switch(
                  value: controller.running,
                  onChanged: (value) {
                    if (value) {
                      if (canStart) controller.start();
                    } else {
                      controller.stop();
                    }
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                _InfoItem(label: 'Port', value: '${controller.port}'),
                const SizedBox(width: 24),
                _InfoItem(label: 'Clients', value: '${controller.clientCount}'),
              ],
            ),
            if (showSession) ...[
              const SizedBox(height: 20),
              _SessionIdDisplay(sessionId: sessionId),
            ],
            if (controller.error != null) ...[
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: const Color(0xFFFF5C5C).withOpacity(0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: const Color(0xFFFF5C5C).withOpacity(0.2)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.error_outline, size: 16, color: Color(0xFFFF5C5C)),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        controller.error!,
                        style: const TextStyle(color: Color(0xFFFF5C5C), fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoItem extends StatelessWidget {
  const _InfoItem({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label.toUpperCase(),
          style: const TextStyle(
            color: Color(0xFF9AA6B2),
            fontSize: 11,
            letterSpacing: 0.5,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }
}

class _SessionIdDisplay extends StatelessWidget {
  const _SessionIdDisplay({required this.sessionId});

  final String? sessionId;

  @override
  Widget build(BuildContext context) {
    final id = sessionId;
    final hasId = id != null && id.isNotEmpty;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A2A3A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withOpacity(0.1)),
      ),
      child: Row(
        children: [
          const Icon(Icons.vpn_key_outlined, size: 18, color: Color(0xFF4B7AA6)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'WORMHOLE SESSION',
                  style: TextStyle(
                    color: Color(0xFF9AA6B2),
                    fontSize: 10,
                    letterSpacing: 0.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  hasId ? id : 'Connecting...',
                  style: const TextStyle(
                    fontFamily: 'Menlo',
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                    color: Colors.white,
                    letterSpacing: 1.5,
                  ),
                ),
              ],
            ),
          ),
          if (hasId)
            IconButton(
              icon: const Icon(Icons.copy, size: 20, color: Color(0xFF9AA6B2)),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: id));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Session ID copied'),
                    behavior: SnackBarBehavior.floating,
                  ),
                );
              },
            ),
        ],
      ),
    );
  }
}

class _ConnectionCard extends StatelessWidget {
  const _ConnectionCard({
    required this.controller,
    required this.wormholeUrlController,
    required this.wormholeTokenController,
  });

  final HorizonController controller;
  final TextEditingController wormholeUrlController;
  final TextEditingController wormholeTokenController;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(title: 'Connection Modes', icon: Icons.settings_input_component_outlined),
            const SizedBox(height: 12),
            _ConfigRow(
              label: 'LAN Connection',
              subtitle: 'Allow direct connections on local network',
              value: controller.lanEnabled,
              onChanged: (v) => controller.setLanEnabled(v),
            ),
            const Divider(height: 24, color: Colors.white10),
            _ConfigRow(
              label: 'Wormhole Connection',
              subtitle: 'Enable secure remote access via relay',
              value: controller.wormholeEnabled,
              onChanged: (v) => controller.setWormholeEnabled(v),
            ),
            if (controller.wormholeEnabled) ...[
              const SizedBox(height: 24),
              const _SectionTitle(title: 'Wormhole Settings', icon: Icons.hub_outlined),
              const SizedBox(height: 16),
              _StyledTextField(
                controller: wormholeUrlController,
                label: 'Base URL',
                hint: 'wss://wormhole.example.com',
              ),
              const SizedBox(height: 16),
              _StyledTextField(
                controller: wormholeTokenController,
                label: 'Access Token',
                hint: 'Optional authentication token',
                isPassword: true,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.icon});
  final String title;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 18, color: const Color(0xFF4B7AA6)),
        const SizedBox(width: 10),
        Text(
          title.toUpperCase(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 12,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ],
    );
  }
}

class _ConfigRow extends StatelessWidget {
  const _ConfigRow({
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

class _StyledTextField extends StatelessWidget {
  const _StyledTextField({
    required this.controller,
    required this.label,
    this.hint,
    this.isPassword = false,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool isPassword;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      obscureText: isPassword,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        hintStyle: const TextStyle(color: Colors.white24, fontSize: 13),
        labelStyle: const TextStyle(color: Color(0xFF9AA6B2), fontSize: 13),
        filled: true,
        fillColor: Colors.white.withOpacity(0.05),
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: Colors.white.withOpacity(0.1)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: Color(0xFF4B7AA6), width: 1.5),
        ),
      ),
    );
  }
}

class _AddressCard extends StatelessWidget {
  const _AddressCard({required this.controller});

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
            const _SectionTitle(title: 'LAN Access', icon: Icons.lan_outlined),
            const SizedBox(height: 16),
            if (!controller.lanEnabled)
              const _StatusMessage(message: 'LAN is disabled in connection modes.', isError: false)
            else if (addresses.isEmpty)
              const _StatusMessage(message: 'No LAN IPv4 addresses detected.', isError: true)
            else
              ...addresses.map((addr) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.black.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white.withOpacity(0.05)),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.link, size: 14, color: Color(0xFF9AA6B2)),
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
              )),
          ],
        ),
      ),
    );
  }
}

class _StatusMessage extends StatelessWidget {
  const _StatusMessage({required this.message, required this.isError});
  final String message;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: (isError ? const Color(0xFFFF5C5C) : const Color(0xFF9AA6B2)).withOpacity(0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.warning_amber_rounded : Icons.info_outline,
            size: 16,
            color: isError ? const Color(0xFFFF5C5C) : const Color(0xFF9AA6B2),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              message,
              style: TextStyle(
                color: isError ? const Color(0xFFFF5C5C) : const Color(0xFF9AA6B2),
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _AccessCard extends StatelessWidget {
  const _AccessCard({required this.controller});

  final HorizonController controller;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionTitle(title: 'Filesystem', icon: Icons.folder_open_outlined),
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
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                ),
                if (controller.accessMessage != null) ...[
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      controller.accessMessage!,
                      style: const TextStyle(color: Color(0xFF41C87A), fontSize: 13),
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

class _DevModeCard extends StatelessWidget {
  const _DevModeCard({required this.controller});

  final HorizonController controller;

  @override
  Widget build(BuildContext context) {
    final warningColor = const Color(0xFFFF5C5C);

    return Card(
      color: warningColor.withOpacity(0.05),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: warningColor.withOpacity(0.2)),
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.warning_amber_rounded, color: warningColor, size: 20),
                const SizedBox(width: 10),
                Text(
                  controller.requiresDevModeConfirmation
                      ? 'DEV MODE CONFIRMATION'
                      : 'DEVELOPMENT MODE ACTIVE',
                  style: TextStyle(
                    color: warningColor,
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    letterSpacing: 0.5,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              controller.requiresDevModeConfirmation
                  ? 'Development mode is requested for this release build. This disables authentication on the LAN.'
                  : 'Authentication is disabled. Any device on the same network can control this terminal.',
              style: const TextStyle(color: Colors.white70, fontSize: 13),
            ),
            if (controller.requiresDevModeConfirmation) ...[
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: controller.confirmDevMode,
                  style: FilledButton.styleFrom(
                    backgroundColor: warningColor,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                  ),
                  child: const Text('Enable Dev Mode'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
