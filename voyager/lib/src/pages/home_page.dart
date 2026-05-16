import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:window_manager/window_manager.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyager_share/voyager_share.dart'
    show
        AppColors,
        buildTerminalStyle,
        kTerminalThemeLight,
        PinyinEngine,
        CandidateBar,
        CommandInputBar,
        CommandInputBarState,
        MultiWindowGrid,
        MultiWindowLayoutController,
        VpnStatusRing,
        VpnRingState;
import 'package:xterm/xterm.dart';

import '../models/terminal_group.dart';
import '../services/connection_manager.dart';
import '../services/crypto_service.dart';
import '../services/device_name_policy.dart';
import '../services/group_store.dart';
import '../services/launch_trace_service.dart';
import '../services/launch_connection_policy.dart';
import '../services/vpn_transport_handoff.dart';
import '../services/vpn_service.dart';
import '../services/terminal_manager.dart';
import '../services/transport_models.dart';
import '../services/transport_rollout.dart';
import '../widgets/add_terminal_card.dart';
import '../widgets/chrome/header_chrome.dart';
import '../widgets/group_drawer.dart';
import '../widgets/keyboard/hhkb_keyboard.dart';
import '../widgets/quick_actions_bar.dart';
import '../widgets/settings_drawer.dart';
import '../widgets/terminal_window_card.dart';

class VoyagerHome extends StatefulWidget {
  const VoyagerHome({super.key});

  @override
  State<VoyagerHome> createState() => _VoyagerHomeState();
}

class _VoyagerHomeState extends State<VoyagerHome> with WidgetsBindingObserver {
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _quickBarKey = GlobalKey();
  final GlobalKey<CommandInputBarState> _commandInputKey =
      GlobalKey<CommandInputBarState>();
  final TextEditingController _urlController = TextEditingController(
    text: 'ws://127.0.0.1:9527/ws',
  );
  final TextEditingController _wormholeController = TextEditingController(
    text: 'wss://wormhole.blackhole-ai.com/ws',
  );
  final TextEditingController _sessionController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController(
    text: 'InGodWeTrust@Blackhole2026',
  );
  Timer? _metricsDebounce;

  late final ConnectionManager _connectionManager;
  late final TerminalManager _terminalManager;
  final MultiWindowLayoutController _multiWindowLayoutController =
      MultiWindowLayoutController();

  bool _connected = false;
  bool _reconnecting = false;
  bool _autoReconnect = true;
  bool _useWormhole = false;
  bool _showKeyboardTools = true;
  bool _showCommandInput = false;
  bool _showHHKB = false;
  bool _hhkbFn = false;
  bool _multiWindow = false;

  double _quickBarHeight = 0;
  static const double _hhkbKeyboardHeight = 250; // 5*42 + 4*6 + 16 padding

  static const double _candidateBarHeight = 40;

  static const double _commandInputBarHeight = 46;

  double get _bottomBarHeight =>
      (_showKeyboardTools ? _quickBarHeight : 0) +
      (_showCommandInput ? _commandInputBarHeight : 0) +
      (_showHHKB ? _hhkbKeyboardHeight : 0) +
      (_showHHKB && _chineseMode && _pinyinEngine.hasInput
          ? _candidateBarHeight
          : 0);
  double _lastMetricsInsetsBottom = 0;
  Size _lastMetricsSize = Size.zero;

  final List<String> _sessions = [];
  final Set<String> _syncedSessions = {};
  final Map<String, int> _sessionSyncOffsets = {};
  String? _activeSessionId;
  String? _pendingReconnectActiveSessionId;
  String? _pendingReconnectActiveGroupId;
  late final GroupStore _groupStore;

  bool _ctrl = false;
  bool _alt = false;
  bool _meta = false;
  bool _chineseMode = false;
  final PinyinEngine _pinyinEngine = PinyinEngine();
  bool _dragging = false;
  String? _dragTargetSessionId;

