import 'dart:convert';
import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../app.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _systemChannel = MethodChannel('com.blackhole/system');
  static const _settingsChannel = WindowMethodChannel(
    'com.blackhole/settings',
    mode: ChannelMode.unidirectional,
  );

  // Mode
  bool _isClientMode = false;

  // Server settings
  final _hostNameController = TextEditingController();
  bool _lanEnabled = true;
  final _lanPortController = TextEditingController(text: '9527');

  // Wormhole settings
  bool _wormholeEnabled = false;
  final _wormholeUrlController = TextEditingController();
  final _wormholeTokenController = TextEditingController();
  bool _customSessionEnabled = false;
  final _customSessionController = TextEditingController();
  bool _showAdvanced = false;

  // Client settings
  bool _isRemoteConnection = false;
  final _lanUrlController = TextEditingController();
  final _remoteSessionController = TextEditingController();
  final _remoteServerController = TextEditingController();
  final _remoteTokenController = TextEditingController();

  // Devices
  List<Map<String, dynamic>> _pairedDevices = [];

  // Folders
  List<String> _allowedFolders = [];

  String _selectedTab = 'general';
  String _version = '';
  bool _saveSuccess = false;

  @override
  void initState() {
    super.initState();
    _loadSettings();
    _loadVersion();
  }

  @override
  void dispose() {
    _hostNameController.dispose();
    _lanPortController.dispose();
    _wormholeUrlController.dispose();
    _wormholeTokenController.dispose();
    _customSessionController.dispose();
    _lanUrlController.dispose();
    _remoteSessionController.dispose();
    _remoteServerController.dispose();
    _remoteTokenController.dispose();
    super.dispose();
  }

  Future<void> _loadSettings() async {
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return;

      final settingsPath = '$home/.blackhole/horizon/settings.json';
      final file = File(settingsPath);
      if (!await file.exists()) {
        // Set default host name
        _hostNameController.text = Platform.localHostname;
        return;
      }

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final settings = json['settings'] as Map<String, dynamic>? ?? {};
      final devices = json['devices'] as List<dynamic>? ?? [];

      setState(() {
        _isClientMode = (settings['appMode'] as String? ?? 'server') == 'client';
        _hostNameController.text =
            settings['hostName'] as String? ?? Platform.localHostname;
        _lanEnabled = settings['lanEnabled'] as bool? ?? true;
        _lanPortController.text = '${settings['lanPort'] as int? ?? 9527}';
        _wormholeEnabled = settings['wormholeEnabled'] as bool? ?? false;
        _wormholeUrlController.text =
            settings['wormholeBaseUrl'] as String? ?? '';
        _wormholeTokenController.text =
            settings['wormholeToken'] as String? ?? '';
        _customSessionEnabled =
            settings['customSessionEnabled'] as bool? ?? false;
        _customSessionController.text =
            settings['customSessionId'] as String? ?? '';
        _isRemoteConnection =
            (settings['clientConnectionType'] as String? ?? 'lan') == 'remote';
        _lanUrlController.text = settings['clientLanUrl'] as String? ?? '';
        _remoteSessionController.text =
            settings['clientRemoteSession'] as String? ?? '';
        _remoteServerController.text =
            settings['clientRemoteServer'] as String? ?? '';
        _remoteTokenController.text =
            settings['clientRemoteToken'] as String? ?? '';
        _pairedDevices = devices.cast<Map<String, dynamic>>();
        _selectedTab = _isClientMode ? 'connection' : 'general';
      });

      // Load folder bookmarks
      await _loadFolderBookmarks();
    } catch (e) {
      debugPrint('[Settings] Failed to load: $e');
    }
  }

  Future<void> _loadFolderBookmarks() async {
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return;

      final bookmarksPath = '$home/.blackhole/horizon/folder_bookmarks.json';
      final file = File(bookmarksPath);
      if (!await file.exists()) return;

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      final bookmarks = json['bookmarks'] as List<dynamic>? ?? [];

      setState(() {
        _allowedFolders = bookmarks
            .map((b) => (b as Map<String, dynamic>)['path'] as String?)
            .whereType<String>()
            .toList();
      });
    } catch (e) {
      debugPrint('[Settings] Failed to load bookmarks: $e');
    }
  }

  Future<void> _saveSettings() async {
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return;

      final dir = Directory('$home/.blackhole/horizon');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final settings = {
        'appMode': _isClientMode ? 'client' : 'server',
        'hostName': _hostNameController.text,
        'lanEnabled': _lanEnabled,
        'lanPort': int.tryParse(_lanPortController.text) ?? 9527,
        'wormholeEnabled': _wormholeEnabled,
        'wormholeBaseUrl': _wormholeUrlController.text,
        'wormholeToken': _wormholeTokenController.text,
        'customSessionEnabled': _customSessionEnabled,
        'customSessionId': _customSessionController.text.toUpperCase(),
        'clientConnectionType': _isRemoteConnection ? 'remote' : 'lan',
        'clientLanUrl': _lanUrlController.text,
        'clientRemoteSession': _remoteSessionController.text.toUpperCase(),
        'clientRemoteServer': _remoteServerController.text,
        'clientRemoteToken': _remoteTokenController.text,
      };

      final json = {
        'version': 2,
        'settings': settings,
        'devices': _pairedDevices,
      };

      final file = File('$home/.blackhole/horizon/settings.json');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
      );

      // Notify native side
      try {
        await _systemChannel.invokeMethod('settingsChanged');
      } catch (_) {}
      // Notify main window (multi-window) to reload settings.
      try {
        await _settingsChannel.invokeMethod('settingsChanged');
      } catch (_) {}

      // Show success feedback
      if (mounted) {
        setState(() => _saveSuccess = true);
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) setState(() => _saveSuccess = false);
        });
      }
    } catch (e) {
      debugPrint('[Settings] Failed to save: $e');
    }
  }

  Future<void> _saveFolderBookmarks() async {
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return;

      final dir = Directory('$home/.blackhole/horizon');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final json = {
        'version': 1,
        'bookmarks': _allowedFolders.map((p) => {'path': p}).toList(),
      };

      final file = File('$home/.blackhole/horizon/folder_bookmarks.json');
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(json),
      );
    } catch (e) {
      debugPrint('[Settings] Failed to save bookmarks: $e');
    }
  }

  void _setMode(bool isClient) {
    setState(() {
      _isClientMode = isClient;
      _selectedTab = isClient ? 'connection' : 'general';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: HorizonColors.background,
      body: Row(
        children: [
          // Sidebar
          _buildSidebar(),
          // Divider
          Container(width: 1, color: HorizonColors.borderSubtle),
          // Content
          Expanded(
            child: Align(
              alignment: Alignment.topLeft,
              child: _buildContent(),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSidebar() {
    return Container(
      width: 210,
      color: HorizonColors.surface,
      child: Column(
        children: [
          const SizedBox(height: 38),
          // Mode toggle
          _buildModeToggle(),
          const SizedBox(height: 16),
          // Tab buttons
          Expanded(child: _buildTabButtons()),
          // Version
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _getVersionString(),
              style: TextStyle(
                color: HorizonColors.textMuted,
                fontSize: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModeToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        height: 32,
        decoration: BoxDecoration(
          color: HorizonColors.surfaceVariant,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: HorizonColors.borderSubtle),
        ),
        child: Row(
          children: [
            Expanded(
              child:
                  _buildModeButton('Server', !_isClientMode, () => _setMode(false)),
            ),
            Expanded(
              child:
                  _buildModeButton('Client', _isClientMode, () => _setMode(true)),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildModeButton(String title, bool isSelected, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        margin: const EdgeInsets.all(4),
        decoration: BoxDecoration(
          color:
              isSelected
                  ? HorizonColors.surfaceBright
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(7),
        ),
        alignment: Alignment.center,
        child: Text(
          title,
          style: TextStyle(
            color:
                isSelected
                    ? HorizonColors.textPrimary
                    : HorizonColors.textMuted,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }

  Widget _buildTabButtons() {
    final tabs = _isClientMode
        ? [('connection', 'Connection', Icons.link)]
        : [
            ('general', 'General', Icons.settings),
            ('remote', 'Remote', Icons.public),
            ('pairs', 'Devices', Icons.phone_iphone),
          ];

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: tabs.map((tab) {
        final (id, title, icon) = tab;
        final isSelected = _selectedTab == id;
        return Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: _buildTabButton(id, title, icon, isSelected),
        );
      }).toList(),
    );
  }

  Widget _buildTabButton(
      String id, String title, IconData icon, bool isSelected) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: () => setState(() => _selectedTab = id),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: isSelected
                ? HorizonColors.surfaceBright
                : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 16,
                color: isSelected
                    ? HorizonColors.textPrimary
                    : HorizonColors.textMuted,
              ),
              const SizedBox(width: 10),
              Text(
                title,
                style: TextStyle(
                  color: isSelected
                      ? HorizonColors.textPrimary
                      : HorizonColors.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildContent() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(32, 38, 32, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title + Save
          Row(
            children: [
              Expanded(
                child: Text(
                  _getTabTitle(),
                  style: const TextStyle(
                    color: HorizonColors.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              _buildSaveButton(),
            ],
          ),
          const SizedBox(height: 24),
          // Content based on tab
          _buildTabContent(),
        ],
      ),
    );
  }

  Widget _buildSaveButton() {
    return ElevatedButton.icon(
      onPressed: () {
        _saveSettings();
        _saveFolderBookmarks();
      },
      icon: Icon(
        _saveSuccess ? Icons.check : Icons.save_outlined,
        size: 16,
      ),
      label: Text(_saveSuccess ? 'Saved' : 'Save'),
      style: ElevatedButton.styleFrom(
        backgroundColor:
            _saveSuccess ? HorizonColors.success : HorizonColors.accent,
        foregroundColor: HorizonColors.textPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
    );
  }

  String _getTabTitle() {
    switch (_selectedTab) {
      case 'general':
        return 'General';
      case 'remote':
        return 'Remote';
      case 'pairs':
        return 'Paired Devices';
      case 'connection':
        return 'Connection';
      default:
        return '';
    }
  }

  Widget _buildTabContent() {
    switch (_selectedTab) {
      case 'general':
        return _buildGeneralTab();
      case 'remote':
        return _buildRemoteTab();
      case 'pairs':
        return _buildPairsTab();
      case 'connection':
        return _buildConnectionTab();
      default:
        return const SizedBox();
    }
  }

  // ===== General Tab =====
  Widget _buildGeneralTab() {
    return Column(
      children: [
        // Identity Card
        _buildCard(
          title: 'Identity',
          children: [
            _buildLabeledField(
              label: 'Host Name',
              child: _buildTextField(
                controller: _hostNameController,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        // Network Card
        _buildCard(
          title: 'Local Network',
          children: [
            Row(
              children: [
                Expanded(
                  child: _buildLabeledField(
                    label: 'LAN Access',
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Switch(
                        value: _lanEnabled,
                        onChanged: (v) => setState(() => _lanEnabled = v),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 32),
                SizedBox(
                  width: 120,
                  child: _buildLabeledField(
                    label: 'Port',
                    child: _buildTextField(
                      controller: _lanPortController,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 16),
        // File Access Card
        _buildCard(
          title: 'File Access',
          subtitle: 'Folders that Horizon can access',
          children: [
            Container(
              height: 150,
              decoration: BoxDecoration(
                color: HorizonColors.surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: HorizonColors.borderSubtle),
              ),
              child: _allowedFolders.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.folder_open,
                            size: 24,
                            color: HorizonColors.textMuted,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'No folders added',
                            style: TextStyle(
                              color: HorizonColors.textTertiary,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _allowedFolders.length,
                      itemBuilder: (context, index) {
                        final isSelected = _selectedFolderIndex == index;
                        return ListTile(
                          dense: true,
                          selected: isSelected,
                          selectedTileColor:
                              HorizonColors.accent.withValues(alpha: 0.08),
                          leading: Icon(
                            Icons.folder,
                            color: isSelected
                                ? HorizonColors.accent
                                : HorizonColors.textMuted,
                            size: 18,
                          ),
                          title: Text(
                            _allowedFolders[index],
                            style: const TextStyle(
                              color: HorizonColors.textPrimary,
                              fontSize: 12,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _selectFolderForRemoval(index),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                _buildPrimaryButton('Add Folder', _addFolder),
                const SizedBox(width: 8),
                _buildSecondaryButton('Remove', _removeSelectedFolder),
              ],
            ),
          ],
        ),
      ],
    );
  }

  int? _selectedFolderIndex;

  void _selectFolderForRemoval(int index) {
    setState(() {
      _selectedFolderIndex = _selectedFolderIndex == index ? null : index;
    });
  }

  Future<void> _addFolder() async {
    try {
      final result = await _systemChannel.invokeMethod('requestFolderAccess');
      if (result == true) {
        await _loadFolderBookmarks();
      }
    } catch (e) {
      debugPrint('[Settings] Failed to add folder: $e');
    }
  }

  void _removeSelectedFolder() {
    if (_selectedFolderIndex != null &&
        _selectedFolderIndex! < _allowedFolders.length) {
      setState(() {
        _allowedFolders.removeAt(_selectedFolderIndex!);
        _selectedFolderIndex = null;
      });
      _saveFolderBookmarks();
    }
  }

  // ===== Remote Tab =====
  Widget _buildRemoteTab() {
    return Column(
      children: [
        _buildCard(
          title: 'Wormhole Relay',
          subtitle: 'Remote access via official Wormhole relay.',
          children: [
            // Enable switch
            _buildSwitchRow(
              label: 'Enable Wormhole',
              value: _wormholeEnabled,
              onChanged: (v) => setState(() => _wormholeEnabled = v),
            ),
            const SizedBox(height: 16),
            // Custom Session ID
            Row(
              children: [
                Text(
                  'Custom Session ID',
                  style: TextStyle(
                    color: HorizonColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 12),
                Switch(
                  value: _customSessionEnabled,
                  onChanged: (v) => setState(() => _customSessionEnabled = v),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 100,
                  child: _buildTextField(
                    controller: _customSessionController,
                    textAlign: TextAlign.center,
                    hint: 'ABC123',
                    maxLength: 6,
                    textCapitalization: TextCapitalization.characters,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Optional \u2022 6 chars',
                  style: TextStyle(
                    color: HorizonColors.textTertiary,
                    fontSize: 10,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Advanced toggle
            GestureDetector(
              onTap: () => setState(() => _showAdvanced = !_showAdvanced),
              child: MouseRegion(
                cursor: SystemMouseCursors.click,
                child: Row(
                  children: [
                    AnimatedRotation(
                      turns: _showAdvanced ? 0.25 : 0,
                      duration: const Duration(milliseconds: 200),
                      child: Icon(
                        Icons.chevron_right,
                        color: HorizonColors.textTertiary,
                        size: 16,
                      ),
                    ),
                    Text(
                      'Advanced',
                      style: TextStyle(
                        color: HorizonColors.textTertiary,
                        fontSize: 11,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            AnimatedCrossFade(
              firstChild: const SizedBox.shrink(),
              secondChild: Padding(
                padding: const EdgeInsets.only(top: 12),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: HorizonColors.surface,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: HorizonColors.borderSubtle),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _buildLabeledField(
                        label: 'Server URL',
                        child: _buildTextField(
                          controller: _wormholeUrlController,
                          hint: 'wss://wormhole.example.com',
                        ),
                      ),
                      const SizedBox(height: 12),
                      _buildLabeledField(
                        label: 'Token',
                        child: _buildTextField(
                          controller: _wormholeTokenController,
                          hint: 'Authentication token',
                          isPassword: true,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              crossFadeState: _showAdvanced
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 250),
              sizeCurve: Curves.easeInOut,
            ),
          ],
        ),
      ],
    );
  }

  // ===== Pairs Tab =====
  Widget _buildPairsTab() {
    return Column(
      children: [
        _buildCard(
          subtitle: 'Devices authorized to connect to this instance',
          children: [
            Container(
              height: 200,
              decoration: BoxDecoration(
                color: HorizonColors.surface,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: HorizonColors.borderSubtle),
              ),
              child: _pairedDevices.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.devices_other,
                            size: 24,
                            color: HorizonColors.textMuted,
                          ),
                          const SizedBox(height: 8),
                          Text(
                            'No paired devices',
                            style: TextStyle(
                              color: HorizonColors.textTertiary,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    )
                  : ListView.builder(
                      itemCount: _pairedDevices.length,
                      itemBuilder: (context, index) {
                        final device = _pairedDevices[index];
                        return ListTile(
                          dense: true,
                          leading: Icon(
                            (device['deviceType'] as String?) == 'mobile'
                                ? Icons.phone_iphone
                                : Icons.desktop_mac,
                            color: HorizonColors.textMuted,
                            size: 18,
                          ),
                          title: Text(
                            device['deviceName'] as String? ?? 'Unknown',
                            style: const TextStyle(
                              color: HorizonColors.textPrimary,
                              fontSize: 12,
                            ),
                          ),
                          subtitle: Text(
                            _formatLastSeen(device['lastSeenAt'] as String?),
                            style: TextStyle(
                              color: HorizonColors.textTertiary,
                              fontSize: 11,
                            ),
                          ),
                        );
                      },
                    ),
            ),
            const SizedBox(height: 12),
            _buildSecondaryButton('Remove', _removeSelectedDevice),
          ],
        ),
      ],
    );
  }

  int? _selectedDeviceIndex;

  void _removeSelectedDevice() {
    if (_selectedDeviceIndex != null &&
        _selectedDeviceIndex! < _pairedDevices.length) {
      setState(() {
        _pairedDevices.removeAt(_selectedDeviceIndex!);
        _selectedDeviceIndex = null;
      });
      _saveSettings();
    }
  }

  String _formatLastSeen(String? isoDate) {
    if (isoDate == null) return 'Unknown';
    try {
      final date = DateTime.parse(isoDate);
      return '${date.month}/${date.day}/${date.year} ${date.hour}:${date.minute.toString().padLeft(2, '0')}';
    } catch (_) {
      return 'Unknown';
    }
  }

  // ===== Connection Tab (Client Mode) =====
  Widget _buildConnectionTab() {
    return Column(
      children: [
        _buildCard(
          title: 'Connection Type',
          children: [
            // Type toggle
            Container(
              height: 36,
              width: 220,
              decoration: BoxDecoration(
                color: HorizonColors.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: HorizonColors.borderSubtle),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: _buildModeButton(
                      'LAN',
                      !_isRemoteConnection,
                      () => setState(() => _isRemoteConnection = false),
                    ),
                  ),
                  Expanded(
                    child: _buildModeButton(
                      'Remote',
                      _isRemoteConnection,
                      () => setState(() => _isRemoteConnection = true),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            // Connection fields
            if (_isRemoteConnection)
              _buildRemoteConnectionFields()
            else
              _buildLanConnectionFields(),
            const SizedBox(height: 20),
            _buildPrimaryButton('Connect', () {
              _saveSettings();
              // Close window - the main app will handle reconnection
              Navigator.of(context).maybePop();
            }),
          ],
        ),
      ],
    );
  }

  Widget _buildRemoteConnectionFields() {
    return Column(
      key: const ValueKey('remote'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabeledField(
          label: 'Session ID',
          child: SizedBox(
            width: 140,
            child: _buildTextField(
              controller: _remoteSessionController,
              hint: 'ABC123',
              textAlign: TextAlign.center,
              maxLength: 6,
              textCapitalization: TextCapitalization.characters,
            ),
          ),
        ),
        const SizedBox(height: 12),
        _buildLabeledField(
          label: 'Server URL',
          child: _buildTextField(
            controller: _remoteServerController,
            hint: 'wss://wormhole.example.com',
          ),
        ),
        const SizedBox(height: 12),
        _buildLabeledField(
          label: 'Token (optional)',
          child: _buildTextField(
            controller: _remoteTokenController,
            hint: 'Authentication token',
            isPassword: true,
          ),
        ),
      ],
    );
  }

  Widget _buildLanConnectionFields() {
    return Column(
      key: const ValueKey('lan'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildLabeledField(
          label: 'Host URL',
          child: _buildTextField(
            controller: _lanUrlController,
            hint: 'ws://192.168.1.100:9527/ws',
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Enter the WebSocket URL of your Horizon host',
          style: TextStyle(
            color: HorizonColors.textTertiary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  // ===== UI Components =====
  Widget _buildCard({
    String? title,
    String? subtitle,
    required List<Widget> children,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: HorizonColors.surfaceVariant,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: HorizonColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null) ...[
            Text(
              title,
              style: const TextStyle(
                color: HorizonColors.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
          ],
          if (subtitle != null) ...[
            Text(
              subtitle,
              style: TextStyle(
                color: HorizonColors.textTertiary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 16),
          ] else if (title != null) ...[
            const SizedBox(height: 12),
          ],
          ...children,
        ],
      ),
    );
  }

  Widget _buildLabeledField({
    required String label,
    required Widget child,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: HorizonColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }

  Widget _buildTextField({
    required TextEditingController controller,
    String? hint,
    bool isPassword = false,
    TextAlign textAlign = TextAlign.start,
    int? maxLength,
    TextCapitalization textCapitalization = TextCapitalization.none,
    ValueChanged<String>? onChanged,
  }) {
    return TextField(
      controller: controller,
      obscureText: isPassword,
      textAlign: textAlign,
      maxLength: maxLength,
      textCapitalization: textCapitalization,
      onChanged: onChanged,
      cursorColor: HorizonColors.accent,
      style: const TextStyle(color: HorizonColors.textPrimary, fontSize: 13),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: HorizonColors.textMuted),
        counterText: '',
        filled: true,
        fillColor: HorizonColors.surface,
        isDense: true,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: HorizonColors.border),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: HorizonColors.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide:
              const BorderSide(color: HorizonColors.borderFocus, width: 1.5),
        ),
      ),
    );
  }

  Widget _buildSwitchRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: TextStyle(
            color: HorizonColors.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
        Switch(
          value: value,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildPrimaryButton(String title, VoidCallback onPressed) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        backgroundColor: HorizonColors.accent,
        foregroundColor: HorizonColors.textPrimary,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      child: Text(
        title,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Widget _buildSecondaryButton(String title, VoidCallback onPressed) {
    return OutlinedButton(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(
        foregroundColor: HorizonColors.textSecondary,
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        side: const BorderSide(color: HorizonColors.border),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
        ),
      ),
      child: Text(
        title,
        style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }

  Future<void> _loadVersion() async {
    final info = await PackageInfo.fromPlatform();
    if (mounted) {
      setState(() => _version = 'v${info.version}');
    }
  }

  String _getVersionString() {
    return _version;
  }
}
