import 'package:flutter/material.dart';
import 'design_tokens.dart';

class SettingsDrawer extends StatelessWidget {
  const SettingsDrawer({
    super.key,
    required this.useWormhole,
    required this.autoReconnect,
    required this.multiWindow,
    required this.showKeyboardTools,
    required this.showCommandInput,
    required this.showHHKB,
    required this.urlController,
    required this.wormholeController,
    required this.sessionController,
    required this.tokenController,
    required this.onUseWormholeChanged,
    required this.onAutoReconnectChanged,
    required this.onMultiWindowChanged,
    this.onResetMultiWindowLayout,
    this.onEqualizeMultiWindowLayout,
    required this.onShowKeyboardToolsChanged,
    required this.onShowCommandInputChanged,
    required this.onShowHHKBChanged,
  });

  final bool useWormhole;
  final bool autoReconnect;
  final bool multiWindow;
  final bool showKeyboardTools;
  final bool showCommandInput;
  final bool showHHKB;
  final TextEditingController urlController;
  final TextEditingController wormholeController;
  final TextEditingController sessionController;
  final TextEditingController tokenController;
  final ValueChanged<bool> onUseWormholeChanged;
  final ValueChanged<bool> onAutoReconnectChanged;
  final ValueChanged<bool> onMultiWindowChanged;
  final VoidCallback? onResetMultiWindowLayout;
  final VoidCallback? onEqualizeMultiWindowLayout;
  final ValueChanged<bool> onShowKeyboardToolsChanged;
  final ValueChanged<bool> onShowCommandInputChanged;
  final ValueChanged<bool> onShowHHKBChanged;

  @override
  Widget build(BuildContext context) {
    const fieldFill = AppColors.borderSubtle;
    const fieldBorder = AppColors.border;
    final titleStyle = Theme.of(context).textTheme.titleMedium?.copyWith(
      color: AppColors.textPrimary,
      fontSize: 18,
    );

    return Drawer(
      backgroundColor: AppColors.background,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(AppRadius.lg + 4),
          bottomLeft: Radius.circular(AppRadius.lg + 4),
        ),
      ),
      child: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
          children: [
            Row(
              children: [
                const Icon(Icons.settings_outlined, color: AppColors.accent),
                const SizedBox(width: 12),
                Text(
                  'VOYAGER SETTINGS',
                  style: titleStyle?.copyWith(fontSize: 14, letterSpacing: 1),
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
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
              ),
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
            if (multiWindow &&
                (onResetMultiWindowLayout != null ||
                    onEqualizeMultiWindowLayout != null)) ...[
              const SizedBox(height: 8),
              if (onResetMultiWindowLayout != null)
                _buildDrawerAction(
                  'Reset Layout',
                  Icons.restart_alt_rounded,
                  onResetMultiWindowLayout!,
                ),
              if (onEqualizeMultiWindowLayout != null)
                _buildDrawerAction(
                  'Equalize Pane Sizes',
                  Icons.grid_view_rounded,
                  onEqualizeMultiWindowLayout!,
                ),
            ],
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
              'Quick Input',
              showCommandInput,
              onShowCommandInputChanged,
            ),
            const SizedBox(height: 6),
            _buildDrawerSwitch('HHKB Keyboard', showHHKB, onShowHHKBChanged),
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
                  color: AppColors.textPrimary,
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
                style: const TextStyle(
                  color: AppColors.textPrimary,
                  fontSize: 14,
                ),
              ),
            ],
            const SizedBox(height: 40),
            Text(
              'Blackhole Voyager v1.0.0',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textHint, fontSize: 11),
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
        color: AppColors.textTertiary,
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
              style: const TextStyle(
                color: AppColors.textPrimary,
                fontSize: 14,
              ),
            ),
          ),
          Switch(value: value, onChanged: onChanged),
        ],
      ),
    );
  }

  Widget _buildDrawerAction(String label, IconData icon, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: TextButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 16),
        label: Text(label),
        style: TextButton.styleFrom(
          foregroundColor: AppColors.textPrimary,
          alignment: Alignment.centerLeft,
          padding: const EdgeInsets.symmetric(horizontal: 0, vertical: 10),
          textStyle: const TextStyle(fontSize: 14),
        ),
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
      hintStyle: const TextStyle(color: AppColors.textHint, fontSize: 13),
      filled: true,
      fillColor: fill,
      isDense: true,
      labelStyle: const TextStyle(color: AppColors.textTertiary, fontSize: 13),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm + 2),
        borderSide: BorderSide(color: border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm + 2),
        borderSide: BorderSide(color: border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(AppRadius.sm + 2),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
    );
  }
}
