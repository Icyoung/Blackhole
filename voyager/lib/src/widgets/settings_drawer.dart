import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:voyager_share/voyager_share.dart';

import '../services/vpn_service.dart';

class SettingsDrawer extends StatefulWidget {
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
    required this.onShowKeyboardToolsChanged,
    required this.onShowCommandInputChanged,
    required this.onShowHHKBChanged,
    this.vpnEnabled = false,
    this.vpnService,
    this.onVpnEnabledChanged,
    this.tvNavigation = false,
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
  final ValueChanged<bool> onShowKeyboardToolsChanged;
  final ValueChanged<bool> onShowCommandInputChanged;
  final ValueChanged<bool> onShowHHKBChanged;
  final bool vpnEnabled;
  final VpnService? vpnService;
  final ValueChanged<bool>? onVpnEnabledChanged;
  final bool tvNavigation;

  @override
  State<SettingsDrawer> createState() => _SettingsDrawerState();
}

class _SettingsDrawerState extends State<SettingsDrawer> {
  bool _showAdvanced = false;
  final FocusNode _lanFocusNode = FocusNode(debugLabel: 'settings_lan');
  final FocusNode _remoteFocusNode = FocusNode(debugLabel: 'settings_remote');
  final FocusNode _addressFocusNode = FocusNode(debugLabel: 'settings_address');
  final FocusNode _autoReconnectFocusNode = FocusNode(
    debugLabel: 'settings_auto_reconnect',
  );

