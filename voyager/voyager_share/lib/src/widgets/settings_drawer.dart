import 'package:flutter/material.dart';

class SettingsDrawer extends StatelessWidget {
  const SettingsDrawer({
    super.key,
    required this.useWormhole,
    required this.autoReconnect,
    required this.multiWindow,
    required this.showKeyboardTools,
    required this.showHHKB,
    required this.urlController,
    required this.wormholeController,
    required this.sessionController,
    required this.tokenController,
    required this.onUseWormholeChanged,
    required this.onAutoReconnectChanged,
    required this.onMultiWindowChanged,
    required this.onShowKeyboardToolsChanged,
    required this.onShowHHKBChanged,
  });

  final bool useWormhole;
  final bool autoReconnect;
  final bool multiWindow;
  final bool showKeyboardTools;
  final bool showHHKB;
  final TextEditingController urlController;
  final TextEditingController wormholeController;
  final TextEditingController sessionController;
  final TextEditingController tokenController;
  final ValueChanged<bool> onUseWormholeChanged;
  final ValueChanged<bool> onAutoReconnectChanged;
  final ValueChanged<bool> onMultiWindowChanged;
  final ValueChanged<bool> onShowKeyboardToolsChanged;
  final ValueChanged<bool> onShowHHKBChanged;

  @override
  Widget build(BuildContext context) {
    final fieldFill = Colors.white.withValues(alpha: 0.05);
    final fieldBorder = Colors.white.withValues(alpha: 0.1);
    final titleStyle = Theme.of(context)
        .textTheme
        .titleMedium
        ?.copyWith(color: Colors.white, fontSize: 18);

    return Drawer(
      backgroundColor: const Color(0xFF0F141B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          bottomLeft: Radius.circular(20),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            Row(
              children: [
                const Icon(Icons.settings_outlined, color: Color(0xFF9AA0A6)),
                const SizedBox(width: 12),
                Text(
                  'VOYAGER SETTINGS',
                  style: titleStyle?.copyWith(
                    fontSize: 14,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 24),
            _buildDrawerSection('Connection Address'),
            const SizedBox(height: 12),
            TextField(
              controller: useWormhole ? wormholeController : urlController,
              decoration: _buildInputDecoration(
                'Address',
                fieldFill,
                fieldBorder,
              ),
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
            const SizedBox(height: 24),
            _buildDrawerSection('Modes & Behavior'),
            const SizedBox(height: 8),
            _buildDrawerSwitch(
              'LAN Mode',
              !useWormhole,
              (v) => onUseWormholeChanged(!v),
            ),
            _buildDrawerSwitch(
              'Auto Reconnect',
              autoReconnect,
              onAutoReconnectChanged,
            ),
            _buildDrawerSwitch(
              'Multi-Window Mode',
              multiWindow,
              onMultiWindowChanged,
            ),
            const SizedBox(height: 24),
            _buildDrawerSection('Input'),
            const SizedBox(height: 8),
            _buildDrawerSwitch(
              'Keyboard Tools',
              showKeyboardTools,
              onShowKeyboardToolsChanged,
            ),
            const SizedBox(height: 6),
            _buildDrawerSwitch(
              'HHKB Keyboard',
              showHHKB,
              onShowHHKBChanged,
            ),
            if (useWormhole) ...[
              const SizedBox(height: 24),
              _buildDrawerSection('Wormhole Remote Options'),
              const SizedBox(height: 12),
              TextField(
                controller: sessionController,
                textCapitalization: TextCapitalization.characters,
                decoration: _buildInputDecoration(
                  'Session ID',
                  fieldFill,
                  fieldBorder,
                  hint: '6-digit code',
                ),
                style: const TextStyle(
                  color: Colors.white,
                  letterSpacing: 4,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: tokenController,
                decoration: _buildInputDecoration(
                  'Token (Optional)',
                  fieldFill,
                  fieldBorder,
                ),
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
            const SizedBox(height: 40),
            Text(
              'Blackhole Voyager v1.0.0',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.2),
                fontSize: 11,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDrawerSection(String title) {
    return Text(
      title.toUpperCase(),
      style: const TextStyle(
        color: Color(0xFF9AA0A6),
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildDrawerSwitch(
    String label,
    bool value,
    ValueChanged<bool> onChanged,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: const TextStyle(color: Colors.white, fontSize: 14),
            ),
          ),
          Switch(
            value: value,
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  InputDecoration _buildInputDecoration(
    String label,
    Color fill,
    Color border, {
    String? hint,
  }) {
    return InputDecoration(
      labelText: label,
      hintText: hint,
      hintStyle: const TextStyle(color: Colors.white24, fontSize: 13),
      filled: true,
      fillColor: fill,
      isDense: true,
      labelStyle: const TextStyle(color: Color(0xFF9AA6B2), fontSize: 13),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: Color(0xFF9AA0A6), width: 1.5),
      ),
    );
  }
}
