import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../controllers/horizon_controller.dart';
import 'cards/access_card.dart';
import 'cards/paired_devices_card.dart';
import 'common/status_dot.dart';

class SettingsDrawer extends StatefulWidget {
  const SettingsDrawer({
    super.key,
    required this.isHorizonMode,
    required this.onModeChanged,
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
    required this.hostController,
    required this.hostWormholeUrlController,
    required this.hostWormholeTokenController,
    required this.hostCustomSessionController,
    required this.onHostWormholeConfigCommit,
  });

  final bool isHorizonMode;
  final ValueChanged<bool> onModeChanged;
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
  final HorizonController hostController;
  final TextEditingController hostWormholeUrlController;
  final TextEditingController hostWormholeTokenController;
  final TextEditingController hostCustomSessionController;
  final VoidCallback onHostWormholeConfigCommit;

  @override
  State<SettingsDrawer> createState() => _SettingsDrawerState();
}

class _SettingsDrawerState extends State<SettingsDrawer>
    with SingleTickerProviderStateMixin {
  static const double _outerPadding = 24;
  static const double _headerTopPadding = 18;
  static const double _headerBottomGap = 12;
  static const double _tabBottomGap = 10;
  static const double _listTopPadding = 14;
  static const double _listBottomPadding = 24;
  static const double _sectionGap = 20;
  static const double _titleGap = 10;
  static const double _blockGap = 12;
  static const double _tightGap = 6;
  static const double _footerGap = 28;

  String? _remoteAccessError;
  bool _showRemoteAccessFields = false;
  final FocusNode _wormholeUrlFocus = FocusNode();
  final FocusNode _wormholeTokenFocus = FocusNode();
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _showRemoteAccessFields = widget.hostController.wormholeEnabled;
    _wormholeUrlFocus.addListener(_handleWormholeFieldFocus);
    _wormholeTokenFocus.addListener(_handleWormholeFieldFocus);
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.isHorizonMode ? 0 : 1,
    );
    _tabController.addListener(_onTabChanged);
  }

  @override
  void dispose() {
    _tabController.removeListener(_onTabChanged);
    _tabController.dispose();
    _wormholeUrlFocus.removeListener(_handleWormholeFieldFocus);
    _wormholeTokenFocus.removeListener(_handleWormholeFieldFocus);
    _wormholeUrlFocus.dispose();
    _wormholeTokenFocus.dispose();
    super.dispose();
  }

  void _onTabChanged() {
    if (!_tabController.indexIsChanging) {
      widget.onModeChanged(_tabController.index == 0);
    }
  }

  void _showRemoteAccessError(String message) {
    setState(() => _remoteAccessError = message);
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) {
        setState(() => _remoteAccessError = null);
      }
    });
  }

  void _handleWormholeFieldFocus() {
    if (_wormholeUrlFocus.hasFocus || _wormholeTokenFocus.hasFocus) {
      return;
    }
    widget.onHostWormholeConfigCommit();
  }

  String? _validateRemoteAccess() {
    final url = widget.hostWormholeUrlController.text.trim();
    if (url.isEmpty) {
      return 'Please enter a Wormhole URL';
    }
    final uri = Uri.tryParse(url);
    if (uri == null ||
        (uri.scheme != 'ws' && uri.scheme != 'wss') ||
        uri.host.isEmpty) {
      return 'Please enter a valid Wormhole URL';
    }
    final token = widget.hostWormholeTokenController.text.trim();
    if (token.isNotEmpty && token.contains(RegExp(r'\\s'))) {
      return 'Access token cannot contain spaces';
    }
    final customSessionValid = !widget.hostController.customSessionEnabled ||
        widget.hostCustomSessionController.text.trim().length == 6;
    if (!customSessionValid) {
      return 'Custom Session ID must be 6 characters';
    }
    return null;
  }

  void _handleRemoteAccessToggle(bool value) {
    if (!value) {
      setState(() => _showRemoteAccessFields = false);
      widget.hostController.setWormholeEnabled(false);
      return;
    }
    setState(() => _showRemoteAccessFields = true);
    widget.hostController.setWormholeEnabled(true);
  }

  void _handleRemoteAccessTest() {
    final error = _validateRemoteAccess();
    if (error != null) {
      _showRemoteAccessError(error);
      return;
    }
    if (_remoteAccessError != null) {
      setState(() => _remoteAccessError = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fieldFill = Colors.white.withValues(alpha: 0.05);
    final fieldBorder = Colors.white.withValues(alpha: 0.1);
    final titleStyle = Theme.of(context)
        .textTheme
        .titleMedium
        ?.copyWith(color: Colors.white, fontSize: 18);
    final shareUrl = _buildShareUrl();

    return Drawer(
      backgroundColor: const Color(0xFF0F141B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.only(
          topLeft: Radius.circular(20),
          bottomLeft: Radius.circular(20),
        ),
      ),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                _outerPadding,
                _headerTopPadding,
                _outerPadding,
                0,
              ),
              child: Row(
                children: [
                  const Icon(Icons.settings_outlined,
                      color: Color(0xFF4B7AA6)),
                  const SizedBox(width: 12),
                  Text(
                    'SETTINGS',
                    style: titleStyle?.copyWith(
                      fontSize: 14,
                      letterSpacing: 1,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: _headerBottomGap),
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: _outerPadding),
                child: _buildDrawerSection('Mode'),
              ),
            ),
            const SizedBox(height: _titleGap),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: _outerPadding),
              child: Container(
                padding: const EdgeInsets.all(1),
                decoration: BoxDecoration(
                  color: const Color(0xFF111620),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
                child: TabBar(
                  controller: _tabController,
                  labelColor: Colors.white,
                  unselectedLabelColor: const Color(0xFF9AA6B2),
                  labelStyle: const TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                  ),
                  dividerColor: Colors.transparent,
                  indicatorSize: TabBarIndicatorSize.tab,
                  indicator: BoxDecoration(
                    color: const Color(0xFF1E2D3D),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  indicatorPadding: EdgeInsets.zero,
                  labelPadding: EdgeInsets.zero,
                  indicatorWeight: 0,
                  tabs: const [
                    Tab(height: 32, text: 'HORIZON'),
                    Tab(height: 32, text: 'VOYAGER'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: _tabBottomGap),
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _buildHostSettings(
                    context,
                    shareUrl,
                    fieldFill,
                    fieldBorder,
                  ),
                  _buildClientSettings(
                    context,
                    fieldFill,
                    fieldBorder,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHostSettings(
    BuildContext context,
    String? shareUrl,
    Color fill,
    Color border,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        _outerPadding,
        _listTopPadding,
        _outerPadding,
        _listBottomPadding,
      ),
      children: [
        _buildDrawerSection('Sharing'),
        const SizedBox(height: _titleGap),
        _buildRemoteAccessCard(context, shareUrl, fill, border),
        const SizedBox(height: _sectionGap),
        _buildDrawerSection('File Access'),
        const SizedBox(height: _titleGap),
        if (Platform.isMacOS)
          AccessCard(
            controller: widget.hostController,
            flat: true,
            showHeader: false,
          )
        else
          const Text(
            'File access is only available on macOS.',
            style: TextStyle(color: Color(0xFF9AA6B2), fontSize: 13),
          ),
        const SizedBox(height: _sectionGap),
        _buildDrawerSection('Trusted Devices'),
        const SizedBox(height: _titleGap),
        PairedDevicesCard(
          controller: widget.hostController,
          flat: true,
          showHeader: false,
        ),
        const SizedBox(height: _sectionGap),
        _buildDrawerSection('URL Access'),
        const SizedBox(height: _titleGap),
        _buildUrlAccessSection(context, shareUrl),
        const SizedBox(height: _footerGap),
        Text(
          'Blackhole Horizon v1.0.0',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.2),
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _buildClientSettings(
    BuildContext context,
    Color fill,
    Color border,
  ) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(
        _outerPadding,
        _listTopPadding,
        _outerPadding,
        _listBottomPadding,
      ),
      children: [
        _buildDrawerSection('Remote Connection'),
        const SizedBox(height: _titleGap),
        TextField(
          controller: widget.useWormhole
              ? widget.wormholeController
              : widget.urlController,
          decoration: _buildInputDecoration(
            'Address',
            fill,
            border,
          ),
          style: const TextStyle(color: Colors.white, fontSize: 14),
        ),
        const SizedBox(height: _blockGap),
        _buildDrawerSwitch(
          'Use Wormhole',
          widget.useWormhole,
          widget.onUseWormholeChanged,
        ),
        if (widget.useWormhole) ...[
          const SizedBox(height: _blockGap),
          TextField(
            controller: widget.sessionController,
            textCapitalization: TextCapitalization.characters,
            decoration: _buildInputDecoration(
              'Session ID',
              fill,
              border,
              hint: '6-digit code',
            ),
            style: const TextStyle(
              color: Colors.white,
              letterSpacing: 4,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: _blockGap),
          TextField(
            controller: widget.tokenController,
            decoration: _buildInputDecoration(
              'Token (Optional)',
              fill,
              border,
            ),
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
        ],
        const SizedBox(height: _sectionGap),
        _buildDrawerSection('Network / Debug'),
        const SizedBox(height: _titleGap),
        _buildDrawerSwitch(
          'Auto Reconnect',
          widget.autoReconnect,
          widget.onAutoReconnectChanged,
        ),
        _buildDrawerSwitch(
          'Multi-Window Mode',
          widget.multiWindow,
          widget.onMultiWindowChanged,
        ),
        const SizedBox(height: _sectionGap),
        _buildDrawerSection('Input'),
        const SizedBox(height: _titleGap),
        _buildDrawerSwitch(
          'Keyboard Tools',
          widget.showKeyboardTools,
          widget.onShowKeyboardToolsChanged,
        ),
        const SizedBox(height: _tightGap),
        _buildDrawerSwitch(
          'HHKB Keyboard',
          widget.showHHKB,
          widget.onShowHHKBChanged,
        ),
        const SizedBox(height: _footerGap),
        Text(
          'Blackhole Voyager v1.0.0',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.2),
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  Widget _buildRemoteAccessCard(
    BuildContext context,
    String? shareUrl,
    Color fill,
    Color border,
  ) {
    final statusText = widget.hostController.running ? 'Online' : 'Offline';
    final statusColor = widget.hostController.running
        ? const Color(0xFF41C87A)
        : const Color(0xFFFF5C5C);
    final showRemoteFields =
        _showRemoteAccessFields || widget.hostController.wormholeEnabled;
    final wormholeEnabled = widget.hostController.wormholeEnabled;
    final wormholeConnecting = widget.hostController.wormholeConnecting;
    final wormholeConnected = widget.hostController.wormholeConnected;
    final wormholeStatusText = wormholeConnected
        ? 'Online'
        : (wormholeConnecting ? 'Connecting' : 'Offline');
    final wormholeStatusColor = wormholeConnected
        ? const Color(0xFF41C87A)
        : (wormholeConnecting
            ? const Color(0xFFFFC857)
            : const Color(0xFFFF8A80));
    final sessionId = widget.hostController.customSessionEnabled
        ? widget.hostController.customSessionId
        : widget.hostController.wormholeSessionId;
    final isWormholeConnected = wormholeEnabled &&
        sessionId != null &&
        sessionId.isNotEmpty &&
        sessionId != 'Connecting...';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          width: double.infinity,
          padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
          decoration: BoxDecoration(
            color: fill,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: border),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  StatusDot(connected: widget.hostController.running, size: 8),
                  const SizedBox(width: 8),
                  const Text(
                    'This Device Status',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const Spacer(),
                  Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: _tightGap),
              if (wormholeEnabled) ...[
                const SizedBox(height: _tightGap),
                Row(
                  children: [
                    StatusDot(connected: wormholeConnected, size: 8),
                    const SizedBox(width: 8),
                    const Text(
                      'Wormhole Status',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const Spacer(),
                    Text(
                      wormholeStatusText,
                      style: TextStyle(
                        color: wormholeStatusColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: _tightGap),
              Row(
                children: [
                  const Icon(Icons.link,
                      size: 14, color: Color(0xFF9AA6B2)),
                  const SizedBox(width: 8),
                  const Text(
                    'Active Connections',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  ),
                  const Spacer(),
                  Text(
                    '${widget.hostController.clientCount}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
              if (isWormholeConnected) ...[
                const SizedBox(height: _blockGap),
                Container(
                  width: double.infinity,
                  height: 1,
                  color: Colors.white.withValues(alpha: 0.08),
                ),
                const SizedBox(height: _blockGap),
                Row(
                  children: [
                    const Icon(Icons.tag, size: 14, color: Color(0xFF9AA6B2)),
                    const SizedBox(width: 8),
                    const Text(
                      'Session ID',
                      style: TextStyle(color: Colors.white70, fontSize: 12),
                    ),
                    const Spacer(),
                    Text(
                      sessionId!,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 4,
                        fontFamily: 'JetBrainsMono',
                      ),
                    ),
                  ],
                ),
                if (shareUrl != null) ...[
                  const SizedBox(height: _tightGap),
                  Row(
                    children: [
                      const Icon(Icons.link,
                          size: 14, color: Color(0xFF9AA6B2)),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          shareUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF9AA6B2),
                            fontSize: 11,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      InkWell(
                        onTap: () {
                          Clipboard.setData(ClipboardData(text: shareUrl));
                          ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text('Link copied to clipboard')),
                          );
                        },
                        borderRadius: BorderRadius.circular(4),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.copy,
                              size: 16, color: Color(0xFF9AA6B2)),
                        ),
                      ),
                      const SizedBox(width: 4),
                      InkWell(
                        onTap: () => _showQrDialog(context, shareUrl),
                        borderRadius: BorderRadius.circular(4),
                        child: const Padding(
                          padding: EdgeInsets.all(4),
                          child: Icon(Icons.qr_code_rounded,
                              size: 16, color: Color(0xFF9AA6B2)),
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ],
          ),
        ),
        const SizedBox(height: _blockGap),
        _buildDrawerSwitch(
          'Allow LAN Access',
          widget.hostController.lanEnabled,
          (value) => widget.hostController.setLanEnabled(value),
        ),
        _buildRemoteAccessSwitch(),
        if (showRemoteFields) ...[
          const SizedBox(height: _blockGap),
          TextField(
            controller: widget.hostWormholeUrlController,
            focusNode: _wormholeUrlFocus,
            decoration: _buildInputDecoration(
              'Wormhole Base URL',
              fill,
              border,
              hint: 'wss://wormhole.example.com',
            ),
            style: const TextStyle(color: Colors.white, fontSize: 14),
          ),
          const SizedBox(height: _blockGap),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: widget.hostWormholeTokenController,
                  focusNode: _wormholeTokenFocus,
                  decoration: _buildInputDecoration(
                    'Access Token',
                    fill,
                    border,
                    hint: 'Optional authentication token',
                  ),
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  obscureText: true,
                ),
              ),
              const SizedBox(width: 10),
              IntrinsicHeight(
                child: ElevatedButton(
                  onPressed: widget.hostController.wormholeConnecting
                      ? null
                      : _handleRemoteAccessTest,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF284058),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  child: const Text('Test'),
                ),
              ),
            ],
          ),
          const SizedBox(height: _blockGap),
        ],
        if (showRemoteFields) ...[
          _buildDrawerSwitch(
            'Use Custom Session ID',
            widget.hostController.customSessionEnabled,
            (value) => widget.hostController.setCustomSessionEnabled(value),
          ),
          if (widget.hostController.customSessionEnabled) ...[
            const SizedBox(height: _blockGap),
            TextField(
              controller: widget.hostCustomSessionController,
              textCapitalization: TextCapitalization.characters,
              decoration: _buildInputDecoration(
                'Session ID',
                fill,
                border,
                hint: 'e.g., ABC123',
                suffixText:
                    '${widget.hostCustomSessionController.text.length}/6',
              ),
              maxLength: 6,
              buildCounter: (context,
                      {required currentLength,
                      required isFocused,
                      required maxLength}) =>
                  null,
              style: const TextStyle(
                color: Colors.white,
                letterSpacing: 4,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildUrlAccessSection(BuildContext context, String? shareUrl) {
    final lanEnabled = widget.hostController.lanEnabled;
    final addresses = widget.hostController.addresses;
    final port = widget.hostController.port;
    final wormholeConnected = widget.hostController.wormholeConnected;

    // Strip query parameters from wormhole URL for display
    String? wormholeDisplayUrl;
    if (shareUrl != null) {
      final uri = Uri.tryParse(shareUrl);
      if (uri != null) {
        wormholeDisplayUrl = uri.replace(query: '').toString();
        // Remove trailing '?' if present
        if (wormholeDisplayUrl.endsWith('?')) {
          wormholeDisplayUrl =
              wormholeDisplayUrl.substring(0, wormholeDisplayUrl.length - 1);
        }
      }
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // LAN addresses
        if (!lanEnabled)
          _buildMutedText('LAN is disabled.')
        else if (addresses.isEmpty)
          _buildMutedText('No LAN IPv4 addresses detected.')
        else
          ...addresses.map(
            (addr) => _buildUrlRow(
              icon: Icons.wifi,
              text: 'ws://$addr:$port',
              color: const Color(0xFF41C87A),
              fontFamily: 'JetBrainsMono',
            ),
          ),
        // Wormhole URL (without query parameters)
        if (wormholeConnected && wormholeDisplayUrl != null)
          _buildUrlRow(
            icon: Icons.hub_outlined,
            text: wormholeDisplayUrl,
            color: const Color(0xFF64B5F6),
            fontFamily: 'JetBrainsMono',
          )
        else if (widget.hostController.wormholeEnabled && !wormholeConnected)
          _buildMutedText('Wormhole: Connecting...'),
      ],
    );
  }

  Widget _buildUrlRow({
    required IconData icon,
    required String text,
    Color? color,
    String? fontFamily,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(icon, size: 14, color: const Color(0xFF9AA6B2)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                color: color ?? Colors.white,
                fontSize: 12,
                fontFamily: fontFamily,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubsectionLabel(String title) {
    return Text(
      title.toUpperCase(),
      style: const TextStyle(
        color: Color(0xFF9AA6B2),
        fontSize: 10,
        fontWeight: FontWeight.bold,
        letterSpacing: 0.6,
      ),
    );
  }

  Widget _buildMutedText(String text) {
    return Text(
      text,
      style: const TextStyle(color: Color(0xFF9AA6B2), fontSize: 12),
    );
  }

  void _showQrDialog(BuildContext context, String link) {
    final validation = QrValidator.validate(data: link);
    if (!validation.isValid) {
      if (!mounted) {
        return;
      }
      showDialog<void>(
        context: context,
        useRootNavigator: true,
        builder: (context) {
          return AlertDialog(
            backgroundColor: const Color(0xFF0F141B),
            title: const Text(
              'QR unavailable',
              style: TextStyle(color: Colors.white),
            ),
            content: const Text(
              'The link is too long to generate a QR code.',
              style: TextStyle(color: Colors.white70, fontSize: 12),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('Close'),
              ),
            ],
          );
        },
      );
      return;
    }

    showDialog<void>(
      context: context,
      useRootNavigator: true,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF0F141B),
          title: const Text(
            'Wormhole QR',
            style: TextStyle(color: Colors.white),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              QrImageView(
                data: link,
                size: 180,
                backgroundColor: Colors.white,
                errorStateBuilder: (context, error) {
                  return const Text(
                    'Unable to render QR code.',
                    style: TextStyle(color: Colors.white70, fontSize: 12),
                  );
                },
              ),
              const SizedBox(height: 12),
              Text(
                link,
                style: const TextStyle(color: Colors.white70, fontSize: 11),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }

  String? _buildShareUrl() {
    final base = widget.hostController.wormholeBaseUrl.trim();
    if (base.isEmpty) {
      return null;
    }
    final uri = Uri.tryParse(base);
    if (uri == null) {
      return null;
    }
    final query = Map<String, String>.from(uri.queryParameters);
    query['role'] = 'voyager';
    final session = widget.hostController.customSessionEnabled
        ? widget.hostController.customSessionId
        : widget.hostController.wormholeSessionId;
    if (session != null && session.isNotEmpty && session != 'Connecting...') {
      query['session'] = session;
    }
    final token = widget.hostController.wormholeToken.trim();
    if (token.isNotEmpty) {
      query['token'] = token;
    }
    return uri.replace(queryParameters: query).toString();
  }

  Widget _buildDrawerSection(String title) {
    return Text(
      title.toUpperCase(),
      style: const TextStyle(
        color: Color(0xFF4B7AA6),
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

  Widget _buildRemoteAccessSwitch() {
    final controller = widget.hostController;
    final isConnecting = controller.wormholeConnecting;
    final isEnabled = controller.wormholeEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  'Allow Remote Access',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                ),
              ),
              Opacity(
                opacity: isConnecting ? 0.5 : 1.0,
                child: Switch(
                  value: isEnabled,
                  onChanged: isConnecting ? null : _handleRemoteAccessToggle,
                ),
              ),
            ],
          ),
        ),
        if (_remoteAccessError != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              _remoteAccessError!,
              style: const TextStyle(
                color: Color(0xFFFF8A80),
                fontSize: 12,
              ),
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
    String? suffixText,
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
      suffixText: suffixText,
      suffixStyle: const TextStyle(color: Color(0xFF9AA6B2), fontSize: 12),
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
        borderSide: const BorderSide(color: Color(0xFF4B7AA6), width: 1.5),
      ),
    );
  }
}