  // GlobalKeys for terminal cards in multi-window mode (for hit testing)
  final Map<String, GlobalKey> _terminalCardKeys = {};

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.error_outline, size: 14, color: Colors.white70),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message, style: const TextStyle(fontSize: 12)),
            ),
          ],
        ),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.fromLTRB(20, 0, 20, 0),
        duration: const Duration(seconds: 4),
        backgroundColor: const Color(0xCC9D3C3C),
      ),
    );
  }

  // Device pairing related state
  String? _deviceKey;
  String _deviceName = '';
  String? _remoteDeviceName;
  bool _pairingPending = false;
  bool _deviceNameRefreshInFlight = false;

  // E2E encryption
  final CryptoService _crypto = CryptoService();
  String? _publicKey;

  // VPN
  final VpnService _vpnService = VpnService();
  final VpnTransportHandoffCoordinator _vpnHandoff =
      VpnTransportHandoffCoordinator();
  EndpointInfo? _vpnEndpointInfo;
  bool _vpnEnabled = false;
  bool _vpnUpgradeAttempted = false;
  bool _vpnNativeStartInFlight = false;
  String? _vpnPrivateKey;
  String? _pendingVpnPublicKey;
  String? _vpnPublicKey;
  int? _vpnLocalPort;
  List<DirectCandidate> _vpnDirectCandidates = const <DirectCandidate>[];
  String? _lastAdvertisedVpnCandidateSignature;
  Timer? _vpnConfigTimeout;

  bool get _vpnAvailable => VpnService.isSupportedPlatform;

  void _vpnLog(String message) {
    final timestamp = DateTime.now().toUtc().toIso8601String();
    debugPrint('[$timestamp] [VPN] $message');
  }

  void _traceLaunch(String message) {
    debugPrint('[VoyagerLaunch] $message');
    unawaited(appendLaunchTrace(message));
  }

  List<String> get _visibleSessions => _groupStore.activeGroupSessionIds;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _terminalManager = TerminalManager(
      onInput: _handleTerminalInput,
      onResize: _handleResize,
      onTitleChange: (sessionId, title) {
        if (mounted) setState(() {});
        if (sessionId == _activeSessionId) {
          _updateWindowTitle();
        }
      },
      logPrefix: 'Voyager',
    );
    _connectionManager = ConnectionManager(
      onConnected: ({required waitForPairing}) {
        final wasReconnecting = _reconnecting;
        if (_reconnecting) {
          _reconnecting = false;
          _syncedSessions.clear();
          // Re-sync existing sessions after passive reconnect from the last
          // rendered byte offset so cached terminals do not duplicate history.
          for (final sid in _sessions) {
            _requestSyncIfNeeded(sid);
          }
        }
        if (!waitForPairing) {
          _sendListSessions();
        }
        final handoffDecision = _vpnHandoff.onPrimaryConnectionOpened(
          vpnConnected: _vpnService.isConnected,
          vpnMode: _currentVpnTunnelMode(),
          activeTransportKind: _connectionManager.activeTransportKind,
          endpoint: _currentVpnTransportEndpoint(),
        );
        if (handoffDecision.shouldSwitch) {
          _switchToVpnTransport(decision: handoffDecision);
        }
        if (!_showHHKB) {
          _terminalManager.activeViewKey?.currentState?.requestKeyboard();
        }
        if (wasReconnecting && mounted) {
          setState(() {});
        }
      },
      onConnectedChanged: (connected) {
        if (!mounted) {
          return;
        }
        setState(() {
          _connected = connected;
        });
      },
      onDisconnected: _handleDisconnected,
      onPairingPendingChanged: (pending) {
        if (!mounted) {
          return;
        }
        setState(() {
          _pairingPending = pending;
        });
      },
      onHostInfo: (hostName) {
        if (!mounted) {
          return;
        }
        setState(() {
          _remoteDeviceName = hostName;
        });
      },
      onError: (message) {
        debugPrint('[Connection] error: $message');
        if (!mounted) {
          return;
        }
        _showError(message);
        setState(() {
          _pairingPending = false;
        });
      },
      onGroupSync: (payload) {
        _groupStore.applySync(payload);
      },
      onGroupError: (message) {
        _showError('Group error: $message');
      },
      onPairingResult: ({
        required approved,
        String? assignedKey,
        String? horizonPublicKey,
      }) {
        if (approved) {
          if (assignedKey != null && assignedKey.isNotEmpty) {
            _deviceKey = assignedKey;
            _saveSettings();
            // Rebuild the reconnect URI so auto-reconnects include the
            // assigned device_key.  Without this, reconnects reuse the
            // original URI (which lacked device_key) and Horizon treats
            // every reconnect as a new device.
            if (_useWormhole) {
              _connectionManager.updateReconnectUri(_buildWormholeUri());
            }
          }
          // Setup encryption if Horizon provided public key
          if (horizonPublicKey != null && horizonPublicKey.isNotEmpty) {
            _setupEncryption(horizonPublicKey);
          }
          if (mounted) {
            setState(() {
              _pairingPending = false;
            });
          }
          debugPrint(
            '[Voyager] Pairing approved, deviceKey: $_deviceKey, hasHorizonPublicKey: ${horizonPublicKey != null}',
          );
          _sendListSessions();
          _maybeStartVpnUpgrade(force: true);
        } else {
          if (mounted) {
            _showError('Connection rejected by host');
            setState(() {
              _pairingPending = false;
              _connected = false;
            });
          }
          debugPrint('[Voyager] Pairing rejected');
        }
      },
      onSessionList: (sessions, {activeSessionId, activeGroupId}) {
        _handleSessionList(
          sessions,
          activeSessionId: activeSessionId,
          activeGroupId: activeGroupId,
        );
      },
      onSessionCreated: _handleSessionCreated,
      onSessionClosed: _handleSessionClosed,
      onStdout: _handleStdout,
      onSessionSync: _handleSessionSync,
      onEndpointInfo: _handleVpnEndpointInfo,
      onVpnConfig: _handleVpnConfig,
    );
    _groupStore = GroupStore(
      onChanged: _handleGroupChange,
      sendCommand: _connectionManager.sendCommand,
    );
    _multiWindowLayoutController.addListener(_handleMultiWindowLayoutChanged);
    unawaited(_loadAndSyncMultiWindowLayout());
    unawaited(_groupStore.loadLocalOrder());
    _pinyinEngine.addListener(_onPinyinChanged);
    _urlController.addListener(_handleAddressChange);
    _wormholeController.addListener(_handleAddressChange);
    _sessionController.addListener(_saveSettings);
    _tokenController.addListener(_saveSettings);
    unawaited(_beginLaunchFlow());
    _pinyinEngine.loadDict();
    if (_vpnAvailable) {
      _vpnService.initialize();
      _vpnService.addListener(_onVpnStatusChanged);
    }
  }

  Future<void> _beginLaunchFlow() async {
    await resetLaunchTrace('initState');
    await _loadSettings();
  }

  Future<void> _loadSettings() async {
    _traceLaunch('_loadSettings start');
    final prefs = await SharedPreferences.getInstance();
    final savedDeviceName = prefs.getString('deviceName');
    // Load or generate crypto keys
    await _loadOrGenerateKeys(prefs);

    setState(() {
      _urlController.text =
          prefs.getString('lanAddress') ?? 'ws://127.0.0.1:9527/ws';
      _wormholeController.text =
          prefs.getString('wormholeAddress') ??
          'wss://wormhole.blackhole-ai.com/ws';
      _sessionController.text = prefs.getString('sessionId') ?? '';
      _tokenController.text =
          prefs.getString('token') ?? 'InGodWeTrust@Blackhole2026';
      _useWormhole = prefs.getBool('useWormhole') ?? false;
      _vpnEnabled =
          prefs.getBool('vpnEnabled') ??
          (_vpnAvailable && defaultTargetPlatform == TargetPlatform.android);
      _autoReconnect = prefs.getBool('autoReconnect') ?? true;
      _multiWindow = prefs.getBool('multiWindow') ?? false;
      _showKeyboardTools = prefs.getBool('showKeyboardTools') ?? true;
      _showCommandInput = prefs.getBool('showCommandInput') ?? false;
      _showHHKB = prefs.getBool('showHHKB') ?? false;
      _chineseMode = prefs.getBool('chineseMode') ?? false;
      _deviceKey = prefs.getString('deviceKey');
      _deviceName = initialDeviceNameForLaunch(savedDeviceName);
    });
    _traceLaunch(
      '_loadSettings values '
      'autoReconnect=$_autoReconnect useWormhole=$_useWormhole '
      'sessionId=${_sessionController.text.trim().isNotEmpty} '
      'wormholeAddress=${_wormholeController.text.trim().isNotEmpty} '
      'lanAddress=${_urlController.text.trim().isNotEmpty} '
      'deviceName=$_deviceName',
    );
    if (shouldRefreshDeviceNameInBackground(savedDeviceName)) {
      _traceLaunch('_loadSettings scheduling device-name refresh');
      unawaited(_refreshDeviceNameInBackground());
    }
    _connectionManager.updateAutoReconnect(_autoReconnect);
    final autoConnectDecision = evaluateAutoConnectOnLaunch(
      autoReconnect: _autoReconnect,
      alreadyConnected: _connected || _connectionManager.connected,
      useWormhole: _useWormhole,
      sessionId: _sessionController.text,
      lanAddress: _urlController.text,
      wormholeAddress: _wormholeController.text,
    );
    _traceLaunch(
      '_loadSettings auto-connect decision '
      'shouldConnect=${autoConnectDecision.shouldConnect} '
      'reason=${autoConnectDecision.reason} '
      'alreadyConnected=${_connected || _connectionManager.connected}',
    );
    if (autoConnectDecision.shouldConnect) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          _traceLaunch('post-frame auto-connect skipped: unmounted');
          return;
        }
        if (_connected || _connectionManager.connected) {
          _traceLaunch(
            'post-frame auto-connect skipped: alreadyConnected='
            '${_connected || _connectionManager.connected}',
          );
          return;
        }
        _traceLaunch('post-frame auto-connect firing _connect()');
        unawaited(_connect());
      });
    }
  }

  Future<void> _loadOrGenerateKeys(SharedPreferences prefs) async {
    final savedPublicKey = prefs.getString('e2e_public_key');
    final savedPrivateKey = prefs.getString('e2e_private_key');

    if (savedPublicKey != null && savedPrivateKey != null) {
      try {
        await _crypto.loadKeyPair(
          publicKeyBase64: savedPublicKey,
          privateKeyBase64: savedPrivateKey,
        );
        _publicKey = savedPublicKey;
        debugPrint('[Voyager] Loaded existing device keys');
        return;
      } catch (e) {
        debugPrint('[Voyager] Failed to load keys: $e');
      }
    }

    // Generate new keys
    await _crypto.generateKeyPair();
    _publicKey = await _crypto.getPublicKeyBase64();
    final privateKey = await _crypto.getPrivateKeyBase64();
    await prefs.setString('e2e_public_key', _publicKey!);
    await prefs.setString('e2e_private_key', privateKey);
    debugPrint('[Voyager] Generated new device keys');
  }

  Future<void> _setupEncryption(String horizonPublicKey) async {
    try {
      await _crypto.computeSharedSecret(horizonPublicKey);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('horizonPublicKey', horizonPublicKey);
      final sharedSecret = await _crypto.getSharedSecretBase64();
      await prefs.setString('e2e_shared_secret', sharedSecret);
      debugPrint('[Voyager] E2E encryption setup complete');
    } catch (e) {
      debugPrint('[Voyager] Failed to setup encryption: $e');
    }
  }

  void _handleGroupChange() {
    if (!mounted) {
      return;
    }
    unawaited(_loadAndSyncMultiWindowLayout());
    if (_reconnecting && _pendingReconnectActiveSessionId != null) {
      final sessionId = _pendingReconnectActiveSessionId!;
      setState(() {
        _activeSessionId = sessionId;
        _terminalManager.activeSessionId = sessionId;
        _terminalFor(sessionId);
      });
      return;
    }
    _restoreActiveGroupForCurrentSession();
    // Request sync for all sessions in the new group
    for (final sessionId in _visibleSessions) {
      _requestSyncIfNeeded(sessionId);
    }
    setState(() {
      _syncActiveSessionWithGroup();
    });
    _clearPendingReconnectSelectionIfRestored();
    _sendSelectSession();
  }

  Future<void> _loadAndSyncMultiWindowLayout() async {
    await _multiWindowLayoutController.loadFor(_groupStore.activeGroupId);
    if (!mounted) {
      return;
    }
    _syncMultiWindowLayout();
  }

  void _syncMultiWindowLayout() {
    if (!mounted) {
      return;
    }
    final sessions = _visibleSessions;
    if (sessions.isEmpty) {
      return;
    }
    final columns = _currentVoyagerMultiWindowColumns();
    _multiWindowLayoutController.syncSessions(
      sessions,
      defaultColumns: columns,
      maxCellsPerRow: columns,
    );
  }

  void _handleMultiWindowLayoutChanged() {
    if (!mounted) {
      return;
    }
    setState(() {});
    _scheduleActiveResize();
  }

  bool _groupContainsSession(String groupId, String sessionId) {
    for (final group in _groupStore.groups) {
      if (group.id == groupId) {
        return group.sessionIds.contains(sessionId);
      }
    }
    return false;
  }

  void _clearPendingReconnectSelectionIfRestored() {
    final sessionId = _pendingReconnectActiveSessionId;
    if (sessionId == null || _activeSessionId != sessionId) {
      return;
    }
    final groupId = _pendingReconnectActiveGroupId;
    final groupHasSession = _groupStore.groups.any(
      (group) => group.sessionIds.contains(sessionId),
    );
    if (groupId == null ||
        _groupContainsSession(groupId, sessionId) ||
        groupHasSession) {
      _pendingReconnectActiveSessionId = null;
      _pendingReconnectActiveGroupId = null;
    }
  }

  void _restoreActiveGroupForCurrentSession() {
    final activeSessionId = _activeSessionId;
    if (activeSessionId == null) {
      return;
    }
    final activeGroup = _groupStore.activeGroup;
    if (activeGroup?.sessionIds.contains(activeSessionId) == true) {
      return;
    }
    for (final group in _groupStore.groups) {
      if (group.sessionIds.contains(activeSessionId)) {
        _groupStore.setActiveGroup(group.id);
        return;
      }
    }
  }

  void _syncActiveSessionWithGroup() {
    final sessions = _visibleSessions;
    if (sessions.isEmpty) {
      _activeSessionId = null;
      _terminalManager.activeSessionId = null;
      return;
    }
    if (_activeSessionId == null || !sessions.contains(_activeSessionId)) {
      _activeSessionId = sessions.first;
      _terminalManager.activeSessionId = _activeSessionId;
      _terminalFor(_activeSessionId!);
    }
  }

  Future<String> _getDefaultDeviceName() async {
    final deviceInfo = DeviceInfoPlugin();
    try {
      if (kIsWeb) {
        final webInfo = await deviceInfo.webBrowserInfo;
        return webInfo.browserName.name;
      }
      if (Platform.isIOS) {
        final iosInfo = await deviceInfo.iosInfo;
        // iOS 16+ may return a generic name; keep the name if available.
        final name = _normalizeDeviceName(iosInfo.name);
        if (name.isNotEmpty &&
            name != 'Unknown Device' &&
            name != 'Unknown device') {
          return name;
        }
        final modelName = iosInfo.modelName.trim();
        if (!isGenericDeviceName(modelName)) {
          return modelName; // e.g., "iPhone 15 Pro"
        }
        final machine = iosInfo.utsname.machine.trim();
        if (!isGenericDeviceName(machine)) {
          return machine; // e.g., "iPhone16,1"
        }
        return name.isNotEmpty ? name : 'Unknown Device';
      }
      if (Platform.isAndroid) {
        final androidInfo = await deviceInfo.androidInfo;
        return androidInfo.model;
      }
      if (Platform.isMacOS) {
        final macInfo = await deviceInfo.macOsInfo;
        return macInfo.computerName;
      }
      if (Platform.isWindows) {
        final windowsInfo = await deviceInfo.windowsInfo;
        return windowsInfo.computerName;
      }
      if (Platform.isLinux) {
        final linuxInfo = await deviceInfo.linuxInfo;
        return linuxInfo.prettyName;
      }
    } catch (_) {
      // Ignore device info errors
    }
    return 'Unknown Device';
  }

  String _normalizeDeviceName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return trimmed;
    }
    final duplicated = RegExp(r'^(.*)\\s*\\(\\1\\)$');
    final match = duplicated.firstMatch(trimmed);
    if (match != null) {
      return match.group(1)!.trim();
    }
    return trimmed;
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lanAddress', _urlController.text);
    await prefs.setString('wormholeAddress', _wormholeController.text);
    await prefs.setString('sessionId', _sessionController.text);
    await prefs.setString('token', _tokenController.text);
    await prefs.setBool('useWormhole', _useWormhole);
    await prefs.setBool('vpnEnabled', _vpnEnabled);
    await prefs.setBool('autoReconnect', _autoReconnect);
    await prefs.setBool('multiWindow', _multiWindow);
    await prefs.setBool('showKeyboardTools', _showKeyboardTools);
    await prefs.setBool('showCommandInput', _showCommandInput);
    await prefs.setBool('showHHKB', _showHHKB);
    await prefs.setBool('chineseMode', _chineseMode);
    if (_deviceKey != null) {
      await prefs.setString('deviceKey', _deviceKey!);
    }
    await prefs.setString('deviceName', _deviceName);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      return;
    }
    if (_connected || !_autoReconnect || !_connectionManager.shouldReconnect) {
      return;
    }
    if (_sessions.isNotEmpty) {
      _reconnecting = true;
    }
    unawaited(_connect(resetVpnUpgrade: false));
  }

  @override
  void dispose() {
    if (_vpnAvailable) {
      _vpnService.removeListener(_onVpnStatusChanged);
    }
    _disconnectMainConnection();
    WidgetsBinding.instance.removeObserver(this);
    _pinyinEngine.removeListener(_onPinyinChanged);
    _pinyinEngine.dispose();
    _urlController.removeListener(_handleAddressChange);
    _wormholeController.removeListener(_handleAddressChange);
    _sessionController.removeListener(_saveSettings);
    _tokenController.removeListener(_saveSettings);
    _urlController.dispose();
    _wormholeController.dispose();
    _sessionController.dispose();
    _tokenController.dispose();
    _metricsDebounce?.cancel();
    _terminalManager.dispose();
    _multiWindowLayoutController.removeListener(
      _handleMultiWindowLayoutChanged,
    );
    _multiWindowLayoutController.dispose();
    if (_vpnAvailable) {
      _vpnService.dispose();
    }
    super.dispose();
  }

  @override
  void didChangeMetrics() {
    _metricsDebounce?.cancel();
    _metricsDebounce = Timer(const Duration(milliseconds: 220), () {
      if (!mounted) {
        return;
      }
      final media = MediaQuery.of(context);
      final bottom = media.viewInsets.bottom;
      final size = media.size;
      final sameInsets = (bottom - _lastMetricsInsetsBottom).abs() < 0.5;
      final sameSize =
          (size.width - _lastMetricsSize.width).abs() < 0.5 &&
          (size.height - _lastMetricsSize.height).abs() < 0.5;
      if (sameInsets && sameSize) {
        return;
      }
      _lastMetricsInsetsBottom = bottom;
      _lastMetricsSize = size;
      if (!sameSize) {
        _syncMultiWindowLayout();
      }
      _scheduleActiveResize();
    });
  }

  void _handleAddressChange() {
    if (!mounted) {
      return;
    }
    setState(() {});
    _saveSettings();
  }

  void _onPinyinChanged() {
    if (mounted) setState(() {});
  }

  void _handleDisconnected() {
    _vpnConfigTimeout?.cancel();
    if (_vpnAvailable && !_vpnService.isConnected) {
      _vpnEndpointInfo = null;
      _vpnPrivateKey = null;
      _pendingVpnPublicKey = null;
      _vpnPublicKey = null;
      _vpnLocalPort = null;
      _vpnDirectCandidates = const <DirectCandidate>[];
      _lastAdvertisedVpnCandidateSignature = null;
      if (_vpnService.isActive) {
        _vpnService.failNegotiation(
          'Primary connection closed before VPN upgrade completed.',
        );
      }
    }
    // Passive disconnect with auto-reconnect: keep terminal state, show overlay.
    final passive = _connectionManager.shouldReconnect;
    if (passive && _sessions.isNotEmpty) {
      _reconnecting = true;
      _pendingReconnectActiveSessionId = _activeSessionId;
      _pendingReconnectActiveGroupId = _groupStore.activeGroupId;
      _groupStore.onDisconnected();
      _pinyinEngine.clear();
      if (mounted) {
        setState(() {});
      }
      return;
    }
    _reconnecting = false;
    _groupStore.onDisconnected();
    _pinyinEngine.clear();
    _remoteDeviceName = null;
    _sessions.clear();
    _syncedSessions.clear();
    _sessionSyncOffsets.clear();
    _activeSessionId = null;
    _pendingReconnectActiveSessionId = null;
    _pendingReconnectActiveGroupId = null;
    _terminalManager.activeSessionId = null;
    _terminalManager.clear();
    if (mounted) {
      setState(() {});
    }
  }

  void _handleSessionList(
    List<String> sessions, {
    String? activeSessionId,
    String? activeGroupId,
  }) {
    final preferredActiveSessionId =
        _pendingReconnectActiveSessionId ?? _activeSessionId;
    _sessions
      ..clear()
      ..addAll(sessions);
    if (_sessions.isEmpty) {
      _sendCreateSession();
      return;
    }
    // Restore active group before syncing active session
    if (activeGroupId != null) {
      _groupStore.setActiveGroup(activeGroupId);
    }
    // Request sync for all sessions to get terminal history
    for (final sessionId in sessions) {
      _requestSyncIfNeeded(sessionId);
    }
    // Restore active session if provided and still valid
    if (preferredActiveSessionId != null &&
        _sessions.contains(preferredActiveSessionId)) {
      _activeSessionId = preferredActiveSessionId;
    } else if (activeSessionId != null && _sessions.contains(activeSessionId)) {
      _activeSessionId = activeSessionId;
    }
    if (_activeSessionId == null || !_sessions.contains(_activeSessionId)) {
      _syncActiveSessionWithGroup();
    } else {
      _terminalFor(_activeSessionId!);
    }
    _terminalManager.activeSessionId = _activeSessionId;
    _clearPendingReconnectSelectionIfRestored();
    if (mounted) {
      setState(() {});
    }
    _scheduleActiveResize();
    if (_activeSessionId != null) {
      _restoreScrollOffset(_activeSessionId!);
    }
    _maybeStartVpnUpgrade();
  }

  void _requestSyncIfNeeded(String sessionId) {
    if (_syncedSessions.contains(sessionId)) {
      return;
    }
    _syncedSessions.add(sessionId);
    _connectionManager.sendSyncRequest(
      sessionId,
      offset: _sessionSyncOffsets[sessionId],
    );
  }

  void _handleSessionCreated(String sessionId) {
    if (!_sessions.contains(sessionId)) {
      _sessions.add(sessionId);
    }
    _activeSessionId = sessionId;
    _terminalManager.activeSessionId = sessionId;
    _terminalFor(sessionId);
    if (mounted) {
      setState(() {});
    }
    _scheduleActiveResize();
    _restoreScrollOffset(sessionId);
    _updateWindowTitle();
    _maybeStartVpnUpgrade();
  }

  void _handleSessionClosed(String sessionId) {
    _sessions.remove(sessionId);
    _terminalManager.removeSession(sessionId);
    _terminalCardKeys.remove(sessionId);
    _sessionSyncOffsets.remove(sessionId);
    _syncedSessions.remove(sessionId);
    if (_activeSessionId == sessionId) {
      final sessions = _visibleSessions;
      _activeSessionId = sessions.isNotEmpty ? sessions.first : null;
      _terminalManager.activeSessionId = _activeSessionId;
    }
    if (_activeSessionId == null) {
      _terminalManager.activeSessionId = null;
    }
    if (mounted) {
      setState(() {});
    }
    _updateWindowTitle();
  }

  void _handleSessionSync(
    String sessionId,
    String content, {
    int? offset,
    int? nextOffset,
    bool reset = true,
  }) {
    if (reset) {
      _terminalManager.resetTerminal(sessionId);
    }
    final currentOffset = reset ? null : _sessionSyncOffsets[sessionId];
    final startOffset = offset ?? (reset ? 0 : currentOffset ?? 0);
    final contentBytes = content.isEmpty ? Uint8List(0) : utf8.encode(content);
    final responseNextOffset =
        nextOffset ?? (startOffset + contentBytes.length);
    var writeBytes = contentBytes;
    if (!reset && currentOffset != null && startOffset < currentOffset) {
      final alreadyRendered = currentOffset - startOffset;
      if (alreadyRendered >= contentBytes.length) {
        _sessionSyncOffsets[sessionId] =
            currentOffset > responseNextOffset
                ? currentOffset
                : responseNextOffset;
        return;
      }
      writeBytes = Uint8List.fromList(contentBytes.sublist(alreadyRendered));
    }
    _sessionSyncOffsets[sessionId] =
        (_sessionSyncOffsets[sessionId] ?? 0) > responseNextOffset
            ? _sessionSyncOffsets[sessionId]!
            : responseNextOffset;
    if (writeBytes.isEmpty) {
      return;
    }
    _terminalManager.writeToTerminalBytes(sessionId, writeBytes);
    // Note: No setState needed - TerminalView auto-updates via Terminal's notifyListeners
  }

  void _handleStdout(String sessionId, Uint8List data) {
    _sessionSyncOffsets[sessionId] =
        (_sessionSyncOffsets[sessionId] ?? 0) + data.length;
    _terminalManager.writeToTerminalBytes(sessionId, data);
    // Note: No setState needed - TerminalView auto-updates via Terminal's notifyListeners
  }

  Future<void> _connect({bool resetVpnUpgrade = true}) async {
    _traceLaunch(
      '_connect enter resetVpnUpgrade=$resetVpnUpgrade '
      'useWormhole=$_useWormhole deviceName=$_deviceName',
    );
    if (mounted) {
      setState(() {
        _pairingPending = false;
      });
    }
    _vpnHandoff.clearFallbackSuppression();
    if (resetVpnUpgrade) {
      _vpnUpgradeAttempted = false;
    }
    if (_useWormhole) {
      unawaited(_refreshDeviceNameInBackground());
    }
    try {
      final candidate = await _buildTransportCandidates();
      _traceLaunch(
        '_connect candidates=${candidate.map((entry) => '${entry.kind.name}:${entry.uri}').join(',')}',
      );
      await _connectionManager.connectWithCandidates(
        candidates: candidate,
        autoReconnect: _autoReconnect,
      );
      _traceLaunch('_connect connectWithCandidates returned');
    } catch (error) {
      _traceLaunch('_connect error=$error');
      rethrow;
    }
  }

  Future<List<TransportCandidate>> _buildTransportCandidates() async {
    final lanUri = _tryParseUri(_urlController.text.trim());
    final wormholeUri =
        _useWormhole
            ? _buildWormholeUri()
            : _tryParseUri(_wormholeController.text.trim());

    if (TransportRolloutConfig.forceWormholeRelay && wormholeUri != null) {
      return [
        TransportCandidate(
          id: 'wormhole-forced',
          kind: TransportKind.wormholeRelay,
          uri: wormholeUri,
          waitForPairing: true,
          priority: 200,
          probeByConnect: false,
        ),
      ];
    }

    final seed =
        '${_deviceKey ?? 'anonymous'}:${_sessionController.text.trim()}:${_urlController.text.trim()}';
    final smartEnabled = TransportRolloutConfig.isSmartRoutingEnabledForSeed(
      seed,
    );

    final candidates = <TransportCandidate>[];

    if (_useWormhole && wormholeUri != null) {
      candidates.add(
        TransportCandidate(
          id: 'wormhole-default',
          kind: TransportKind.wormholeRelay,
          uri: wormholeUri,
          waitForPairing: true,
          priority: TransportRolloutConfig.defaultPriorityFor(
            TransportKind.wormholeRelay,
          ),
          probeByConnect: false,
        ),
      );
    }

    if (lanUri != null && (!TransportRolloutConfig.forceWormholeRelay)) {
      candidates.add(
        TransportCandidate(
          id: 'lan-default',
          kind: TransportKind.lanDirect,
          uri: lanUri,
          waitForPairing: false,
          priority: TransportRolloutConfig.defaultPriorityFor(
            TransportKind.lanDirect,
          ),
        ),
      );
    }

    if (!smartEnabled && candidates.isNotEmpty) {
      return [_selectLegacyPrimary(candidates)];
    }

    if (candidates.isEmpty) {
      final fallbackUri = _useWormhole ? wormholeUri : lanUri;
      if (fallbackUri == null) {
        return const [];
      }
      return [
        TransportCandidate(
          id: _useWormhole ? 'wormhole-fallback' : 'lan-fallback',
          kind:
              _useWormhole
                  ? TransportKind.wormholeRelay
                  : TransportKind.lanDirect,
          uri: fallbackUri,
          waitForPairing: _useWormhole,
          priority: 1,
          probeByConnect: !_useWormhole,
        ),
      ];
    }
    return candidates;
  }

  TransportCandidate _selectLegacyPrimary(List<TransportCandidate> candidates) {
    for (final candidate in candidates) {
      if (_useWormhole && candidate.kind == TransportKind.wormholeRelay) {
        return candidate;
      }
      if (!_useWormhole && candidate.kind == TransportKind.lanDirect) {
        return candidate;
      }
    }
    return candidates.first;
  }

  Uri? _tryParseUri(String raw) {
    if (raw.isEmpty) {
      return null;
    }
    try {
      return Uri.parse(raw);
    } catch (_) {
      return null;
    }
  }

  Future<void> _refreshDeviceNameInBackground() async {
    if (_deviceNameRefreshInFlight ||
        !shouldRefreshDeviceNameInBackground(_deviceName)) {
      return;
    }
    _deviceNameRefreshInFlight = true;
    try {
      _traceLaunch('_refreshDeviceNameInBackground start');
      final refreshed = await _getDefaultDeviceName();
      final trimmed = refreshed.trim();
      if (trimmed.isEmpty || trimmed == _deviceName) {
        _traceLaunch('_refreshDeviceNameInBackground unchanged=$trimmed');
        return;
      }
      if (mounted) {
        setState(() {
          _deviceName = trimmed;
        });
      } else {
        _deviceName = trimmed;
      }
      await _saveSettings();
      _traceLaunch('_refreshDeviceNameInBackground updated=$trimmed');
    } finally {
      _deviceNameRefreshInFlight = false;
    }
  }

  Uri _buildWormholeUri() {
    final base = Uri.parse(_wormholeController.text.trim());
    final query = Map<String, String>.from(base.queryParameters);
    query['role'] = 'voyager';
    final session = _sessionController.text.trim();
    if (session.isNotEmpty) {
      query['session'] = session;
    }
    final token = _tokenController.text.trim();
    if (token.isNotEmpty) {
      query['token'] = token;
    }
    // Add device information for pairing
    if (_deviceKey != null && _deviceKey!.isNotEmpty) {
      query['device_key'] = _deviceKey!;
    }
    // Ensure device_name is never empty (empty string causes URL param without value)
    final deviceName = _deviceName.isNotEmpty ? _deviceName : 'Unknown Device';
    query['device_name'] = deviceName;
    query['device_type'] = _getDeviceType();
    // Add public key for E2E encryption
    if (_publicKey != null && _publicKey!.isNotEmpty) {
      query['public_key'] = _publicKey!;
    }
    query['transport_id'] = 'wormhole-default';
    query['path_id'] = 'wormhole_relay:default';
    final uri = base.replace(queryParameters: query);
    debugPrint('[Voyager] Wormhole URI: $uri');
    debugPrint(
      '[Voyager] device_name=$deviceName, device_type=${_getDeviceType()}, device_key=$_deviceKey, has_public_key=${_publicKey != null}',
    );
    return uri;
  }

  Terminal _terminalFor(String sessionId) {
    return _terminalManager.terminalFor(sessionId);
  }

  void _scheduleActiveResize() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        return;
      }
      _forceResizeActiveTerminal();
    });
  }

  void _updateQuickBarHeight() {
    final context = _quickBarKey.currentContext;
    if (context == null) {
      return;
    }
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      return;
    }
    final height = box.size.height;
    if ((height - _quickBarHeight).abs() < 0.5) {
      return;
    }
    setState(() {
      _quickBarHeight = height;
    });
    _scheduleActiveResize();
  }

  void _forceResizeActiveTerminal() {
    _terminalManager.activeSessionId = _activeSessionId;
    _terminalManager.forceResizeActiveTerminal(
      multiWindow: _multiWindow,
      bottomBarHeight: _bottomBarHeight,
    );
  }

  TerminalController _controllerFor(String sessionId) {
    return _terminalManager.controllerFor(sessionId);
  }

  ScrollController _scrollControllerFor(String sessionId) {
    return _terminalManager.scrollControllerFor(sessionId);
  }

  void _restoreScrollOffset(String sessionId) {
    _terminalManager.restoreScrollOffset(sessionId);
  }

  GlobalKey<TerminalViewState> _viewKeyFor(String sessionId) {
    return _terminalManager.viewKeyFor(sessionId);
  }

  GlobalKey<TerminalViewState>? get _activeViewKey {
    return _terminalManager.activeViewKey;
  }

  Terminal? get _activeTerminal {
    return _terminalManager.activeTerminal;
  }

  TerminalController? get _activeController {
    return _terminalManager.activeController;
  }

  ScrollController? get _activeScrollController {
    return _terminalManager.activeScrollController;
  }

  Terminal get _idleTerminal => _terminalManager.idleTerminal;

  TerminalController get _idleController => _terminalManager.idleController;

  GlobalKey<TerminalViewState> get _idleTerminalViewKey =>
      _terminalManager.idleTerminalViewKey;

  ScrollController get _idleScrollController =>
      _terminalManager.idleScrollController;

  bool get _useHardwareKeyboardOnly =>
      !kIsWeb && (Platform.isMacOS || Platform.isLinux || Platform.isWindows);

  void _setActiveSession(String sessionId, {bool requestKeyboard = false}) {
    _pendingReconnectActiveSessionId = null;
    _pendingReconnectActiveGroupId = null;
    if (_activeSessionId == sessionId) {
      if (requestKeyboard && !_multiWindow && !_showHHKB) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _viewKeyFor(sessionId).currentState?.requestKeyboard();
        });
      }
      return;
    }
    // Commit pending pinyin when switching tabs
    if (_chineseMode && _pinyinEngine.hasInput) {
      final raw = _pinyinEngine.commitRaw();
      _sendRaw(raw);
    }
    // Request sync for this session if not already synced
    _requestSyncIfNeeded(sessionId);
    setState(() {
      _activeSessionId = sessionId;
      _terminalManager.activeSessionId = sessionId;
      _terminalFor(sessionId);
    });
    _scheduleActiveResize();
    _restoreScrollOffset(sessionId);
    _updateWindowTitle();
    _sendSelectSession();
    if (requestKeyboard && !_multiWindow && !_showHHKB) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _viewKeyFor(sessionId).currentState?.requestKeyboard();
      });
    }
  }

  void _reorderSessions(int oldIndex, int newIndex) {
    _groupStore.reorderSession(_groupStore.activeGroupId, oldIndex, newIndex);
  }

  void _sendSelectSession() {
    final sessionId = _activeSessionId;
    if (sessionId == null) return;
    _connectionManager.sendSelectSession(sessionId, _groupStore.activeGroupId);
  }

  void _updateWindowTitle() {
    if (!Platform.isMacOS && !Platform.isLinux && !Platform.isWindows) {
      return;
    }
    final sessionId = _activeSessionId;
    String title = 'Voyager';
    if (sessionId != null) {
      final terminalTitle = _terminalManager.getTitle(sessionId);
      if (terminalTitle != null && terminalTitle.isNotEmpty) {
        title = terminalTitle;
      }
    }
    try {
      windowManager.setTitle(title);
    } catch (_) {}
  }

  String _lastInputData = '';
  int _lastInputTimestamp = 0;

  String _normalizeTerminalInput(String data) {
    return data.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
  }

  void _handleTerminalInput(String sessionId, String data) {
    // When HHKB keyboard is shown, TerminalView is read-only
    // and input is handled by the keyboard widget instead.
    if (_showHHKB) return;

    if (_activeSessionId == null || _activeSessionId != sessionId) {
      return;
    }
    final normalizedData = _normalizeTerminalInput(data);
    // On mobile (hardwareKeyboardOnly=false), Flutter dispatches both a
    // hardware KeyDownEvent and an IME text-input change for the same
    // keystroke.  Both paths call terminal.keyInput() → onOutput, producing
    // duplicate characters.  A 50ms debounce window filters out the second
    // event reliably across device speeds.
    final now = DateTime.now().millisecondsSinceEpoch;
    if (normalizedData == _lastInputData && (now - _lastInputTimestamp) < 50) {
      debugPrint(
        '[Input] Skipping duplicate: "$normalizedData" within ${now - _lastInputTimestamp}ms',
      );
      return;
    }
    _lastInputData = normalizedData;
    _lastInputTimestamp = now;

    var output = normalizedData;
    if (_ctrl) {
      output = _applyCtrl(output);
      _ctrl = false;
    }
    if (_alt || _meta) {
      output = _applyAlt(output);
      _alt = false;
      _meta = false;
    }
    _sendRaw(output);
  }

  String _applyCtrl(String data) {
    final codes =
        data.runes.map((rune) {
          final ch = String.fromCharCode(rune);
          final upper = ch.toUpperCase();
          if (upper.codeUnitAt(0) >= 65 && upper.codeUnitAt(0) <= 90) {
            return String.fromCharCode(upper.codeUnitAt(0) - 64);
          }
          return ch;
        }).join();
    return codes;
  }

  String _applyAlt(String data) {
    final buffer = StringBuffer();
    for (final rune in data.runes) {
      buffer.writeCharCode(0x1b);
      buffer.writeCharCode(rune);
    }
    return buffer.toString();
  }

  void _sendCtrl(String key) {
    _sendRaw(_applyCtrl(key));
  }

  void _handleResize(
    String sessionId,
    int cols,
    int rows,
    int pixelWidth,
    int pixelHeight,
  ) {
    if (!_multiWindow && _activeSessionId != sessionId) {
      return;
    }
    _connectionManager.sendResize(sessionId, cols, rows);
  }

  bool _handlePinyinKey(String key, {required bool isSpecial}) {
    // Letter keys -> add to pinyin buffer
    if (!isSpecial && key.length == 1 && RegExp(r'[a-zA-Z]').hasMatch(key)) {
      _pinyinEngine.addChar(key);
      return true;
    }
    // Space -> select first candidate
    if (key == ' ') {
      if (_pinyinEngine.candidates.isNotEmpty) {
        final selected = _pinyinEngine.select(0);
        if (selected != null) _sendRaw(selected);
      } else if (_pinyinEngine.hasInput) {
        // No candidates: commit raw buffer
        final raw = _pinyinEngine.commitRaw();
        _sendRaw(raw);
      } else {
        // Empty buffer: send space normally
        _sendRaw(' ');
      }
      return true;
    }
    // Number keys 1-9 -> select candidate
    if (key.length == 1 && key.codeUnitAt(0) >= 49 && key.codeUnitAt(0) <= 57) {
      final index = key.codeUnitAt(0) - 49; // '1' -> 0, '9' -> 8
      if (index < _pinyinEngine.candidates.length) {
        final selected = _pinyinEngine.select(index);
        if (selected != null) _sendRaw(selected);
      } else {
        // No pinyin input or out of range: send number normally
        if (_pinyinEngine.hasInput) {
          final raw = _pinyinEngine.commitRaw();
          _sendRaw(raw);
        }
        _sendRaw(key);
      }
      return true;
    }
    // Backspace (\x7f) -> delete from buffer or send through
    if (key == '\x7f') {
      if (_pinyinEngine.hasInput) {
        _pinyinEngine.backspace();
      } else {
        if (_pinyinEngine.hasCandidates) {
          _pinyinEngine.clearPredictions();
        }
        _sendRaw(key);
      }
      return true;
    }
    // Enter -> commit candidate/raw but do not send newline if composing
    if (key == '\r') {
      if (_pinyinEngine.hasInput || _pinyinEngine.hasCandidates) {
        if (_pinyinEngine.candidates.isNotEmpty) {
          final selected = _pinyinEngine.select(0);
          if (selected != null) _sendRaw(selected);
        } else {
          final raw = _pinyinEngine.commitRaw();
          _sendRaw(raw);
        }
        return true;
      }
      return false;
    }
    // Punctuation and other keys -> commit buffer then send
    if (_pinyinEngine.hasInput) {
      final raw = _pinyinEngine.commitRaw();
      _sendRaw(raw);
    } else if (_pinyinEngine.hasCandidates) {
      _pinyinEngine.clearPredictions();
    }
    return false;
  }

  /// Whether HHKB input should be redirected to the command input bar.
  bool get _hhkbToCommandInput => _showHHKB && _showCommandInput;

  void _sendRaw(String data) {
    final sessionId = _activeSessionId;
    if (sessionId == null) {
      return;
    }
    _connectionManager.sendRaw(sessionId, data);
  }

  void _sendRawFor(String sessionId, String data) {
    _connectionManager.sendRaw(sessionId, data);
  }

  GlobalKey _terminalCardKeyFor(String sessionId) {
    return _terminalCardKeys.putIfAbsent(sessionId, () => GlobalKey());
  }

  String? _findTerminalAtPosition(Offset globalPosition) {
    // In multi-window mode, find which terminal card contains the drop position
    if (!_multiWindow) {
      return _activeSessionId;
    }

    final sessions =
        _visibleSessions.isNotEmpty
            ? _visibleSessions
            : (_activeSessionId != null ? [_activeSessionId!] : <String>[]);

    for (final sessionId in sessions) {
      final key = _terminalCardKeys[sessionId];
      if (key == null) continue;

      final renderBox = key.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox == null || !renderBox.hasSize) continue;

      final cardPosition = renderBox.localToGlobal(Offset.zero);
      final cardRect = cardPosition & renderBox.size;

      if (cardRect.contains(globalPosition)) {
        return sessionId;
      }
    }

    // Fallback to active session if no card found
    return _activeSessionId;
  }

  void _handleFileDrop(DropDoneDetails details) {
    // Save the target session before resetting (calculated during drag)
    final savedTargetId = _dragTargetSessionId;

    // Reset drag state
    setState(() {
      _dragging = false;
      _dragTargetSessionId = null;
    });

    if (details.files.isEmpty) {
      return;
    }

    // Use saved target from drag, or find from drop position, or fall back to active
    String? targetSessionId;
    if (_multiWindow) {
      targetSessionId =
          savedTargetId ?? _findTerminalAtPosition(details.globalPosition);
    }
    targetSessionId ??= _activeSessionId;

    if (targetSessionId == null) {
      return;
    }

    // Build paths without quotes
    final paths = details.files.map((file) => file.path).join(' ');

    // Always select the target terminal first, then send the paths
    _setActiveSession(targetSessionId);
    _sendRawFor(targetSessionId, paths);
  }

  void _sendCommand(Map<String, dynamic> payload) {
    _connectionManager.sendCommand(payload);
  }

  void _sendListSessions() {
    _sendCommand({'type': 'list'});
    _groupStore.requestGroupList();
  }

  void _sendCreateSession() {
    final groupId = _groupStore.activeGroupId;
    _sendCommand({
      'type': 'create',
      if (groupId != TerminalGroup.defaultGroupId) 'groupId': groupId,
    });
  }

  void _sendCloseSession(String sessionId) {
    _sendCommand({'type': 'close', 'sessionId': sessionId});
  }

  void _sendKey(TerminalKey key) {
    if (key == TerminalKey.enter || key == TerminalKey.numpadEnter) {
      _sendRaw('\r');
      return;
    }
    // When HHKB is active the terminal is read-only, so keyInput() is a no-op.
    // Send raw escape sequences instead.
    if (_showHHKB) {
      final raw = _terminalKeyToRaw(key);
      if (raw != null) {
        _sendRaw(raw);
      }
      return;
    }
    _activeTerminal?.keyInput(key);
  }

  static String? _terminalKeyToRaw(TerminalKey key) {
    switch (key) {
      case TerminalKey.tab:
        return '\t';
      case TerminalKey.escape:
        return '\x1b';
      case TerminalKey.arrowUp:
        return '\x1b[A';
      case TerminalKey.arrowDown:
        return '\x1b[B';
      case TerminalKey.arrowRight:
        return '\x1b[C';
      case TerminalKey.arrowLeft:
        return '\x1b[D';
      default:
        return null;
    }
  }

  Future<void> _pasteClipboard() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text != null && text.isNotEmpty) {
      _activeTerminal?.paste(text);
    }
  }

  Future<void> _copySelection() async {
    final controller = _activeController;
    final terminal = _activeTerminal;
    if (controller == null || terminal == null) {
      return;
    }
    final selection = controller.selection;
    if (selection == null) {
      return;
    }
    final text = terminal.buffer.getText(selection);
    await Clipboard.setData(ClipboardData(text: text));
    controller.clearSelection();
  }

  void _scrollToBottom() {
    final controller = _activeScrollController ?? _idleScrollController;
    if (!controller.hasClients) {
      return;
    }
    controller.jumpTo(controller.position.maxScrollExtent);
  }

  @override
  Widget build(BuildContext context) {
    const barColor = AppColors.surface;
    const activeColor = AppColors.border; // Slightly darker for contrast
    const overlayColor =
        Colors.transparent; // No longer need overlay with solid background
    final terminal = _activeTerminal ?? _idleTerminal;
    final controller = _activeController ?? _idleController;
    final scrollController = _activeScrollController ?? _idleScrollController;
    final deleteDetection = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    // connectionContent: 32 + 16(padding) = 48, tab栏: 28 + 6(padding) = 34
    const terminalTopInset = 48 + 34;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updateQuickBarHeight();
      }
    });

    final scaffold = Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppColors.surfaceVariant,
      onDrawerChanged: (isOpened) {
        if (!isOpened) {
          _groupStore.setDeferredSync(false);
        }
      },
      drawer: _buildGroupDrawer(context),
      endDrawer: _buildSettingsDrawer(context),
      body: Stack(
        children: [
          Positioned.fill(child: Container(color: AppColors.surfaceVariant)),
          Positioned.fill(
            top:
                MediaQuery.of(context).padding.top +
                terminalTopInset.toDouble(),
            child: DropTarget(
              onDragDone: _handleFileDrop,
              onDragEntered: (details) {
                setState(() {
                  _dragging = true;
                  if (_multiWindow) {
                    _dragTargetSessionId = _findTerminalAtPosition(
                      details.globalPosition,
                    );
                  }
                });
              },
              onDragExited:
                  (_) => setState(() {
                    _dragging = false;
                    _dragTargetSessionId = null;
                  }),
              onDragUpdated: (details) {
                if (_multiWindow) {
                  final targetId = _findTerminalAtPosition(
                    details.globalPosition,
                  );
                  if (targetId != _dragTargetSessionId) {
                    setState(() {
                      _dragTargetSessionId = targetId;
                    });
                  }
                }
              },
              child: Stack(
                children: [
                  _multiWindow
                      ? LayoutBuilder(
                        builder: (context, constraints) {
                          final width = constraints.maxWidth;
                          final columns = _voyagerMultiWindowColumnsForWidth(
                            width,
                          );
                          final sessions =
                              _visibleSessions.isNotEmpty
                                  ? _visibleSessions
                                  : (_activeSessionId != null
                                      ? [_activeSessionId!]
                                      : <String>[]);
                          final displaySessions =
                              sessions.isEmpty ? <String>[] : sessions;
                          final padding = EdgeInsets.fromLTRB(
                            16,
                            12,
                            16,
                            _bottomBarHeight + 20,
                          );

                          if (displaySessions.isEmpty) {
                            return Padding(
                              padding: padding,
                              child: TerminalView(
                                _idleTerminal,
                                key: _idleTerminalViewKey,
                                controller: _idleController,
                                scrollController: _idleScrollController,
                                theme: kTerminalThemeLight,
                                autoResize: true,
                                autofocus: true,
                                deleteDetection: deleteDetection,
                                hardwareKeyboardOnly: _useHardwareKeyboardOnly,
                                readOnly: _showHHKB,
                                keyboardType:
                                    _showHHKB
                                        ? TextInputType.none
                                        : TextInputType.text,
                                backgroundOpacity: 1.0,
                                padding: const EdgeInsets.all(10),
                                textStyle: buildTerminalStyle(fontSize: 12),
                              ),
                            );
                          }

                          final layout = _multiWindowLayoutController
                              .effectiveLayout(
                                displaySessions,
                                defaultColumns: columns,
                              );

                          return MultiWindowGrid(
                            padding: padding,
                            gap: 0,
                            desktopHitSize: 8,
                            mobileBreakpoint: 600,
                            scrollPhysics: const BouncingScrollPhysics(),
                            layout: layout,
                            onResizeColumn:
                                _multiWindowLayoutController.resizeColumn,
                            onResizeRow: _multiWindowLayoutController.resizeRow,
                            onResizeEnd:
                                () => unawaited(
                                  _multiWindowLayoutController.commit(),
                                ),
                            onMoveCell: (from, to, side) => unawaited(
                              _multiWindowLayoutController.moveCell(
                                fromSessionId: from,
                                toSessionId: to,
                                side: side,
                              ),
                            ),
                            cellBuilder: (context, sessionId, index) {
                              return TerminalWindowCard(
                                key: _terminalCardKeyFor(sessionId),
                                sessionId: sessionId,
                                terminal: _terminalFor(sessionId),
                                controller: _controllerFor(sessionId),
                                scrollController: _scrollControllerFor(
                                  sessionId,
                                ),
                                viewKey: _viewKeyFor(sessionId),
                                label: 'TERM ${index + 1}',
                                isActive: sessionId == _activeSessionId,
                                showHHKB: _showHHKB,
                                hardwareKeyboardOnly: _useHardwareKeyboardOnly,
                                isDragTarget:
                                    _dragging &&
                                    _dragTargetSessionId == sessionId,
                                onTap:
                                    () => _setActiveSession(
                                      sessionId,
                                      requestKeyboard: true,
                                    ),
                                onClose: () => _sendCloseSession(sessionId),
                              );
                            },
                          );
                        },
                      )
                      : TerminalView(
                        terminal,
                        key: _activeViewKey ?? _idleTerminalViewKey,
                        controller: controller,
                        scrollController: scrollController,
                        theme: kTerminalThemeLight,
                        autoResize: false,
                        autofocus: true,
                        deleteDetection: deleteDetection,
                        hardwareKeyboardOnly: _useHardwareKeyboardOnly,
                        readOnly: _showHHKB,
                        keyboardType:
                            _showHHKB ? TextInputType.none : TextInputType.text,
                        backgroundOpacity: 1.0,
                        padding: EdgeInsets.fromLTRB(
                          10,
                          4,
                          10,
                          _bottomBarHeight + 10,
                        ),
                        textStyle: buildTerminalStyle(fontSize: 12),
                      ),
                  if (_dragging && !_multiWindow)
                    Positioned.fill(
                      child: Container(
                        color: AppColors.accent.withValues(alpha: 0.12),
                      ),
                    ),
                  if (_reconnecting)
                    const Positioned.fill(child: AbsorbPointer()),
                ],
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.of(context).padding.top + terminalTopInset,
            left: 0,
            right: 0,
            height: 24,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      Colors.black.withValues(alpha: 0.06),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: HeaderChrome(
              color: barColor,
              activeColor: activeColor,
              overlayColor: overlayColor,
              error: null,
              pairingPending: _pairingPending,
              onAddSession: _sendCreateSession,
              sessions: _visibleSessions,
              activeSessionId: _activeSessionId,
              sessionLabelBuilder: (sessionId, index) {
                return _terminalManager.getTitle(sessionId) ??
                    _groupStore.getSessionName(sessionId, index);
              },
              onSelectSession:
                  (id) => _setActiveSession(id, requestKeyboard: true),
              onCloseSession: _sendCloseSession,
              onReorderSessions: _reorderSessions,
              connectionContent: _buildConnectionContent(context),
              multiWindow: _multiWindow,
              onToggleMultiWindow: () {
                setState(() => _multiWindow = !_multiWindow);
                _saveSettings();
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _scheduleActiveResize();
                });
              },
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  KeyedSubtree(
                    key: _quickBarKey,
                    child:
                        _showKeyboardTools
                            ? QuickActionsBar(
                              connected: _connected,
                              ctrl: _ctrl,
                              alt: _alt,
                              meta: _meta,
                              onToggleCtrl:
                                  () => setState(() => _ctrl = !_ctrl),
                              onToggleAlt: () => setState(() => _alt = !_alt),
                              onToggleMeta:
                                  () => setState(() => _meta = !_meta),
                              onKey: _sendKey,
                              onPaste: _pasteClipboard,
                              onCopy: _copySelection,
                              onSend: _sendRaw,
                              onScrollToBottom: _scrollToBottom,
                            )
                            : const SizedBox.shrink(),
                  ),
                  if (_showCommandInput)
                    CommandInputBar(
                      key: _commandInputKey,
                      readOnly: _showHHKB,
                      onSend: (text) {
                        _sendRaw(text);
                        _sendRaw('\r');
                      },
                    ),
                  if (_showHHKB &&
                      _chineseMode &&
                      (_pinyinEngine.hasInput || _pinyinEngine.hasCandidates))
                    CandidateBar(
                      pinyin: _pinyinEngine.displayPinyin,
                      candidates: _pinyinEngine.candidates,
                      onSelect: (index) {
                        final selected = _pinyinEngine.select(index);
                        if (selected != null) {
                          if (_hhkbToCommandInput) {
                            _commandInputKey.currentState?.insertText(selected);
                          } else {
                            _sendRaw(selected);
                          }
                        }
                      },
                    ),
                  if (_showHHKB)
                    HHKBKeyboard(
                      connected: _connected,
                      fn: _hhkbFn,
                      ctrl: _ctrl,
                      alt: _alt,
                      chineseMode: _chineseMode,
                      onToggleChineseMode: () {
                        // Commit any pending pinyin before toggling
                        if (_chineseMode && _pinyinEngine.hasInput) {
                          final raw = _pinyinEngine.commitRaw();
                          _sendRaw(raw);
                        }
                        setState(() => _chineseMode = !_chineseMode);
                        _saveSettings();
                      },
                      onScrollToBottom: _scrollToBottom,
                      onKey: (key, {bool isSpecial = false}) {
                        if (_chineseMode && !_ctrl && !_alt) {
                          final consumed = _handlePinyinKey(
                            key,
                            isSpecial: isSpecial,
                          );
                          if (consumed) {
                            return;
                          }
                        }
                        // Redirect to command input bar when both HHKB and input are active
                        if (_hhkbToCommandInput) {
                          final inputBar = _commandInputKey.currentState;
                          if (inputBar != null) {
                            if (key == '\r') {
                              inputBar.submit();
                            } else if (key == '\x7f' || key == '\b') {
                              inputBar.deleteBack();
                            } else if (!isSpecial && !_ctrl && !_alt) {
                              inputBar.insertText(key);
                            }
                            return;
                          }
                        }
                        if (_ctrl && !isSpecial) {
                          _sendCtrl(key);
                        } else if (_alt && !isSpecial) {
                          _sendRaw('\x1b$key');
                        } else {
                          _sendRaw(key);
                        }
                        // Reset modifiers after key press
                        if (_ctrl || _alt) {
                          setState(() {
                            _ctrl = false;
                            _alt = false;
                          });
                        }
                      },
                      onFnChanged: (fn) => setState(() => _hhkbFn = fn),
                      onToggleCtrl: () => setState(() => _ctrl = !_ctrl),
                      onToggleAlt: () => setState(() => _alt = !_alt),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );

    return scaffold;
  }

  Widget _buildConnectionContent(BuildContext context) {
    // Title: "Voyager · deviceName" or just "Voyager"
    final title =
        _remoteDeviceName != null && _remoteDeviceName!.isNotEmpty
            ? 'Voyager · $_remoteDeviceName'
            : 'Voyager';

    // Subtitle: transport-aware live state.
    String subtitle;
    if (_connected) {
      final kind = _connectionManager.activeTransportKind;
      switch (kind) {
        case TransportKind.lanDirect:
          subtitle = 'Connected via LAN';
          break;
        case TransportKind.wormholeRelay:
          subtitle = 'Connected via Wormhole';
          break;
        case TransportKind.wireguardDirect:
          subtitle = 'Connected via WireGuard Direct';
          break;
        case TransportKind.unknown:
          subtitle =
              _useWormhole ? 'Connected to Wormhole' : 'Connected to LAN';
          break;
      }
      final fallback = _connectionManager.activeFallbackReason;
      if (fallback != null && fallback.isNotEmpty) {
        subtitle = '$subtitle · fallback:$fallback';
      }
    } else {
      subtitle = 'Disconnected';
    }

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: SizedBox(
        height: 32, // 固定高度，避免 Switch/IconButton 在不同平台撑高 Row
        child: Row(
          children: [
            IconButton(
              icon: const Icon(
                Icons.menu,
                color: AppColors.textSecondary,
                size: 20,
              ),
              onPressed: () {
                _scaffoldKey.currentState?.openDrawer();
                _groupStore.setDeferredSync(true);
              },
              tooltip: 'Groups',
            ),
            const SizedBox(width: 4),
            ListenableBuilder(
              listenable: _vpnService,
              builder: (context, _) {
                final VpnRingState vpnState;
                if (!_vpnAvailable || !_vpnService.isActive) {
                  vpnState = VpnRingState.none;
                } else if (_vpnService.isConnected) {
                  vpnState = VpnRingState.connected;
                } else {
                  vpnState = VpnRingState.connecting;
                }
                return VpnStatusRing(
                  connected: _connected,
                  vpnState: vpnState,
                  size: 8,
                  ringWidth: 1.5,
                  ringGap: 2,
                );
              },
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.textPrimary,
                      fontSize: 14,
                      height: 1.1,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppColors.accent,
                      fontSize: 10,
                      height: 1.1,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.8,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 16),
            Switch(
              value: _connected,
              onChanged: (value) async {
                if (value) {
                  try {
                    await _connect();
                  } catch (e) {
                    if (mounted) {
                      _showError(e.toString());
                      setState(() {
                        _connected = false;
                      });
                    }
                  }
                } else {
                  _disconnectMainConnection();
                }
              },
            ),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(
                Icons.settings_outlined,
                color: AppColors.textSecondary,
                size: 20,
              ),
              onPressed: () => _scaffoldKey.currentState?.openEndDrawer(),
              tooltip: 'Settings',
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupDrawer(BuildContext context) {
    return GroupDrawer(
      embedded: false,
      manager: _groupStore,
      activeSessionId: _activeSessionId,
      onSelectSession:
          (sessionId) => _setActiveSession(sessionId, requestKeyboard: true),
      onCloseSession: _sendCloseSession,
      sessionLabelBuilder: (sessionId, index) {
        return _terminalManager.getTitle(sessionId) ??
            _groupStore.getSessionName(sessionId, index);
      },
    );
  }

  int _voyagerMultiWindowColumnsForWidth(double width) {
    if (width >= 2500) {
      return 5;
    }
    if (width >= 2000) {
      return 4;
    }
    if (width >= 1500) {
      return 3;
    }
    if (width >= 1000) {
      return 2;
    }
    return 1;
  }

  int _currentVoyagerMultiWindowColumns() {
    return _voyagerMultiWindowColumnsForWidth(MediaQuery.sizeOf(context).width);
  }

  void _resetMultiWindowLayout({required bool keepPaneOrder}) {
    unawaited(
      _multiWindowLayoutController.resetToFallback(
        sessionIds: _visibleSessions,
        columns: _currentVoyagerMultiWindowColumns(),
        keepPaneOrder: keepPaneOrder,
      ),
    );
    _scheduleActiveResize();
  }

  Widget _buildSettingsDrawer(BuildContext context) {
    return SettingsDrawer(
      useWormhole: _useWormhole,
      autoReconnect: _autoReconnect,
      multiWindow: _multiWindow,
      showKeyboardTools: _showKeyboardTools,
      showCommandInput: _showCommandInput,
      showHHKB: _showHHKB,
      urlController: _urlController,
      wormholeController: _wormholeController,
      sessionController: _sessionController,
      tokenController: _tokenController,
      onUseWormholeChanged: (value) {
        setState(() => _useWormhole = value);
        _saveSettings();
      },
      onAutoReconnectChanged: (value) {
        setState(() => _autoReconnect = value);
        _connectionManager.updateAutoReconnect(value);
        _saveSettings();
      },
      onMultiWindowChanged: (value) {
        setState(() => _multiWindow = value);
        _saveSettings();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scheduleActiveResize();
        });
      },
      onResetMultiWindowLayout:
          () => _resetMultiWindowLayout(keepPaneOrder: false),
      onEqualizeMultiWindowLayout:
          () => _resetMultiWindowLayout(keepPaneOrder: true),
      onShowKeyboardToolsChanged: (value) {
        setState(() {
          _showKeyboardTools = value;
          if (!value) {
            _quickBarHeight = 0;
          }
        });
        _saveSettings();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scheduleActiveResize();
        });
      },
      onShowCommandInputChanged: (value) {
        setState(() => _showCommandInput = value);
        _saveSettings();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scheduleActiveResize();
        });
      },
      onShowHHKBChanged: (value) {
        if (value) {
          // Dismiss system keyboard before HHKB takes over input.
          SystemChannels.textInput.invokeMethod('TextInput.hide');
        }
        setState(() => _showHHKB = value);
        _saveSettings();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scheduleActiveResize();
        });
      },
      vpnEnabled: _vpnEnabled,
      vpnService: _vpnAvailable ? _vpnService : null,
      onVpnEnabledChanged: _vpnAvailable ? _setVpnEnabled : null,
    );
  }

  void _setVpnEnabled(bool value) {
    if (_vpnEnabled == value) {
      return;
    }
    setState(() {
      _vpnEnabled = value;
    });
    unawaited(_saveSettings());

    if (!value) {
      _vpnUpgradeAttempted = false;
      _vpnNativeStartInFlight = false;
      _vpnConfigTimeout?.cancel();
      _vpnEndpointInfo = null;
      _vpnHandoff.reset();
      _vpnPrivateKey = null;
      _pendingVpnPublicKey = null;
      _vpnPublicKey = null;
      _vpnLocalPort = null;
      _vpnDirectCandidates = const <DirectCandidate>[];
      _lastAdvertisedVpnCandidateSignature = null;
      if (_vpnService.isActive) {
        unawaited(_vpnService.stop());
      }
      _vpnService.cancelPendingStart();
      return;
    }

    _vpnUpgradeAttempted = false;
    _vpnNativeStartInFlight = false;
    _maybeStartVpnUpgrade(force: true);
  }

  void _maybeStartVpnUpgrade({bool force = false}) {
    if (!_vpnAvailable || !_vpnEnabled) {
      return;
    }
    if (!_connected || _pairingPending) {
      return;
    }
    if (_connectionManager.activeTransportKind ==
        TransportKind.wireguardDirect) {
      return;
    }
    if (_vpnService.isActive ||
        _pendingVpnPublicKey != null ||
        _vpnPrivateKey != null) {
      return;
    }
    if (!force && _vpnUpgradeAttempted) {
      return;
    }
    _vpnUpgradeAttempted = true;
    unawaited(_requestVpnUpgrade());
  }

  Future<void> _requestVpnUpgrade() async {
    if (!_connected) {
      return;
    }

    _vpnService.beginNegotiation();
    _vpnNativeStartInFlight = false;

    // Generate keypair and send public key to Horizon for peer registration.
    // When the live path is Wormhole relay we first request endpoint_info so
    // we can use Horizon's observed UDP address instead of the tunnel's
    // internal server IP.
    Map<String, String> keypair;
    try {
      keypair = await _vpnService.generateKeypair();
    } on PlatformException catch (error) {
      _vpnService.failNegotiation(
        error.message ?? 'Native VPN plugin is unavailable.',
      );
      return;
    } catch (error) {
      _vpnService.failNegotiation('Failed to initialize native VPN: $error');
      return;
    }
    final privateKey = keypair['privateKey'] ?? '';
    final publicKey = keypair['publicKey'] ?? '';

    if (privateKey.isEmpty || publicKey.isEmpty) {
      _vpnService.failNegotiation('Failed to generate VPN keypair.');
      return;
    }

    _vpnPrivateKey = privateKey;
    _pendingVpnPublicKey = publicKey;
    _vpnPublicKey = publicKey;
    _lastAdvertisedVpnCandidateSignature = null;
    final localPort = _vpnLocalPort ??= _selectVpnLocalPort();
    _vpnDirectCandidates = await _buildVoyagerDirectCandidates(
      port: localPort,
      previous: _vpnEndpointInfo?.voyagerCandidates,
    );
    _vpnConfigTimeout?.cancel();
    _vpnConfigTimeout = Timer(const Duration(seconds: 12), () {
      if (!mounted || !_vpnService.isActive || _vpnService.isConnected) {
        return;
      }
      _pendingVpnPublicKey = null;
      _vpnPrivateKey = null;
      _vpnPublicKey = null;
      _vpnNativeStartInFlight = false;
      _vpnLocalPort = null;
      _vpnDirectCandidates = const <DirectCandidate>[];
      _lastAdvertisedVpnCandidateSignature = null;
      _vpnService.failNegotiation(
        'Timed out waiting for Horizon VPN config. Verify VPN is enabled on Horizon and restart the host if needed.',
      );
    });
    final activeTransport = _connectionManager.activeTransportKind;
    if (activeTransport == TransportKind.wormholeRelay) {
      _vpnLog('Requesting endpoint_info with local WG public key');
      _connectionManager.sendEndpointRequest(
        deviceKey: _deviceKey,
        wgPublicKey: publicKey,
        wgUdpPort: localPort,
        voyagerCandidates: _currentVoyagerDirectCandidates(),
      );
    } else {
      _vpnLog('Sending peer_endpoint directly over active transport');
      _sendVpnPeerEndpoint(publicKey, force: true);
      _pendingVpnPublicKey = null;
    }
  }

  void _handleVpnEndpointInfo(EndpointInfo info) async {
    if (!_vpnAvailable || !_vpnEnabled) {
      return;
    }
    _vpnEndpointInfo = _mergeVpnEndpointInfo(info);
    _vpnLog(
      'endpoint_info received: horizonAddr=${info.horizonAddr} wgUdpPort=${info.wgUdpPort} netcheck=${info.netcheckHost ?? "-"}:${info.netcheckPort ?? -1} hasWgPublicKey=${info.wgPublicKey != null}',
    );
    final pendingPublicKey = _pendingVpnPublicKey;
    if (pendingPublicKey != null && pendingPublicKey.isNotEmpty) {
      final localPort = _vpnLocalPort ??= _selectVpnLocalPort();
      _vpnDirectCandidates = await _buildVoyagerDirectCandidates(
        port: localPort,
        previous: _vpnEndpointInfo?.voyagerCandidates,
      );
      _vpnLog('Sending peer_endpoint after endpoint_info');
      _sendVpnPeerEndpoint(pendingPublicKey, force: true);
    }
  }

  void _handleVpnConfig(EndpointInfo info) {
    if (!_vpnAvailable || !_vpnEnabled) {
      return;
    }
    _vpnConfigTimeout?.cancel();
    final privateKey = _vpnPrivateKey;
    if (privateKey == null || privateKey.isEmpty) {
      _vpnService.failNegotiation(
        'Received vpn_config without a local keypair.',
      );
      return;
    }
    if (_vpnNativeStartInFlight || _vpnService.isConnected) {
      _vpnLog(
        'vpn_config received after native VPN start was already requested, ignoring duplicate',
      );
      return;
    }
    final mergedInfo = _mergeVpnEndpointInfo(info);
    _vpnEndpointInfo = mergedInfo;
    _pendingVpnPublicKey = null;
    _vpnLog(
      'vpn_config received: clientIp=${mergedInfo.clientIp} serverIp=${mergedInfo.serverIp} horizonAddr=${mergedInfo.horizonAddr} wgUdpPort=${mergedInfo.wgUdpPort} netcheck=${mergedInfo.netcheckHost ?? "-"}:${mergedInfo.netcheckPort ?? -1}',
    );
    if (mergedInfo.wgPublicKey == null) {
      _vpnService.failNegotiation(
        'vpn_config is missing Horizon WG public key.',
      );
      return;
    }
    final (netcheckHost, netcheckPort) = _deriveVpnNetcheckConfig(mergedInfo);
    _vpnLog(
      'netcheck target host=${netcheckHost ?? "-"} port=${netcheckPort ?? -1}',
    );
    _vpnNativeStartInFlight = true;
    unawaited(
      _vpnService
          .start(
            VpnConfig(
              privateKey: privateKey,
              peerPublicKey: mergedInfo.wgPublicKey!,
              // iOS tunnelRemoteAddress must be the public/routable address
              // (not LAN candidate) so iOS correctly routes tunnel UDP
              // through the physical interface. LAN candidates are passed
              // separately via directCandidates for the PacketTunnelProvider
              // to choose from.
              serverAddr:
                  mergedInfo.horizonAddr ?? _resolveVpnServerHost(mergedInfo),
              serverPort: mergedInfo.wgUdpPort ?? 51820,
              clientIp: mergedInfo.clientIp ?? '10.13.37.2',
              serverIp: mergedInfo.serverIp ?? '10.13.37.1',
              localPort: _vpnLocalPort,
              netcheckHost: netcheckHost,
              netcheckPort: netcheckPort,
              lanPort: mergedInfo.lanPort ?? 9527,
              subnet: mergedInfo.subnet ?? '10.13.37.0/24',
              dns: mergedInfo.dns ?? const ['10.13.37.1'],
              internalRoutes: mergedInfo.internalRoutes ?? [],
              mtu: mergedInfo.mtu ?? 1280,
              directCandidates:
                  (mergedInfo.horizonCandidates ?? const <DirectCandidate>[])
                      .map(
                        (candidate) => <String, dynamic>{
                          'addr': candidate.addr,
                          'port': candidate.port,
                          'scope': candidate.scope,
                          'priority': candidate.priority,
                          'source': candidate.source,
                        },
                      )
                      .toList(),
            ),
          )
          .catchError((Object error, StackTrace stackTrace) {
            _vpnNativeStartInFlight = false;
            _vpnPublicKey = null;
            _vpnLocalPort = null;
            _vpnDirectCandidates = const <DirectCandidate>[];
            _lastAdvertisedVpnCandidateSignature = null;
            _vpnLog('Failed to start native VPN: $error');
            debugPrintStack(stackTrace: stackTrace);
            _vpnService.failNegotiation('Failed to start native VPN: $error');
          }),
    );
  }

  int _selectVpnLocalPort() {
    final nowBits = DateTime.now().microsecondsSinceEpoch & 0x7fffffff;
    final seed = nowBits ^ (_deviceKey?.hashCode ?? _deviceName.hashCode);
    return 20000 + (seed % 20000);
  }

  (String?, int?) _deriveVpnNetcheckConfig(EndpointInfo info) {
    final explicitHost = info.netcheckHost?.trim();
    final explicitPort = info.netcheckPort;
    if (explicitHost != null &&
        explicitHost.isNotEmpty &&
        explicitPort != null &&
        explicitPort > 0) {
      return (explicitHost, explicitPort);
    }

    final rawUrl =
        _connectionManager.activeTransportKind == TransportKind.wormholeRelay
            ? _wormholeController.text.trim()
            : '';
    final uri = Uri.tryParse(rawUrl);
    if (uri == null || uri.host.isEmpty) {
      return (null, null);
    }
    final port =
        uri.hasPort
            ? uri.port
            : switch (uri.scheme) {
              'wss' || 'https' => 443,
              _ => 80,
            };
    return (uri.host, port);
  }

  Future<List<DirectCandidate>> _buildVoyagerDirectCandidates({
    required int port,
    List<DirectCandidate>? previous,
  }) async {
    final candidates = <DirectCandidate>[];

    void addCandidate(DirectCandidate candidate) {
      if (candidate.addr.isEmpty || candidate.port <= 0) {
        return;
      }
      final duplicate = candidates.any(
        (existing) =>
            existing.addr == candidate.addr &&
            existing.port == candidate.port &&
            existing.scope == candidate.scope,
      );
      if (!duplicate) {
        candidates.add(candidate);
      }
    }

    for (final candidate in previous ?? const <DirectCandidate>[]) {
      addCandidate(candidate);
    }

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final interface in interfaces) {
        for (final address in interface.addresses) {
          final host = address.address.trim();
          if (!_isUsableVpnDirectAddress(host)) {
            continue;
          }
          addCandidate(
            DirectCandidate(
              addr: host,
              port: port,
              scope: 'lan',
              priority: 250,
              source: 'local_interface:${interface.name}',
            ),
          );
        }
      }
    } catch (error) {
      _vpnLog('Failed to enumerate local interfaces: $error');
    }

    candidates.sort((a, b) => b.priority.compareTo(a.priority));
    return candidates;
  }

  List<DirectCandidate> _currentVoyagerDirectCandidates() {
    final candidates = <DirectCandidate>[];

    void addCandidate(DirectCandidate candidate) {
      if (candidate.addr.isEmpty || candidate.port <= 0) {
        return;
      }
      final duplicate = candidates.any(
        (existing) =>
            existing.addr == candidate.addr &&
            existing.port == candidate.port &&
            existing.scope == candidate.scope,
      );
      if (!duplicate) {
        candidates.add(candidate);
      }
    }

    for (final candidate in _vpnDirectCandidates) {
      addCandidate(candidate);
    }
    for (final raw in _vpnService.observedCandidates) {
      addCandidate(DirectCandidate.fromMap(raw));
    }
    candidates.sort((a, b) => b.priority.compareTo(a.priority));
    return candidates;
  }

  String _candidateSignature(List<DirectCandidate> candidates) {
    return candidates
        .map(
          (candidate) =>
              '${candidate.addr}:${candidate.port}/${candidate.scope}/${candidate.source}',
        )
        .join('|');
  }

  void _sendVpnPeerEndpoint(String publicKey, {bool force = false}) {
    final candidates = _currentVoyagerDirectCandidates();
    final signature = _candidateSignature(candidates);
    if (!force && signature == _lastAdvertisedVpnCandidateSignature) {
      return;
    }
    _lastAdvertisedVpnCandidateSignature = signature;
    _vpnLog(
      'Advertising peer_endpoint with ${candidates.length} direct candidate(s): '
      '${candidates.map((candidate) => '${candidate.addr}:${candidate.port}/${candidate.scope}/${candidate.source}').join(', ')}',
    );
    _connectionManager.sendPeerEndpoint(
      publicKey,
      deviceKey: _deviceKey,
      wgUdpPort: _vpnLocalPort,
      voyagerCandidates: candidates,
    );
  }

  bool _isUsableVpnDirectAddress(String host) {
    final address = InternetAddress.tryParse(host);
    if (address == null || address.type != InternetAddressType.IPv4) {
      return false;
    }
    final octets = address.rawAddress;
    if (octets.length != 4) {
      return false;
    }
    final a = octets[0];
    final b = octets[1];
    if (a == 0 || a == 127 || a == 169 && b == 254) {
      return false;
    }
    return a == 10 ||
        (a == 172 && b >= 16 && b <= 31) ||
        (a == 192 && b == 168) ||
        (a == 100 && b >= 64 && b <= 127);
  }

  EndpointInfo _mergeVpnEndpointInfo(EndpointInfo info) {
    return info.mergeWith(_vpnEndpointInfo);
  }

  String _resolveVpnServerHost(EndpointInfo info) {
    // Prefer a LAN candidate from Horizon when Voyager is on the same subnet —
    // avoids hairpin NAT failures when both devices share the same public IP.
    final hCandidates = info.horizonCandidates;
    final vCandidates = _vpnDirectCandidates;
    if (hCandidates != null) {
      for (final hc in hCandidates) {
        if (hc.scope == 'lan' && hc.addr.isNotEmpty) {
          // Check if Voyager has a LAN candidate on the same /24 subnet.
          final hParts = hc.addr.split('.');
          if (hParts.length == 4) {
            final hPrefix = '${hParts[0]}.${hParts[1]}.${hParts[2]}';
            final onSameLan = vCandidates.any(
              (vc) => vc.scope == 'lan' && vc.addr.startsWith('$hPrefix.'),
            );
            if (onSameLan) {
              _vpnLog('resolveVpnServerHost: using LAN candidate ${hc.addr}');
              return hc.addr;
            }
          }
        }
      }
    }

    final horizonAddr = info.horizonAddr;
    if (horizonAddr != null && horizonAddr.isNotEmpty) {
      return horizonAddr;
    }

    if (_connectionManager.activeTransportKind != TransportKind.wormholeRelay) {
      final lanUri = Uri.tryParse(_urlController.text.trim());
      final host = lanUri?.host;
      if (host != null && host.isNotEmpty) {
        return host;
      }
    }

    return info.serverIp ?? '10.13.37.1';
  }

  int _defaultVpnLanPort() {
    return _useWormhole ? 9529 : 9527;
  }

  VpnTunnelMode _currentVpnTunnelMode() {
    return switch (_vpnService.connectionMode) {
      VpnConnectionMode.direct => VpnTunnelMode.direct,
      VpnConnectionMode.unknown => VpnTunnelMode.unknown,
    };
  }

  VpnTransportEndpoint? _currentVpnTransportEndpoint() {
    final info = _vpnEndpointInfo;
    if (info == null) return null;
    // Use the resolved server host (LAN candidate or horizonAddr) instead of
    // the VPN subnet IP (10.13.37.1). macOS utun ptp routing prevents TCP
    // connections to the TUN local address from working, so we connect via
    // LAN/WAN and let Horizon identify it as a VPN peer by other means.
    final host = _resolveVpnServerHost(info);
    return VpnTransportEndpoint(
      serverIp: host,
      lanPort: info.lanPort ?? _defaultVpnLanPort(),
    );
  }

  void _onVpnStatusChanged() {
    if (!_vpnAvailable) return;
    if (!mounted) return;
    final snapshot = VpnTunnelSnapshot(
      isActive: _vpnService.isActive,
      isConnected: _vpnService.isConnected,
      mode: _currentVpnTunnelMode(),
      clientIp: _vpnService.clientIp,
      serverIp: _vpnService.serverIp,
      lanPort: _vpnService.lanPort,
      tunPacketsIn: _vpnService.tunPacketsIn,
      udpPacketsIn: _vpnService.udpPacketsIn,
      wgRxBytes: _vpnService.wgRxBytes,
      directSessionReady: _vpnService.directSessionReady,
      error: _vpnService.error,
    );
    final restoredEndpoint = _vpnHandoff.restoreEndpointFromNativeStatus(
      currentEndpoint: _currentVpnTransportEndpoint(),
      snapshot: snapshot,
      defaultLanPort: _defaultVpnLanPort(),
    );
    if (restoredEndpoint != null) {
      _vpnEndpointInfo = EndpointInfo(
        clientIp: _vpnService.clientIp,
        serverIp: _vpnService.serverIp,
        lanPort: restoredEndpoint.lanPort,
      );
      _vpnLog(
        'restored endpoint from native status: '
        'serverIp=${_vpnService.serverIp ?? "-"} '
        'lanPort=${restoredEndpoint.lanPort}',
      );
    }
    _vpnLog(
      'status=${_vpnService.status.name} mode=${_vpnService.connectionMode.name} '
      'active=${_vpnService.isActive} connected=${_vpnService.isConnected} '
      'clientIp=${_vpnService.clientIp ?? "-"} serverIp=${_vpnService.serverIp ?? "-"} '
      'lanPort=${_vpnService.lanPort ?? -1} '
      'tunOut=${_vpnService.tunPacketsOut ?? -1} tunIn=${_vpnService.tunPacketsIn ?? -1} '
      'udpOut=${_vpnService.udpPacketsOut ?? -1} udpIn=${_vpnService.udpPacketsIn ?? -1} '
      'wgTx=${_vpnService.wgTxBytes ?? -1} wgRx=${_vpnService.wgRxBytes ?? -1} '
      'error=${_vpnService.error ?? "-"}',
    );
    final activeVpnPublicKey = _vpnPublicKey;
    final activeTransport = _connectionManager.activeTransportKind;
    if (activeVpnPublicKey != null &&
        _connectionManager.connected &&
        activeTransport != TransportKind.wireguardDirect) {
      _sendVpnPeerEndpoint(activeVpnPublicKey);
    }
    final isConnected = _vpnService.isConnected;
    if (!_vpnService.isActive) {
      _vpnNativeStartInFlight = false;
    }
    if (isConnected) {
      _vpnConfigTimeout?.cancel();
    }
    final handoffEndpoint = _currentVpnTransportEndpoint();
    final handoffDecision = _vpnHandoff.onVpnStatusChanged(
      snapshot: snapshot,
      primaryConnectionConnected: _connectionManager.connected,
      activeTransportKind: _connectionManager.activeTransportKind,
      endpoint: handoffEndpoint,
    );
    if (handoffDecision.shouldSwitch || snapshot.directSessionReady == true) {
      debugPrint(
        '[VPN-Handoff] shouldSwitch=${handoffDecision.shouldSwitch} shouldFallback=${handoffDecision.shouldFallback} endpoint=${handoffEndpoint?.websocketUri} gate=${VpnTransportHandoffCoordinator.satisfiesDirectReadinessGate(snapshot)} udpIn=${snapshot.udpPacketsIn} tunIn=${snapshot.tunPacketsIn} wgRx=${snapshot.wgRxBytes} directReady=${snapshot.directSessionReady} transportKind=${_connectionManager.activeTransportKind}',
      );
    }
    if (handoffDecision.shouldSwitch) {
      _switchToVpnTransport(decision: handoffDecision);
    } else if (handoffDecision.shouldFallback) {
      _vpnConfigTimeout?.cancel();
      _fallbackToPrimaryTransport();
    }
    setState(() {});
  }

  void _disconnectMainConnection() {
    _reconnecting = false;
    _vpnHandoff.suppressNextFallback();
    _vpnConfigTimeout?.cancel();
    _vpnEndpointInfo = null;
    _vpnNativeStartInFlight = false;
    _vpnHandoff.cancelPendingSwitch();
    _vpnPrivateKey = null;
    _pendingVpnPublicKey = null;
    _vpnPublicKey = null;
    _vpnLocalPort = null;
    _vpnDirectCandidates = const <DirectCandidate>[];
    _lastAdvertisedVpnCandidateSignature = null;
    _connectionManager.disconnect(shouldReconnect: false);
    if (_vpnService.isConnected) {
      unawaited(_vpnService.stop());
    } else {
      _vpnService.cancelPendingStart();
    }
  }

  void _switchToVpnTransport({VpnTransportDecision? decision}) {
    final endpoint = decision?.endpoint ?? _currentVpnTransportEndpoint();
    if (endpoint == null) return;
    final vpnUri = endpoint.websocketUri;
    _vpnLog('Switching transport to $vpnUri');
    final vpnTransportKind =
        decision?.transportKind ??
        VpnTransportHandoffCoordinator.transportKindForMode(
          _currentVpnTunnelMode(),
        );
    Future<void>.delayed(const Duration(milliseconds: 750), () {
      if (!mounted || !_vpnService.isConnected) {
        return;
      }
      unawaited(
        _connectionManager.connect(
          uri: vpnUri,
          waitForPairing: false,
          autoReconnect: _autoReconnect,
          transportKind: vpnTransportKind,
          readyTimeout: const Duration(seconds: 5),
          handoffExisting: true,
        ),
      );
    });
  }

  void _fallbackToPrimaryTransport() {
    _vpnConfigTimeout?.cancel();
    _vpnNativeStartInFlight = false;
    _vpnPublicKey = null;
    _vpnLocalPort = null;
    _vpnDirectCandidates = const <DirectCandidate>[];
    _lastAdvertisedVpnCandidateSignature = null;
    _vpnLog('VPN disconnected, falling back to primary transport');
    _connectionManager.disconnect(silent: true);
    _connect(resetVpnUpgrade: false);
  }

  String _getDeviceType() {
    if (kIsWeb) {
      return 'web';
    }
    if (Platform.isIOS || Platform.isAndroid) {
      return 'mobile';
    }
    return 'desktop';
  }
}