  @override
  void dispose() {
    _lanFocusNode.dispose();
    _remoteFocusNode.dispose();
    _addressFocusNode.dispose();
    _autoReconnectFocusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isTv = widget.tvNavigation;
    final drawerBg = isTv ? const Color(0xFF0C0F14) : AppColors.background;
    final fieldFill = isTv ? const Color(0xFF11161D) : AppColors.surfaceVariant;
    final fieldBorder = isTv ? const Color(0xFF2B3441) : AppColors.border;
    final textPrimary = isTv ? const Color(0xFFF8FAFC) : AppColors.textPrimary;
    final textMuted = isTv ? const Color(0xFF718096) : AppColors.textHint;
    final accent = isTv ? const Color(0xFF4D82FF) : AppColors.accent;
    final titleStyle = Theme.of(
      context,
    ).textTheme.titleMedium?.copyWith(color: textPrimary, fontSize: 18);

    return Drawer(
      backgroundColor: drawerBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          bottomLeft: Radius.circular(20),
        ),
      ),
      child: TvFocusScope(
        enabled: widget.tvNavigation,
        onBack: () => Navigator.of(context).maybePop(),
        child: SafeArea(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 20, 24, 24),
            children: [
              Row(
                children: [
                  Icon(Icons.settings_outlined, color: accent),
                  const SizedBox(width: 12),
                  Text(
                    'VOYAGER SETTINGS',
                    style: titleStyle?.copyWith(fontSize: 14, letterSpacing: 1),
                  ),
                ],
              ),
              const SizedBox(height: 24),
              _buildDrawerSection('Connection Mode'),
              const SizedBox(height: 12),
              _buildModeSelector(),
              const SizedBox(height: 20),
              if (widget.useWormhole) ...[
                _buildDrawerSection('Session ID'),
                const SizedBox(height: 12),
                TvFocusTextField(
                  controller: widget.sessionController,
                  tvNavigation: widget.tvNavigation,
                  focusNode: _addressFocusNode,
                  onMoveUp: _focusCurrentMode,
                  onMoveDown: () => _autoReconnectFocusNode.requestFocus(),
                  textCapitalization: TextCapitalization.characters,
                  textAlign: TextAlign.center,
                  decoration: InputDecoration(
                    hintText: 'ABC123',
                    hintStyle: TextStyle(
                      color: textMuted,
                      fontSize: 14,
                      letterSpacing: 4,
                      fontWeight: FontWeight.bold,
                    ),
                    filled: true,
                    fillColor: fieldFill,
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: accent, width: 1.5),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(
                        color: accent.withValues(alpha: 0.4),
                        width: 1.5,
                      ),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: BorderSide(color: accent, width: 2),
                    ),
                  ),
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 14,
                    letterSpacing: 4,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 20),
                _buildAdvancedToggle(),
                AnimatedCrossFade(
                  firstChild: const SizedBox.shrink(),
                  secondChild: Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      children: [
                        TvFocusTextField(
                          controller: widget.wormholeController,
                          tvNavigation: widget.tvNavigation,
                          decoration: _buildInputDecoration(
                            'Server URL',
                            fieldFill,
                            fieldBorder,
                          ),
                          style: TextStyle(color: textPrimary, fontSize: 14),
                        ),
                        const SizedBox(height: 12),
                        TvFocusTextField(
                          controller: widget.tokenController,
                          tvNavigation: widget.tvNavigation,
                          obscureText: true,
                          decoration: _buildInputDecoration(
                            'Token',
                            fieldFill,
                            fieldBorder,
                          ),
                          style: TextStyle(color: textPrimary, fontSize: 14),
                        ),
                      ],
                    ),
                  ),
                  crossFadeState:
                      _showAdvanced
                          ? CrossFadeState.showSecond
                          : CrossFadeState.showFirst,
                  duration: const Duration(milliseconds: 200),
                ),
              ] else ...[
                _buildDrawerSection('Address'),
                const SizedBox(height: 12),
                TvFocusTextField(
                  controller: widget.urlController,
                  tvNavigation: widget.tvNavigation,
                  focusNode: _addressFocusNode,
                  onMoveUp: _focusCurrentMode,
                  onMoveDown: () => _autoReconnectFocusNode.requestFocus(),
                  decoration: _buildInputDecoration(
                    'Address',
                    fieldFill,
                    fieldBorder,
                  ),
                  style: TextStyle(color: textPrimary, fontSize: 14),
                ),
              ],
              if (widget.vpnService != null) ...[
                const SizedBox(height: 24),
                _buildVpnSection(),
              ],
              const SizedBox(height: 24),
              _buildDrawerSection('Modes & Behavior'),
              const SizedBox(height: 8),
              _buildDrawerSwitch(
                'Auto Reconnect',
                widget.autoReconnect,
                widget.onAutoReconnectChanged,
                focusNode: _autoReconnectFocusNode,
              ),
              _buildDrawerSwitch(
                'Multi-Window Mode',
                widget.multiWindow,
                widget.onMultiWindowChanged,
              ),
              const SizedBox(height: 24),
              _buildDrawerSection('Input'),
              const SizedBox(height: 8),
              _buildDrawerSwitch(
                'Keyboard Tools',
                widget.showKeyboardTools,
                widget.onShowKeyboardToolsChanged,
              ),
              _buildDrawerSwitch(
                'Quick Input',
                widget.showCommandInput,
                widget.onShowCommandInputChanged,
              ),
              _buildDrawerSwitch(
                'HHKB Keyboard',
                widget.showHHKB,
                widget.onShowHHKBChanged,
              ),
              const SizedBox(height: 40),
              Text(
                'Blackhole Voyager v1.0.0',
                textAlign: TextAlign.center,
                style: TextStyle(color: textMuted, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildModeSelector() {
    return Row(
      children: [
        Expanded(
          child: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.arrowRight):
                  () => _remoteFocusNode.requestFocus(),
              const SingleActivator(LogicalKeyboardKey.arrowDown):
                  () => _addressFocusNode.requestFocus(),
            },
            child: _buildModeOption(
              label: 'LAN',
              selected: !widget.useWormhole,
              focusNode: _lanFocusNode,
              borderRadius: const BorderRadius.horizontal(
                left: Radius.circular(10),
              ),
              onTap: () {
                if (widget.useWormhole) widget.onUseWormholeChanged(false);
              },
            ),
          ),
        ),
        Expanded(
          child: CallbackShortcuts(
            bindings: <ShortcutActivator, VoidCallback>{
              const SingleActivator(LogicalKeyboardKey.arrowLeft):
                  () => _lanFocusNode.requestFocus(),
              const SingleActivator(LogicalKeyboardKey.arrowDown):
                  () => _addressFocusNode.requestFocus(),
            },
            child: _buildModeOption(
              label: 'Remote',
              selected: widget.useWormhole,
              focusNode: _remoteFocusNode,
              borderRadius: const BorderRadius.horizontal(
                right: Radius.circular(10),
              ),
              onTap: () {
                if (!widget.useWormhole) widget.onUseWormholeChanged(true);
              },
            ),
          ),
        ),
      ],
    );
  }

  void _focusCurrentMode() {
    if (widget.useWormhole) {
      _remoteFocusNode.requestFocus();
    } else {
      _lanFocusNode.requestFocus();
    }
  }

  Widget _buildModeOption({
    required String label,
    required bool selected,
    required FocusNode focusNode,
    required BorderRadius borderRadius,
    required VoidCallback onTap,
  }) {
    final activeColor =
        widget.tvNavigation ? const Color(0xFF4D82FF) : AppColors.accent;
    final inactiveColor =
        widget.tvNavigation
            ? const Color(0xFF11161D)
            : AppColors.surfaceVariant;
    final activeBorder = activeColor;
    final inactiveBorder =
        widget.tvNavigation ? const Color(0xFF2B3441) : AppColors.border;
    final hoverColor =
        widget.tvNavigation ? const Color(0xFF222936) : AppColors.surfaceBright;
    final primary =
        widget.tvNavigation ? const Color(0xFFF8FAFC) : AppColors.textPrimary;
    final muted =
        widget.tvNavigation ? const Color(0xFF718096) : AppColors.textMuted;

    return FocusableTapRegion(
      onTap: onTap,
      semanticLabel: label,
      autofocus: selected,
      focusNode: focusNode,
      builder: (context, focused, hovered, pressed) {
        final highlighted = focused || hovered || pressed;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color:
                selected
                    ? activeColor.withValues(alpha: 0.15)
                    : highlighted
                    ? hoverColor
                    : inactiveColor,
            borderRadius: borderRadius,
            border: Border.all(
              color:
                  focused
                      ? activeColor
                      : selected
                      ? activeBorder
                      : inactiveBorder,
              width: focused || selected ? 1.5 : 1,
            ),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: selected || focused ? primary : muted,
              fontSize: 13,
              fontWeight:
                  selected || focused ? FontWeight.bold : FontWeight.normal,
              letterSpacing: 0.5,
            ),
          ),
        );
      },
    );
  }

  Widget _buildAdvancedToggle() {
    return GestureDetector(
      onTap: () => setState(() => _showAdvanced = !_showAdvanced),
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          children: [
            AnimatedRotation(
              turns: _showAdvanced ? 0.25 : 0,
              duration: const Duration(milliseconds: 200),
              child: const Icon(
                Icons.chevron_right,
                color: AppColors.accent,
                size: 18,
              ),
            ),
            const SizedBox(width: 4),
            const Text(
              'Advanced',
              style: TextStyle(
                color: AppColors.accent,
                fontSize: 13,
                fontWeight: FontWeight.w500,
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
      style: TextStyle(
        color: widget.tvNavigation ? const Color(0xFF718096) : AppColors.accent,
        fontSize: 11,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.5,
      ),
    );
  }

  Widget _buildDrawerSwitch(
    String label,
    bool value,
    ValueChanged<bool> onChanged, {
    FocusNode? focusNode,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color:
                    widget.tvNavigation
                        ? const Color(0xFFF8FAFC)
                        : AppColors.textPrimary,
                fontSize: 14,
              ),
            ),
          ),
          Switch(value: value, onChanged: onChanged, focusNode: focusNode),
        ],
      ),
    );
  }

  Widget _buildVpnSection() {
    final vpn = widget.vpnService!;
    final isEnabled = widget.vpnEnabled;

    final (statusLabel, statusColor) = switch (vpn.status) {
      VpnStatus.disconnected => (
        isEnabled ? 'Ready for upgrade' : 'Relay only',
        AppColors.textMuted,
      ),
      VpnStatus.connecting => ('Upgrading...', AppColors.statusYellow),
      VpnStatus.connected => ('Connected', AppColors.statusGreen),
      VpnStatus.disconnecting => ('Disconnecting...', AppColors.statusYellow),
      VpnStatus.error => ('Error', AppColors.statusRed),
    };

    final helperText =
        isEnabled
            ? 'After the main connection is ready, Voyager will try to upgrade the current WebSocket transport to native VPN.'
            : 'Voyager stays on the current WebSocket transport and will not request VPN config.';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildDrawerSection('VPN'),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppColors.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color:
                  isEnabled
                      ? AppColors.accent.withValues(alpha: 0.3)
                      : AppColors.surfaceVariant,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.shield_outlined,
                    color: isEnabled ? AppColors.statusGreen : AppColors.accent,
                    size: 18,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    statusLabel,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (vpn.isConnected) ...[
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 1,
                      ),
                      decoration: BoxDecoration(
                        color:
                            vpn.connectionMode == VpnConnectionMode.direct
                                ? const Color(
                                  0xFF6B9B7A,
                                ).withValues(alpha: 0.15)
                                : const Color(
                                  0xFFC09050,
                                ).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        vpn.connectionMode == VpnConnectionMode.direct
                            ? 'Direct'
                            : 'Relay',
                        style: TextStyle(
                          color:
                              vpn.connectionMode == VpnConnectionMode.direct
                                  ? AppColors.statusGreen
                                  : AppColors.statusOrange,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                  const Spacer(),
                  SizedBox(
                    height: 24,
                    child: Switch(
                      value: isEnabled,
                      onChanged: widget.onVpnEnabledChanged,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                helperText,
                style: const TextStyle(
                  color: AppColors.accent,
                  fontSize: 11,
                  height: 1.35,
                ),
              ),
              if (vpn.error case final errorText?
                  when errorText.isNotEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  errorText,
                  style: const TextStyle(
                    color: AppColors.statusRed,
                    fontSize: 11,
                    height: 1.35,
                  ),
                ),
              ],
              if (vpn.isConnected && vpn.clientIp != null) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Text(
                      vpn.clientIp!,
                      style: const TextStyle(
                        color: AppColors.accent,
                        fontSize: 11,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
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
      hintStyle: TextStyle(
        color:
            widget.tvNavigation ? const Color(0xFF718096) : AppColors.textHint,
        fontSize: 13,
      ),
      filled: true,
      fillColor: fill,
      isDense: true,
      labelStyle: TextStyle(
        color: widget.tvNavigation ? const Color(0xFF718096) : AppColors.accent,
        fontSize: 13,
      ),
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
        borderSide: BorderSide(
          color:
              widget.tvNavigation ? const Color(0xFF4D82FF) : AppColors.accent,
          width: 1.5,
        ),
      ),
    );
  }
}
