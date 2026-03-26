import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:characters/characters.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyager_share/voyager_share.dart' show buildTerminalStyle;
import 'package:xterm/xterm.dart';

import '../controllers/horizon_controller.dart';
import '../models/dev_mode_config.dart';
import '../models/terminal_group.dart';
import '../services/connection_manager.dart';
import '../services/daemon_manager.dart';
import '../services/group_store.dart';
import '../services/terminal_manager.dart';
import '../services/terminal_service.dart';
import '../widgets/dialogs/pairing_dialog.dart';
import '../widgets/keyboard/hhkb_keyboard.dart';
import '../widgets/quick_actions_bar.dart';
import '../widgets/session_card.dart';
import '../app.dart';

class HorizonHome extends StatefulWidget {
  const HorizonHome({super.key, required this.devModeConfig});

  final DevModeConfig devModeConfig;

  @override
  State<HorizonHome> createState() => _HorizonHomeState();
}

class _HorizonHomeState extends State<HorizonHome> with WidgetsBindingObserver {
  static const _defaultWormholeUrl = 'wss://wormhole.blackhole-ai.com/ws';
  static const _buildTimeToken = String.fromEnvironment('WORMHOLE_TOKEN');
  static const _systemChannel = MethodChannel('com.blackhole/system');
  static const _settingsChannel = WindowMethodChannel(
    'com.blackhole/settings',
    mode: ChannelMode.unidirectional,
  );

  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();
  final GlobalKey _quickBarKey = GlobalKey();
  final TextEditingController _urlController = TextEditingController(
    text: 'ws://127.0.0.1:9527',
  );
  final TextEditingController _wormholeController = TextEditingController(
    text: 'ws://127.0.0.1:8080/ws',
  );
  final TextEditingController _sessionController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  Timer? _metricsDebounce;
  Timer? _daemonPairingPoll;
  Timer? _settingsDebounce;

  late final HorizonController _hostController;
  final DaemonManager _daemonManager = DaemonManager();
  late final TextEditingController _hostWormholeUrlController;
  late final TextEditingController _hostWormholeTokenController;
  late final TextEditingController _hostCustomSessionController;
  bool _hostPairingDialogShown = false;

  late final ConnectionManager _connectionManager;
  late final TerminalManager _terminalManager;

  bool _connected = false;
  bool _autoReconnect = true;
  bool _useWormhole = false;
  bool _isHorizonMode = true; // true = Horizon (host), false = Voyager (client)
  bool _showKeyboardTools = true;
  bool _showHHKB = false;
  bool _hhkbFn = false;
  bool _multiWindow = false;
  bool _showSidebar = false;
  double _quickBarHeight = 0;
  static const double _hhkbKeyboardHeight = 250; // 5*42 + 4*6 + 16 padding
  final Set<String> _collapsedGroupIds = {};
  String _sidebarSearchQuery = '';
  String? _hoveredGroupId;
  String? _hoveredSessionRowId;
  String? _hoveredTabId;
  final ScrollController _tabScrollController = ScrollController();
  final ScrollController _groupScrollController = ScrollController();
  bool _showTabLeftFade = false;
  bool _showTabRightFade = false;
  bool _showGroupTopFade = false;
  bool _showGroupBottomFade = false;

  double get _bottomBarHeight =>
      (_showKeyboardTools ? _quickBarHeight : 0) +
      (_showHHKB ? _hhkbKeyboardHeight : 0);
  double _lastMetricsInsetsBottom = 0;
  Size _lastMetricsSize = Size.zero;

  final List<String> _sessions = [];
  final Set<String> _syncedSessions = {};
  String? _activeSessionId;
  late final GroupStore _groupStore;

  bool _ctrl = false;
  bool _alt = false;
  bool _meta = false;
  bool _dragging = false;
  String? _dragTargetSessionId;
  final Set<int> _topBarInteractivePointers = <int>{};

  // GlobalKeys for terminal cards in multi-window mode (for hit testing)
  final Map<String, GlobalKey> _terminalCardKeys = {};

  // Track settings window to prevent multiple instances
  static WindowController? _settingsWindowController;

  String? _error;
  bool _createSessionInFlight = false;
  int _createSessionRequestId = 0;

  // Device pairing related state
  String? _deviceKey;
  String _deviceName = '';
  bool _clientPairingPending = false;
  bool _hostConfigSynced = false;

  // Local mode (Horizon) output subscription
  StreamSubscription<TerminalOutput>? _localOutputSub;
  static const bool _logTerminalOutput = bool.fromEnvironment(
    'BH_LOG_TERMINAL_OUTPUT',
    defaultValue: true,
  );
  static const Duration _enterProbeWindow = Duration(milliseconds: 1200);
  String? _terminalOutputLogPath;
  String? _terminalInputLogPath;
  DateTime? _enterProbeUntil;
  String? _enterProbeSessionId;
  String? _enterProbeInput;

  // CWD polling for local sessions (Horizon mode)
  Timer? _cwdPollTimer;
  final Map<String, String> _sessionCwds = {};
  static const Duration _cwdPollInterval = Duration(seconds: 2);

  // Daemon status polling (for native/macOS settings driven daemon)
  Timer? _daemonStatusPoll;
  DaemonStatus? _daemonStatus;

  List<String> get _visibleSessions => _groupStore.activeGroupSessionIds;

  // Daemon architecture: even in "server" mode we connect via WebSocket.
  // In-process fallback: when daemon binary is unavailable, _hostController
  // runs the WS server directly, so we consider the system active if either
  // the WebSocket client is connected OR the in-process host is running.
  bool get _usingDirectLocalPty => false;
  bool get _isSystemActive =>
      _connected || (_isHorizonMode && _hostController.running);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _hostController = HorizonController(
      devModeRequested: widget.devModeConfig.requested,
      requireDevModeConfirmation: widget.devModeConfig.requiresConfirmation,
    );
    _terminalManager = TerminalManager(
      onInput: _handleTerminalInput,
      onResize: _handleResize,
      onTitleChange: (sessionId, title) {
        if (mounted) setState(() {});
        if (sessionId == _activeSessionId) {
          _updateWindowTitle();
        }
      },
      logPrefix: 'Horizon',
    );
    _connectionManager = ConnectionManager(
      onConnected: ({required waitForPairing}) {
        if (!waitForPairing) {
          _sendListSessions();
        }
        _terminalManager.activeViewKey?.currentState?.requestKeyboard();
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
          _clientPairingPending = pending;
        });
      },
      onHostInfo: (hostName) {
        // Currently unused in UI; keep callback to avoid breaking protocol.
      },
      onError: (message) {
        if (!mounted) {
          return;
        }
        setState(() {
          _error = message;
          _clientPairingPending = false;
        });
      },
      onGroupSync: (payload) {
        _groupStore.applySync(payload);
      },
      onGroupError: (message) {
        if (!mounted) {
          return;
        }
        setState(() {
          _error = 'Group error: $message';
        });
      },
      onPairingResult: ({required approved, String? assignedKey}) {
        if (approved) {
          if (assignedKey != null && assignedKey.isNotEmpty) {
            _deviceKey = assignedKey;
            _saveSettings();
          }
          if (mounted) {
            setState(() {
              _clientPairingPending = false;
              _error = null;
            });
          }
          debugPrint('[Voyager] Pairing approved, deviceKey: $_deviceKey');
          _sendListSessions();
        } else {
          if (mounted) {
            setState(() {
              _clientPairingPending = false;
              _error = 'Connection rejected';
              _connected = false;
            });
          }
          debugPrint('[Voyager] Pairing rejected');
        }
      },
      onSessionList: _handleSessionList,
      onSessionCreated: _handleRemoteSessionCreated,
      onSessionClosed: _handleRemoteSessionClosed,
      onStdout: _handleStdout,
      onStdoutBytes: _handleStdoutBytes,
      onCwd: _handleCwd,
      onSessionSync: _handleSessionSync,
    );
    _groupStore = GroupStore(
      onChanged: _handleGroupChange,
      sendCommand: _sendGroupCommand,
    );
    unawaited(_groupStore.loadLocalOrder());
    _hostWormholeUrlController = TextEditingController(
      text: _hostController.wormholeBaseUrl,
    );
    _hostWormholeTokenController = TextEditingController(
      text: _hostController.wormholeToken,
    );
    _hostCustomSessionController = TextEditingController(
      text: _hostController.customSessionId,
    );
    _hostCustomSessionController.addListener(_syncHostCustomSession);
    _hostController.addListener(_handleHostChange);
    _urlController.addListener(_handleAddressChange);
    _wormholeController.addListener(_handleAddressChange);
    _sessionController.addListener(_saveSettings);
    _tokenController.addListener(_saveSettings);
    _tabScrollController.addListener(_updateTabFades);
    _groupScrollController.addListener(_updateGroupFades);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateTabFades();
      _updateGroupFades();
    });
    _setupSystemChannel();
    _setupSettingsChannel();
    _loadSettings();
  }

  void _setupSystemChannel() {
    _systemChannel.setMethodCallHandler((call) async {
      if (call.method == 'settingsChanged') {
        _handleNativeSettingsChanged();
      } else if (call.method == 'toggleMultiWindow') {
        _toggleMultiWindow();
      } else if (call.method == 'getMultiWindowState') {
        return _multiWindow;
      } else if (call.method == 'openSettings') {
        _openSettings();
      }
      return null;
    });
  }

  void _setupSettingsChannel() {
    _settingsChannel.setMethodCallHandler((call) async {
      if (call.method == 'settingsChanged') {
        _handleNativeSettingsChanged();
      }
      return null;
    });
  }

  Future<void> _openSettings() async {
    if (!mounted) return;

    // Check if settings window already exists
    if (_settingsWindowController != null) {
      try {
        await _settingsWindowController!.show();
        return;
      } catch (_) {
        // Window was closed, create a new one
        _settingsWindowController = null;
      }
    }

    final controller = await WindowController.create(
      WindowConfiguration(hiddenAtLaunch: true, arguments: 'settings'),
    );
    _settingsWindowController = controller;
  }

  void _toggleMultiWindow() {
    setState(() => _multiWindow = !_multiWindow);
    _saveSettings();
    _notifyNativeMultiWindowState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _scheduleActiveResize();
    });
  }

  Future<void> _notifyNativeMultiWindowState() async {
    try {
      await _systemChannel.invokeMethod('multiWindowChanged', _multiWindow);
    } catch (e) {
      // Ignore if native side isn't ready yet
      debugPrint('[Horizon] Native multiWindowChanged not ready: $e');
    }
  }

  void _handleNativeSettingsChanged() {
    // Debounce to prevent multiple rapid calls from causing redundant daemon restarts.
    _settingsDebounce?.cancel();
    _settingsDebounce = Timer(const Duration(milliseconds: 300), () {
      debugPrint('[Horizon] Native settings changed, reloading...');
      // Re-apply config from native settings and restart daemon if needed.
      _reloadAppMode();
    });
  }

  int? _readInt(dynamic value) {
    if (value is int) return value;
    if (value is String) return int.tryParse(value.trim());
    return null;
  }

  bool _readBool(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    if (value is String) {
      final v = value.trim().toLowerCase();
      if (v == 'true') return true;
      if (v == 'false') return false;
    }
    return fallback;
  }

  String? _readString(dynamic value) {
    if (value is! String) return null;
    final trimmed = value.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  String _resolveDefaultWormholeUrl() {
    final envUrl = _readString(Platform.environment['WORMHOLE_URL']);
    return envUrl ?? _defaultWormholeUrl;
  }

  String? _resolveDefaultWormholeToken() {
    final envToken = _readString(Platform.environment['WORMHOLE_TOKEN']);
    if (envToken != null) {
      return envToken;
    }
    final trimmed = _buildTimeToken.trim();
    return trimmed.isEmpty ? null : trimmed;
  }

  Future<void> _ensureLocalDaemonFromNativeSettings() async {
    final nativeSettings = await _readNativeSettings();
    // Fire-and-forget: don't block startup on VPN helper (may show password dialog)
    unawaited(_ensureNativeVpnHelper());
    final lanEnabled = _readBool(nativeSettings['lanEnabled'], fallback: true);
    final lanPort = _readInt(nativeSettings['lanPort']) ?? 9527;
    final hostName = _readString(nativeSettings['hostName']) ?? _deviceName;
    final vpnEnabled = _readBool(nativeSettings['vpnEnabled'], fallback: false);

    final wormholeEnabled = _readBool(
      nativeSettings['wormholeEnabled'],
      fallback: false,
    );
    final defaultWormholeUrl = _resolveDefaultWormholeUrl();
    final defaultWormholeToken = _resolveDefaultWormholeToken();
    final savedWormholeUrl = _readString(nativeSettings['wormholeBaseUrl']);
    final wormholeUrl =
        wormholeEnabled ? (savedWormholeUrl ?? defaultWormholeUrl) : null;
    final savedWormholeToken = _readString(nativeSettings['wormholeToken']);
    final useDefaultWormholeToken =
        savedWormholeToken == null && wormholeUrl == defaultWormholeUrl;
    final wormholeToken =
        wormholeEnabled
            ? (savedWormholeToken ??
                (useDefaultWormholeToken ? defaultWormholeToken : null))
            : null;

    final customSessionEnabled = _readBool(
      nativeSettings['customSessionEnabled'],
      fallback: false,
    );
    final wormholeSession =
        customSessionEnabled
            ? _readString(nativeSettings['customSessionId'])
            : null;

    // Flutter connects to the daemon over loopback; LAN exposure is controlled by bindHost.
    final wsUri = Uri(
      scheme: 'ws',
      host: '127.0.0.1',
      port: lanPort,
      path: '/ws',
    );
    setState(() {
      _urlController.text = wsUri.toString();
      _useWormhole = false;
    });

    // Ensure local PTY host isn't accidentally running (would conflict on port).
    await _hostController.stop();

    final bindHost = _desiredDaemonBindHost(lanEnabled: lanEnabled);
    final started = await _daemonManager.ensureRunning(
      wsUri: wsUri,
      hostName: hostName,
      devMode: widget.devModeConfig.requested,
      vpnRequired: vpnEnabled,
      wormholeUrl: wormholeUrl,
      wormholeToken: wormholeToken,
      wormholeSession: wormholeSession,
      bindHost: bindHost,
    );
    if (started) {
      _startDaemonStatusPolling(wsUri);
      _startDaemonPairingPolling(wsUri);
      _maybeAutoConnectLocal();
    } else {
      // Daemon binary not available — fall back to in-process HorizonController.
      debugPrint(
        '[Horizon] Daemon unavailable, falling back to in-process host',
      );
      _hostController.setHostDeviceName(hostName);
      await _hostController.start();
      if (_hostController.running) {
        _subscribeLocalOutput();
        _maybeAutoConnectLocal();
      } else {
        // In-process host failed (e.g. port already in use by another instance).
        // Try connecting to the existing server on that port as a client fallback.
        debugPrint(
          '[Horizon] In-process host failed: ${_hostController.error ?? "unknown"}, '
          'trying to connect to existing server on port $lanPort',
        );
        // Attempt to connect as client; if that also fails, try killing the
        // orphaned process and restarting the in-process host.
        await _connectOrRecoverPort(wsUri, hostName);
      }
    }
  }

  Future<void> _reloadAppMode() async {
    final nativeSettings = await _readNativeSettings();
    final appMode = nativeSettings['appMode'] as String? ?? 'server';
    debugPrint('[Mode] Native settings changed: appMode=$appMode');

    if (appMode == 'client') {
      if (mounted) {
        setState(() {
          _isHorizonMode = false;
        });
      } else {
        _isHorizonMode = false;
      }

      // Switching into client mode: clear local state and connect using native settings.
      _unsubscribeLocalOutput();
      _stopCwdPolling();
      _sessionCwds.clear();
      _sessions.clear();
      _syncedSessions.clear();
      _activeSessionId = null;
      _terminalManager.activeSessionId = null;
      _terminalManager.clear();

      final connectionType =
          nativeSettings['clientConnectionType'] as String? ?? 'lan';
      final isRemote = connectionType == 'remote';

      if (isRemote) {
        // Remote mode: connect via wormhole
        final remoteServer =
            nativeSettings['clientRemoteServer'] as String? ?? '';
        final remoteSession =
            nativeSettings['clientRemoteSession'] as String? ?? '';
        final remoteToken =
            nativeSettings['clientRemoteToken'] as String? ?? '';

        if (remoteServer.isNotEmpty && remoteSession.isNotEmpty) {
          debugPrint(
            '[Mode] Client remote: server=$remoteServer session=$remoteSession',
          );
          setState(() {
            _wormholeController.text = remoteServer;
            _sessionController.text = remoteSession;
            _tokenController.text = remoteToken;
            _useWormhole = true;
          });
          _connectionManager.disconnect(shouldReconnect: false);
          await _connect();
        }
      } else {
        // LAN mode: connect to specified host
        final lanUrl = nativeSettings['clientLanUrl'] as String? ?? '';
        if (lanUrl.isNotEmpty) {
          debugPrint('[Mode] Client LAN: url=$lanUrl');
          setState(() {
            _urlController.text = lanUrl;
            _useWormhole = false;
          });
          _connectionManager.disconnect(shouldReconnect: false);
          // If connecting to local address, ensure daemon is running
          final wsUri = Uri.tryParse(lanUrl);
          if (wsUri != null && DaemonManager.isLocalWs(wsUri)) {
            debugPrint('[Mode] Client LAN local: starting daemon');
            await _ensureLocalDaemonFromNativeSettings();
          } else {
            await _connect();
          }
        }
      }
    } else {
      debugPrint('[Mode] Server mode: connecting to local daemon');
      if (mounted) {
        setState(() {
          _isHorizonMode = true;
          _useWormhole = false;
        });
      } else {
        _isHorizonMode = true;
        _useWormhole = false;
      }

      await _ensureLocalDaemonFromNativeSettings();
    }

    if (mounted) {
      setState(() {});
    }
  }

  Future<Map<String, dynamic>> _readNativeSettings() async {
    try {
      final home = Platform.environment['HOME'] ?? '';
      if (home.isEmpty) return {};
      final settingsPath = '$home/.blackhole/horizon/settings.json';
      final file = File(settingsPath);
      if (!await file.exists()) return {};
      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;
      return json['settings'] as Map<String, dynamic>? ?? {};
    } catch (e) {
      debugPrint('[Mode] Failed to read native settings: $e');
      return {};
    }
  }

  Future<String> _readAppModeFromNativeSettings() async {
    final settings = await _readNativeSettings();
    return settings['appMode'] as String? ?? 'server';
  }

  Future<void> _ensureNativeVpnHelper() async {
    if (!Platform.isMacOS) {
      return;
    }
    try {
      final status = await _systemChannel.invokeMapMethod<String, dynamic>(
        'ensureVpnHelper',
      );
      if (status != null) {
        debugPrint('[VPN Helper] ${jsonEncode(status)}');
      }
    } on PlatformException catch (error) {
      debugPrint('[VPN Helper] Failed to ensure helper: ${error.message}');
    } catch (error) {
      debugPrint('[VPN Helper] Failed to ensure helper: $error');
    }
  }

  Future<void> _loadSettings() async {
    final prefs = await SharedPreferences.getInstance();
    final savedDeviceName = prefs.getString('deviceName');
    // Re-fetch device name if saved value is a generic name
    final needsRefresh = _isGenericDeviceName(savedDeviceName);
    final deviceName =
        needsRefresh ? await _getDefaultDeviceName() : savedDeviceName!;
    debugPrint(
      '[Device] Horizon deviceName=$deviceName saved=${savedDeviceName ?? "null"} needsRefresh=$needsRefresh',
    );
    if (needsRefresh && savedDeviceName != deviceName) {
      await prefs.setString('deviceName', deviceName);
    }
    // Read app mode from native settings file
    final appMode = await _readAppModeFromNativeSettings();
    debugPrint('[Mode] Native appMode=$appMode');
    setState(() {
      _urlController.text =
          prefs.getString('lanAddress') ?? 'ws://127.0.0.1:9527/ws';
      _wormholeController.text =
          prefs.getString('wormholeAddress') ?? 'ws://127.0.0.1:8080/ws';
      _sessionController.text = prefs.getString('sessionId') ?? '';
      _tokenController.text = prefs.getString('token') ?? '';
      _useWormhole = prefs.getBool('useWormhole') ?? false;
      _autoReconnect = prefs.getBool('autoReconnect') ?? true;
      _multiWindow = prefs.getBool('multiWindow') ?? false;
      _showKeyboardTools = prefs.getBool('showKeyboardTools') ?? true;
      _showHHKB = prefs.getBool('showHHKB') ?? false;
      _isHorizonMode = appMode == 'server';
      _deviceKey = prefs.getString('deviceKey');
      _deviceName = deviceName;
    });
    _hostController.setHostDeviceName(deviceName);
    _connectionManager.updateAutoReconnect(_autoReconnect);

    // Notify native about initial multiWindow state (delay to ensure native is ready)
    Future.delayed(
      const Duration(milliseconds: 100),
      _notifyNativeMultiWindowState,
    );

    // Apply mode/config from native settings and connect.
    unawaited(_reloadAppMode());
  }

  void _handleGroupChange() {
    if (!mounted) {
      return;
    }
    _collapsedGroupIds.removeWhere(
      (id) => !_groupStore.groups.any((group) => group.id == id),
    );
    // Request sync for all sessions in the new group (Voyager mode only)
    for (final sessionId in _visibleSessions) {
      _requestSyncIfNeeded(sessionId);
    }
    setState(() {
      _syncActiveSessionWithGroup();
    });
  }

  void _handleHostChange() {
    if (!mounted) {
      return;
    }
    if (_hostController.running) {
      if (!_hostConfigSynced) {
        _safeSetText(
          _hostWormholeUrlController,
          _hostController.wormholeBaseUrl,
        );
        _safeSetText(
          _hostWormholeTokenController,
          _hostController.wormholeToken,
        );
        _safeSetText(
          _hostCustomSessionController,
          _hostController.customSessionId,
        );
        _hostConfigSynced = true;
      }
      // Always subscribe to local output (for Horizon mode data)
      if (_localOutputSub == null) {
        _subscribeLocalOutput();
        // If in Horizon mode and no sessions, load local sessions
        if (_isHorizonMode && _sessions.isEmpty) {
          _loadLocalSessions();
        }
      }
      // Only auto-connect when acting as a client (Voyager mode).
      if (!_isHorizonMode) {
        _maybeAutoConnectLocal();
      }
      return;
    }
    if (_isHorizonMode) {
      _sessions.clear();
      _activeSessionId = null;
      _terminalManager.activeSessionId = null;
      _terminalManager.clear();
      _stopCwdPolling();
      _sessionCwds.clear();
      setState(() {});
    }
  }

  void _subscribeLocalOutput() {
    _unsubscribeLocalOutput();
    _localOutputSub = _hostController.localOutputStream.listen(
      _handleLocalOutput,
      onError: (error) {
        debugPrint('[Horizon Local] Output error: $error');
      },
    );
  }

  void _unsubscribeLocalOutput() {
    _localOutputSub?.cancel();
    _localOutputSub = null;
  }

  void _handleLocalOutput(TerminalOutput output) {
    // Only process if in Horizon mode (direct local access)
    if (!_isHorizonMode) {
      return;
    }
    _logTerminalOutputBytes(
      output.sessionId,
      output.data,
      note: _currentEnterProbeNote(output.sessionId),
    );
    _terminalManager.writeToTerminalBytes(output.sessionId, output.data);
    // Note: No setState needed - TerminalView auto-updates via Terminal's notifyListeners
  }

  bool get _useLocalOutputMirror =>
      _isHorizonMode && _localOutputSub != null && !_usingDirectLocalPty;

  bool _containsEnterInput(String data) {
    return data.contains('\r') || data.contains('\n');
  }

  String _armEnterProbeIfNeeded(String sessionId, String data) {
    if (!_containsEnterInput(data)) {
      return '';
    }
    final escaped = _escapeControlCharacters(data);
    _enterProbeSessionId = sessionId;
    _enterProbeInput = escaped;
    _enterProbeUntil = DateTime.now().add(_enterProbeWindow);
    return 'probe=enter input=$escaped';
  }

  String _currentEnterProbeNote(String sessionId) {
    final until = _enterProbeUntil;
    if (until == null || DateTime.now().isAfter(until)) {
      _enterProbeUntil = null;
      _enterProbeSessionId = null;
      _enterProbeInput = null;
      return '';
    }
    if (_enterProbeSessionId != sessionId) {
      return '';
    }
    final input = _enterProbeInput;
    return input == null || input.isEmpty
        ? 'probe=enter'
        : 'probe=enter input=$input';
  }

  bool _isTransientCreateError(String? value) {
    if (value == null || value.isEmpty) {
      return false;
    }
    return value.startsWith('Connection is offline') ||
        value.startsWith('Create session failed');
  }

  void _logTerminalOutputBytes(
    String sessionId,
    Uint8List data, {
    String note = '',
  }) {
    if (!_logTerminalOutput || data.isEmpty) {
      return;
    }
    final path =
        _terminalOutputLogPath ??= _terminalLogPath(
          'blackhole_terminal_output.log',
        );
    final timestamp = DateTime.now().toIso8601String();
    final noteSuffix = note.isNotEmpty ? ' note=$note' : '';
    final decoded = utf8.decode(data, allowMalformed: true);
    final buffer =
        StringBuffer()..writeln(
          '[$timestamp] session=$sessionId bytes=${data.length}$noteSuffix',
        );
    _writeHexLines(buffer, data);
    buffer
      ..writeln('text: ${_escapeControlCharacters(decoded)}')
      ..writeln('---');
    _appendTerminalLog(path, buffer.toString(), label: 'output');
  }

  void _logTerminalInputEvent(
    String stage,
    String sessionId,
    String data, {
    String note = '',
  }) {
    if (data.isEmpty) {
      return;
    }
    final path =
        _terminalInputLogPath ??= _terminalLogPath(
          'blackhole_terminal_input.log',
        );
    final bytes = Uint8List.fromList(utf8.encode(data));
    final timestamp = DateTime.now().toIso8601String();
    final buffer =
        StringBuffer()..writeln(
          '[$timestamp] stage=$stage session=$sessionId bytes=${bytes.length} ctrl=$_ctrl alt=$_alt meta=$_meta note=$note',
        );
    _writeHexLines(buffer, bytes);
    buffer
      ..writeln('text: ${_escapeControlCharacters(data)}')
      ..writeln('---');
    _appendTerminalLog(path, buffer.toString(), label: 'input');
  }

  String _terminalLogPath(String fileName) {
    final path = Directory.systemTemp.uri.resolve(fileName).toFilePath();
    debugPrint('[Horizon] Logging terminal to $path');
    return path;
  }

  void _appendTerminalLog(
    String path,
    String content, {
    required String label,
  }) {
    try {
      File(
        path,
      ).writeAsStringSync(content, mode: FileMode.writeOnlyAppend, flush: true);
    } catch (error) {
      debugPrint('[Horizon] Failed to append terminal $label log: $error');
    }
  }

  void _appendTerminalTrace(String line) {
    final path =
        Directory.systemTemp.uri
            .resolve('blackhole_terminal_trace.log')
            .toFilePath();
    try {
      File(path).writeAsStringSync(
        '[${DateTime.now().toIso8601String()}] $line\n',
        mode: FileMode.writeOnlyAppend,
        flush: true,
      );
    } catch (_) {
      // Best-effort tracing only.
    }
  }

  void _writeHexLines(StringBuffer buffer, Uint8List data) {
    const bytesPerLine = 32;
    for (int i = 0; i < data.length; i += bytesPerLine) {
      final end = (i + bytesPerLine).clamp(0, data.length);
      final lineBuffer = StringBuffer();
      for (int j = i; j < end; j++) {
        lineBuffer.write(data[j].toRadixString(16).padLeft(2, '0'));
        if (j + 1 < end) {
          lineBuffer.write(' ');
        }
      }
      buffer.writeln(lineBuffer.toString());
    }
  }

  String _escapeControlCharacters(String text) {
    final buffer = StringBuffer();
    for (final codeUnit in text.codeUnits) {
      if (codeUnit == 0x0A) {
        buffer.write(r'\n');
      } else if (codeUnit == 0x0D) {
        buffer.write(r'\r');
      } else if (codeUnit == 0x09) {
        buffer.write(r'\t');
      } else if (codeUnit < 0x20 || codeUnit == 0x7F) {
        buffer.write(r'\x');
        buffer.write(codeUnit.toRadixString(16).padLeft(2, '0'));
      } else {
        buffer.writeCharCode(codeUnit);
      }
    }
    return buffer.toString();
  }

  void _loadLocalSessions() {
    final localSessions = _hostController.localSessions;
    debugPrint('[Mode] Loading local sessions: ${localSessions.length}');
    _sessions
      ..clear()
      ..addAll(localSessions);

    // If no sessions exist, create one
    if (_sessions.isEmpty) {
      debugPrint('[Mode] No local sessions, creating one');
      _createLocalSession();
      return;
    }

    // Apply group sync
    final syncPayload = _hostController.getLocalGroupSync();
    _groupStore.applySync(syncPayload);

    // Set active session
    _syncActiveSessionWithGroup();
    // Fall back to first session if group not ready
    if (_activeSessionId == null && _sessions.isNotEmpty) {
      _activeSessionId = _sessions.first;
    }
    debugPrint('[Mode] Active session: $_activeSessionId');
    _terminalManager.activeSessionId = _activeSessionId;
    if (_activeSessionId != null) {
      _terminalFor(_activeSessionId!);
    }

    if (mounted) {
      setState(() {});
    }
    _scheduleActiveResize();
    if (_activeSessionId != null) {
      _restoreScrollOffset(_activeSessionId!);
    }
    // Start cwd polling after loading sessions
    _startCwdPolling();
  }

  void _startCwdPolling() {
    _stopCwdPolling();
    if (!_isHorizonMode) {
      return;
    }
    if (!_usingDirectLocalPty && !_connected) {
      return;
    }
    // Poll immediately once
    _pollSessionCwds();
    // Then poll periodically
    _cwdPollTimer = Timer.periodic(_cwdPollInterval, (_) {
      _pollSessionCwds();
    });
  }

  void _stopCwdPolling() {
    _cwdPollTimer?.cancel();
    _cwdPollTimer = null;
  }

  Future<void> _pollSessionCwds() async {
    if (!_isHorizonMode) {
      return;
    }
    if (_usingDirectLocalPty) {
      for (final sessionId in _sessions) {
        final cwd = await _hostController.getLocalCwd(sessionId);
        if (cwd == null || cwd.isEmpty) {
          continue;
        }
        final oldCwd = _sessionCwds[sessionId];
        if (oldCwd != cwd) {
          _sessionCwds[sessionId] = cwd;
        }
      }
      if (mounted) {
        setState(() {});
      }
      return;
    }
    if (!_connected) {
      return;
    }
    for (final sessionId in _sessions) {
      _connectionManager.sendCommand({
        'type': 'getCwd',
        'sessionId': sessionId,
      });
    }
  }

  void _handleCwd(String sessionId, String cwd) {
    if (!_isHorizonMode) {
      return;
    }
    if (cwd.isEmpty) {
      return;
    }
    final oldCwd = _sessionCwds[sessionId];
    if (oldCwd == cwd) {
      return;
    }
    _sessionCwds[sessionId] = cwd;
    if (mounted) {
      setState(() {});
    }
  }

  String? _getCwdDisplayName(String sessionId) {
    final cwd = _sessionCwds[sessionId];
    if (cwd == null || cwd.isEmpty) {
      return null;
    }
    // Extract the last component of the path
    final parts = cwd.split('/');
    final name = parts.isNotEmpty ? parts.last : cwd;
    // Handle home directory case (empty name means root of path)
    if (name.isEmpty && parts.length > 1) {
      return parts[parts.length - 2];
    }
    return name.isEmpty ? cwd : name;
  }

  void _showPairingDialog(PendingPairing pending) {
    if (_hostPairingDialogShown) {
      return;
    }
    _hostPairingDialogShown = true;

    _showPairingDialogWith(
      deviceName: pending.deviceName,
      onApprove:
          (remember) => _hostController.approvePairing(remember: remember),
      onReject: _hostController.rejectPairing,
    );
  }

  void _showPairingDialogWith({
    required String deviceName,
    required void Function(bool remember) onApprove,
    required VoidCallback onReject,
  }) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => PairingDialog(
            deviceName: deviceName,
            onApprove: (remember) {
              Navigator.of(context).pop();
              _hostPairingDialogShown = false;
              onApprove(remember);
            },
            onReject: () {
              Navigator.of(context).pop();
              _hostPairingDialogShown = false;
              onReject();
            },
          ),
    );
  }

  void _syncHostCustomSession() {
    unawaited(_ensureDaemonHostConfig());
  }

  String _desiredDaemonBindHost({required bool lanEnabled}) {
    return lanEnabled ? '0.0.0.0' : '127.0.0.1';
  }

  Future<void> _ensureDaemonHostConfig() async {
    final wsUri = Uri.tryParse(_urlController.text.trim());
    if (wsUri == null || !DaemonManager.isLocalWs(wsUri)) {
      return;
    }
    final nativeSettings = await _readNativeSettings();
    final lanEnabled = _readBool(nativeSettings['lanEnabled'], fallback: true);
    final vpnEnabled = _readBool(nativeSettings['vpnEnabled'], fallback: false);
    await _ensureNativeVpnHelper();
    await _daemonManager.ensureRunning(
      wsUri: wsUri,
      hostName: _deviceName,
      devMode: widget.devModeConfig.requested,
      vpnRequired: vpnEnabled,
      wormholeUrl: _hostWormholeUrlController.text.trim(),
      wormholeToken: _hostWormholeTokenController.text.trim(),
      wormholeSession: _hostCustomSessionController.text.trim(),
      bindHost: _desiredDaemonBindHost(lanEnabled: lanEnabled),
    );
  }

  void _syncActiveSessionWithGroup() {
    final sessions = _visibleSessions;
    if (sessions.isEmpty) {
      if (_sessions.isNotEmpty) {
        if (_activeSessionId == null || !_sessions.contains(_activeSessionId)) {
          _activeSessionId = _sessions.first;
        }
        _terminalManager.activeSessionId = _activeSessionId;
        if (_activeSessionId != null) {
          _terminalFor(_activeSessionId!);
        }
      } else {
        _activeSessionId = null;
        _terminalManager.activeSessionId = null;
      }
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
        debugPrint(
          '[Voyager] iOS device info: name=${iosInfo.name}, modelName=${iosInfo.modelName}, machine=${iosInfo.utsname.machine}',
        );
        // iOS 16+ may return a generic name; keep the name if available.
        final name = _normalizeDeviceName(iosInfo.name);
        if (name.isNotEmpty &&
            name != 'Unknown Device' &&
            name != 'Unknown device') {
          return name;
        }
        final modelName = iosInfo.modelName.trim();
        if (!_isGenericDeviceName(modelName)) {
          return modelName; // e.g., "iPhone 15 Pro"
        }
        final machine = iosInfo.utsname.machine.trim();
        if (!_isGenericDeviceName(machine)) {
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
    } catch (e) {
      debugPrint('Failed to get device name: $e');
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

  bool _isGenericDeviceName(String? name) {
    if (name == null) {
      return true;
    }
    final trimmed = name.trim();
    if (trimmed.isEmpty) {
      return true;
    }
    const genericNames = {
      'iPhone',
      'iPad',
      'iPod touch',
      'Android',
      'Mac',
      'Windows',
      'Linux',
      'Web Browser',
      'Unknown Device',
      'Unknown device',
    };
    if (genericNames.contains(trimmed)) {
      return true;
    }
    final duplicatedIosName = RegExp(
      r'^(iPhone|iPad|iPod touch)\\s*\\(\\1\\)$',
    );
    return duplicatedIosName.hasMatch(trimmed);
  }

  void _safeSetText(TextEditingController controller, String text) {
    if (controller.text == text) {
      return;
    }
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
  }

  Future<void> _saveSettings() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('lanAddress', _urlController.text);
    await prefs.setString('wormholeAddress', _wormholeController.text);
    await prefs.setString('sessionId', _sessionController.text);
    await prefs.setString('token', _tokenController.text);
    await prefs.setBool('useWormhole', _useWormhole);
    await prefs.setBool('autoReconnect', _autoReconnect);
    await prefs.setBool('multiWindow', _multiWindow);
    await prefs.setBool('showKeyboardTools', _showKeyboardTools);
    await prefs.setBool('showHHKB', _showHHKB);
    await prefs.setBool('isHorizonMode', _isHorizonMode);
    if (_deviceKey != null) {
      await prefs.setString('deviceKey', _deviceKey!);
    }
    await prefs.setString('deviceName', _deviceName);
  }

  @override
  void dispose() {
    _connectionManager.disconnect(shouldReconnect: false);
    _settingsChannel.setMethodCallHandler(null);
    _unsubscribeLocalOutput();
    _stopCwdPolling();
    _daemonStatusPoll?.cancel();
    _daemonStatusPoll = null;
    _daemonPairingPoll?.cancel();
    _daemonPairingPoll = null;
    WidgetsBinding.instance.removeObserver(this);
    _hostController.removeListener(_handleHostChange);
    _hostCustomSessionController.removeListener(_syncHostCustomSession);
    _urlController.removeListener(_handleAddressChange);
    _wormholeController.removeListener(_handleAddressChange);
    _sessionController.removeListener(_saveSettings);
    _tokenController.removeListener(_saveSettings);
    _hostWormholeUrlController.dispose();
    _hostWormholeTokenController.dispose();
    _hostCustomSessionController.dispose();
    _urlController.dispose();
    _wormholeController.dispose();
    _sessionController.dispose();
    _tokenController.dispose();
    _metricsDebounce?.cancel();
    _settingsDebounce?.cancel();
    _terminalManager.dispose();
    _hostController.dispose();
    _tabScrollController.dispose();
    _groupScrollController.dispose();
    super.dispose();
  }

  void _startDaemonPairingPolling(Uri wsUri) {
    _daemonPairingPoll?.cancel();
    _daemonPairingPoll = Timer.periodic(const Duration(milliseconds: 700), (
      _,
    ) async {
      if (!mounted) {
        return;
      }
      if (_hostPairingDialogShown) {
        return;
      }
      final deviceName = await _daemonManager.tryGetPendingPairingDeviceName(
        wsUri,
      );
      if (!mounted || deviceName == null) {
        return;
      }
      _hostPairingDialogShown = true;
      _showPairingDialogWith(
        deviceName: deviceName,
        onApprove: (remember) async {
          await _daemonManager.approvePairing(wsUri, remember: remember);
          _sendListSessions();
        },
        onReject: () async {
          await _daemonManager.rejectPairing(wsUri);
        },
      );
    });
  }

  void _startDaemonStatusPolling(Uri wsUri) {
    _daemonStatusPoll?.cancel();
    _daemonStatusPoll = null;
    _daemonStatus = null;

    if (!DaemonManager.isLocalWs(wsUri)) {
      return;
    }

    Future<void> pollOnce() async {
      final status = await _daemonManager.tryGetStatus(wsUri);
      if (!mounted) {
        return;
      }
      if (status == null) {
        if (_daemonStatus != null) {
          setState(() => _daemonStatus = null);
        }
        return;
      }
      final shouldUpdate =
          _daemonStatus?.configId != status.configId ||
          _daemonStatus?.lanBind != status.lanBind ||
          _daemonStatus?.lanPort != status.lanPort ||
          _daemonStatus?.lanClients != status.lanClients ||
          _daemonStatus?.wormholeConnected != status.wormholeConnected ||
          _daemonStatus?.wormholeSessionId != status.wormholeSessionId ||
          _daemonStatus?.wormholeUrl != status.wormholeUrl ||
          _daemonStatus?.vpnRunning != status.vpnRunning ||
          _daemonStatus?.sessionCount != status.sessionCount;
      if (shouldUpdate) {
        setState(() => _daemonStatus = status);
      }
    }

    unawaited(pollOnce());
    _daemonStatusPoll = Timer.periodic(const Duration(seconds: 1), (_) {
      unawaited(pollOnce());
    });
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

  void _handleDisconnected() {
    _groupStore.onDisconnected();

    // If using network backend (daemon / remote host), clear the network-driven UI state.
    if (!_usingDirectLocalPty) {
      _sessions.clear();
      _syncedSessions.clear();
      _activeSessionId = null;
      _terminalManager.activeSessionId = null;
      _terminalManager.clear();
      _stopCwdPolling();
      _sessionCwds.clear();
      if (mounted) {
        setState(() {});
      }
    }
  }

  void _handleSessionList(List<String> sessions) {
    debugPrint(
      '[Mode] Received session list: ${sessions.length} sessions, isHorizonMode=$_isHorizonMode',
    );
    if (_usingDirectLocalPty) {
      debugPrint('[Mode] Ignoring session list (using direct PTY backend)');
      return;
    }

    _sessions
      ..clear()
      ..addAll(sessions);
    if (_sessions.isEmpty) {
      _sendCreateSession();
      return;
    }
    // Request sync for all sessions to get terminal history
    for (final sessionId in sessions) {
      _requestSyncIfNeeded(sessionId);
    }
    // Try to sync with group, but fall back to first session if group not ready
    _syncActiveSessionWithGroup();
    if (_activeSessionId == null && _sessions.isNotEmpty) {
      _activeSessionId = _sessions.first;
    }
    _terminalManager.activeSessionId = _activeSessionId;
    if (_activeSessionId != null) {
      _terminalFor(_activeSessionId!);
    }
    if (mounted) {
      setState(() {});
    }
    _scheduleActiveResize();
    if (_activeSessionId != null) {
      _restoreScrollOffset(_activeSessionId!);
    }
    if (_isHorizonMode) {
      _startCwdPolling();
    }
  }

  // Handler for local session created (Horizon mode direct access)
  void _handleLocalSessionCreated(String sessionId) {
    // Only update UI if in Horizon mode
    if (!_isHorizonMode) {
      return;
    }
    if (!_sessions.contains(sessionId)) {
      _sessions.add(sessionId);
    }
    _activeSessionId = sessionId;
    _terminalManager.activeSessionId = sessionId;
    _terminalFor(sessionId);
    if (mounted) {
      setState(() {
        _createSessionInFlight = false;
        if (_isTransientCreateError(_error)) {
          _error = null;
        }
      });
    }
    _scheduleActiveResize();
    _restoreScrollOffset(sessionId);
    _updateWindowTitle();
  }

  // Handler for remote session created (Voyager mode / network callback)
  void _handleRemoteSessionCreated(String sessionId) {
    if (_usingDirectLocalPty) {
      return;
    }
    if (!_sessions.contains(sessionId)) {
      _sessions.add(sessionId);
    }
    _activeSessionId = sessionId;
    _terminalManager.activeSessionId = sessionId;
    _terminalFor(sessionId);
    _groupStore.requestGroupList();
    if (mounted) {
      setState(() {
        _createSessionInFlight = false;
        if (_isTransientCreateError(_error)) {
          _error = null;
        }
      });
    }
    _scheduleActiveResize();
    _restoreScrollOffset(sessionId);
    _updateWindowTitle();
  }

  // Handler for local session closed (Horizon mode direct access)
  void _handleLocalSessionClosed(String sessionId) {
    // Only update UI if in Horizon mode
    if (!_isHorizonMode) {
      return;
    }
    _sessions.remove(sessionId);
    _terminalManager.removeSession(sessionId);
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

  // Handler for remote session closed (Voyager mode / network callback)
  void _handleRemoteSessionClosed(String sessionId) {
    if (_usingDirectLocalPty) {
      return;
    }
    _sessions.remove(sessionId);
    _terminalManager.removeSession(sessionId);
    _terminalCardKeys.remove(sessionId);
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

  void _handleSessionSync(String sessionId, String content) {
    if (_usingDirectLocalPty || _useLocalOutputMirror) {
      return;
    }
    if (content.isEmpty) {
      return;
    }
    _terminalManager.writeToTerminal(sessionId, content);
    // Note: No setState needed - TerminalView auto-updates via Terminal's notifyListeners
  }

  void _requestSyncIfNeeded(String sessionId) {
    if (_usingDirectLocalPty) {
      return;
    }
    if (_syncedSessions.contains(sessionId)) {
      return;
    }
    _syncedSessions.add(sessionId);
    _connectionManager.sendSyncRequest(sessionId);
  }

  void _handleStdout(String sessionId, String text) {
    if (_usingDirectLocalPty || _useLocalOutputMirror) {
      return;
    }
    _logTerminalOutputBytes(
      sessionId,
      Uint8List.fromList(utf8.encode(text)),
      note: _currentEnterProbeNote(sessionId),
    );
    _terminalManager.writeToTerminal(sessionId, text);
    // Note: No setState needed - TerminalView auto-updates via Terminal's notifyListeners
  }

  void _handleStdoutBytes(String sessionId, Uint8List bytes) {
    if (_usingDirectLocalPty || _useLocalOutputMirror) {
      return;
    }
    _logTerminalOutputBytes(
      sessionId,
      bytes,
      note: _currentEnterProbeNote(sessionId),
    );
    _terminalManager.writeToTerminalBytes(sessionId, bytes);
  }

  Future<void> _connect() async {
    if (mounted) {
      setState(() {
        _error = null;
        _clientPairingPending = false;
      });
    }
    if (_useWormhole) {
      await _ensureDeviceNameReady();
    }
    final uri =
        _useWormhole
            ? _buildWormholeUri()
            : Uri.parse(_urlController.text.trim());
    await _connectionManager.connect(
      uri: uri,
      waitForPairing: _useWormhole,
      autoReconnect: _autoReconnect,
    );
  }

  void _maybeAutoConnectLocal() {
    if (_connected || _useWormhole) {
      return;
    }
    final uri = Uri.tryParse(_urlController.text.trim());
    if (uri == null) {
      return;
    }
    if (_isLocalHost(uri.host)) {
      _connect();
    }
  }

  /// Try connecting as a client to an existing server on [wsUri].
  /// If the connection doesn't establish within a short timeout, assume the
  /// port is held by an orphaned process, kill it, and restart the in-process
  /// host.
  Future<void> _connectOrRecoverPort(Uri wsUri, String hostName) async {
    // First, try connecting as a client to whatever is on that port.
    await _connect();

    // Give the connection a moment to establish.
    await Future.delayed(const Duration(seconds: 2));

    if (_connected) {
      debugPrint('[Horizon] Connected to existing server as client fallback');
      return;
    }

    // Connection failed — the port holder is likely an orphaned process.
    // Try to kill it by finding the PID listening on the port.
    debugPrint('[Horizon] Client fallback failed, attempting port recovery');
    final recovered = await _tryRecoverPort(wsUri.port);
    if (recovered) {
      // Port is free now, restart the in-process host.
      debugPrint('[Horizon] Port recovered, restarting in-process host');
      _hostController.setHostDeviceName(hostName);
      await _hostController.start();
      if (_hostController.running) {
        _subscribeLocalOutput();
        _maybeAutoConnectLocal();
      } else {
        debugPrint(
          '[Horizon] In-process host still failed after port recovery: '
          '${_hostController.error ?? "unknown"}',
        );
      }
    } else {
      debugPrint('[Horizon] Port recovery failed, staying offline');
    }
  }

  /// Attempt to free [port] by killing any orphaned Horizon process holding it.
  /// Returns true if the port was freed.
  Future<bool> _tryRecoverPort(int port) async {
    if (Platform.isWindows) {
      // Port recovery not supported on Windows yet.
      return false;
    }
    try {
      // Use lsof to find the PID holding the port (macOS/Linux)
      final result = await Process.run('lsof', ['-ti', ':$port']);
      if (result.exitCode != 0) {
        return false;
      }
      final pids =
          (result.stdout as String)
              .split('\n')
              .map((s) => int.tryParse(s.trim()))
              .whereType<int>()
              .where((p) => p != _pidSelf)
              .toSet();
      if (pids.isEmpty) {
        return false;
      }
      for (final pid in pids) {
        debugPrint(
          '[Horizon] Killing orphaned process on port $port: PID $pid',
        );
        Process.killPid(pid, ProcessSignal.sigterm);
      }
      // Wait for the port to be freed
      for (var i = 0; i < 10; i++) {
        await Future.delayed(const Duration(milliseconds: 200));
        try {
          final server = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            port,
          );
          await server.close();
          return true;
        } catch (_) {
          // Port still in use, keep waiting
        }
      }
      return false;
    } catch (e) {
      debugPrint('[Horizon] Port recovery error: $e');
      return false;
    }
  }

  int get _pidSelf => pid;

  Future<void> _ensureDeviceNameReady() async {
    if (!_isGenericDeviceName(_deviceName)) {
      return;
    }
    final refreshed = await _getDefaultDeviceName();
    final trimmed = refreshed.trim();
    if (trimmed.isEmpty || trimmed == _deviceName) {
      return;
    }
    if (mounted) {
      setState(() {
        _deviceName = trimmed;
      });
    } else {
      _deviceName = trimmed;
    }
    _hostController.setHostDeviceName(trimmed);
    await _saveSettings();
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
    final uri = base.replace(queryParameters: query);
    debugPrint('[Horizon Voyager] Wormhole URI: $uri');
    debugPrint(
      '[Horizon Voyager] device_name=$deviceName, device_type=${_getDeviceType()}, device_key=$_deviceKey',
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

  String _getDeviceType() {
    if (kIsWeb) {
      return 'web';
    }
    if (Platform.isIOS || Platform.isAndroid) {
      return 'mobile';
    }
    return 'desktop';
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

  bool get _useHardwareKeyboardOnly => false;

  void _setActiveSession(String sessionId, {bool requestKeyboard = false}) {
    if (_activeSessionId == sessionId) {
      if (requestKeyboard && !_multiWindow) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _viewKeyFor(sessionId).currentState?.requestKeyboard();
        });
      }
      return;
    }
    // Request sync for this session if not already synced (Voyager mode only)
    _requestSyncIfNeeded(sessionId);
    setState(() {
      _activeSessionId = sessionId;
      _terminalManager.activeSessionId = sessionId;
      _terminalFor(sessionId);
    });
    _scheduleActiveResize();
    _restoreScrollOffset(sessionId);
    _updateWindowTitle();
    if (requestKeyboard && !_multiWindow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _viewKeyFor(sessionId).currentState?.requestKeyboard();
      });
    }
  }

  void _reorderSessions(int oldIndex, int newIndex) {
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    _groupStore.reorderSession(_groupStore.activeGroupId, oldIndex, newIndex);
  }

  void _updateWindowTitle() {
    // Disabled due to window_manager crash issue.
  }

  // Track last input for debugging
  String _lastInputData = '';
  int _lastInputTimestamp = 0;

  String _normalizeTerminalInput(String data) {
    return data.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
  }

  void _handleTerminalInput(String sessionId, String data) {
    // When HHKB keyboard is shown, TerminalView is read-only
    // and input is handled by the keyboard widget instead
    if (_showHHKB) {
      return;
    }

    try {
      final normalizedData = _normalizeTerminalInput(data);
      _appendTerminalTrace(
        'handleInput:start session=$sessionId raw=${_escapeControlCharacters(data)} normalized=${_escapeControlCharacters(normalizedData)}',
      );
      _logTerminalInputEvent(
        'onInput',
        sessionId,
        normalizedData,
        note: 'raw=${_escapeControlCharacters(data)}',
      );

      // Detect duplicate input within a short time window
      final now = DateTime.now().millisecondsSinceEpoch;
      if (normalizedData == _lastInputData &&
          (now - _lastInputTimestamp) < 20) {
        // Skip duplicate input within 20ms
        debugPrint(
          '[Input] Skipping duplicate: "$normalizedData" within ${now - _lastInputTimestamp}ms',
        );
        return;
      }
      _lastInputData = normalizedData;
      _lastInputTimestamp = now;

      if (_activeSessionId != sessionId) {
        _activeSessionId = sessionId;
        _terminalManager.activeSessionId = sessionId;
        if (mounted) {
          setState(() {});
        }
        _updateWindowTitle();
      }

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
      _appendTerminalTrace(
        'handleInput:beforeSend session=$sessionId output=${_escapeControlCharacters(output)} connected=$_connected direct=$_usingDirectLocalPty',
      );
      _logTerminalInputEvent(
        'prepareSendRaw',
        sessionId,
        output,
        note:
            'connected=$_connected active=${_activeSessionId ?? ""} direct=$_usingDirectLocalPty',
      );
      _sendRawFor(sessionId, output);
      _appendTerminalTrace(
        'handleInput:afterSend session=$sessionId output=${_escapeControlCharacters(output)}',
      );
    } catch (error, stackTrace) {
      final details =
          '$error | ${stackTrace.toString().split('\n').take(3).join(' | ')}';
      _appendTerminalTrace(
        'handleInput:error session=$sessionId details=$details',
      );
      _logTerminalInputEvent(
        'handleInputError',
        sessionId,
        _normalizeTerminalInput(data),
        note: details,
      );
      debugPrint('[Horizon] _handleTerminalInput failed: $error\n$stackTrace');
    }
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
    if (_usingDirectLocalPty) {
      _hostController.resizeLocalSession(sessionId, rows, cols);
    } else {
      _connectionManager.sendResize(sessionId, cols, rows);
    }
  }

  void _sendRaw(String data) {
    final sessionId = _activeSessionId;
    if (sessionId == null) {
      return;
    }
    _sendRawFor(sessionId, data);
  }

  void _sendRawFor(String sessionId, String data) {
    try {
      _appendTerminalTrace(
        'sendRaw:start session=$sessionId data=${_escapeControlCharacters(data)} connected=$_connected direct=$_usingDirectLocalPty',
      );
      final note = _armEnterProbeIfNeeded(sessionId, data);
      _logTerminalInputEvent('sendRaw', sessionId, data, note: note);
      if (_usingDirectLocalPty) {
        final bytes = Uint8List.fromList(utf8.encode(data));
        _hostController.writeLocalStdin(sessionId, bytes);
      } else {
        _connectionManager.sendRaw(sessionId, data);
      }
      _appendTerminalTrace(
        'sendRaw:done session=$sessionId data=${_escapeControlCharacters(data)}',
      );
      _logTerminalInputEvent(
        'sentRaw',
        sessionId,
        data,
        note: 'connected=$_connected direct=$_usingDirectLocalPty',
      );
    } catch (error, stackTrace) {
      final details =
          '$error | ${stackTrace.toString().split('\n').take(3).join(' | ')}';
      _appendTerminalTrace('sendRaw:error session=$sessionId details=$details');
      _logTerminalInputEvent('sendRawError', sessionId, data, note: details);
      debugPrint('[Horizon] _sendRawFor failed: $error\n$stackTrace');
    }
  }

  void _sendCommand(Map<String, dynamic> payload) {
    _connectionManager.sendCommand(payload);
  }

  void _sendGroupCommand(Map<String, dynamic> payload) {
    if (_usingDirectLocalPty) {
      unawaited(_hostController.applyLocalGroupCommand(payload));
      return;
    }
    _connectionManager.sendCommand(payload);
  }

  void _sendListSessions() {
    _sendCommand({'type': 'list'});
    _groupStore.requestGroupList();
  }

  Future<void> _sendCreateSession() async {
    if (_createSessionInFlight) {
      return;
    }
    if (_usingDirectLocalPty) {
      _createSessionInFlight = true;
      await _createLocalSession();
      _createSessionInFlight = false;
      return;
    }
    if (!_connected) {
      if (mounted) {
        setState(() {
          _error = 'Connection is offline. Reconnecting...';
        });
      }
      unawaited(_connect());
      return;
    }
    final beforeCount = _sessions.length;
    _createSessionInFlight = true;
    final requestId = ++_createSessionRequestId;
    final groupId = _groupStore.activeGroupId;
    _sendCommand({
      'type': 'create',
      if (groupId != TerminalGroup.defaultGroupId) 'groupId': groupId,
    });
    Future.delayed(const Duration(milliseconds: 900), () {
      if (!mounted || _usingDirectLocalPty) {
        return;
      }
      if (requestId != _createSessionRequestId) {
        return;
      }
      _createSessionInFlight = false;
      _sendListSessions();
      if (_sessions.length <= beforeCount && mounted) {
        setState(() {
          _error = 'Create session failed. Check daemon shell/path settings.';
        });
      }
    });
  }

  void _sendCreateSessionInGroup(String groupId) {
    _groupStore.setActiveGroup(groupId);
    _sendCreateSession();
  }

  Future<void> _createLocalSession() async {
    final groupId = _groupStore.activeGroupId;
    final sessionId = await _hostController.createLocalSession(
      groupId: groupId != TerminalGroup.defaultGroupId ? groupId : null,
    );
    if (sessionId != null) {
      _handleLocalSessionCreated(sessionId);
      // Refresh group sync
      final syncPayload = _hostController.getLocalGroupSync();
      _groupStore.applySync(syncPayload);
    }
  }

  void _sendCloseSession(String sessionId) {
    if (_usingDirectLocalPty) {
      _closeLocalSession(sessionId);
      return;
    }
    _sendCommand({'type': 'close', 'sessionId': sessionId});
  }

  Future<void> _closeLocalSession(String sessionId) async {
    await _hostController.closeLocalSession(sessionId);
    _handleLocalSessionClosed(sessionId);
    // Refresh group sync
    final syncPayload = _hostController.getLocalGroupSync();
    _groupStore.applySync(syncPayload);
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
    final isInputActive = _isSystemActive;
    final deleteDetection = !kIsWeb && (Platform.isAndroid || Platform.isIOS);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _updateQuickBarHeight();
      }
    });

    return AnimatedBuilder(
      animation: _hostController,
      builder: (context, _) {
        final pending = _hostController.pendingPairing;
        if (pending != null && !_hostPairingDialogShown) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _showPairingDialog(pending);
          });
        }

        const sidebarExpandedWidth = 240.0;
        const sidebarCollapsedWidth = 64.0;
        const sidebarSwitchWidth = 170.0;
        const topBarHeight = 56.0;
        const animDuration = Duration(milliseconds: 220);
        const animCurve = Curves.easeOutCubic;

        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: HorizonColors.background,
          body: Stack(
            children: [
              Positioned.fill(child: _buildBackground()),
              Row(
                children: [
                  AnimatedContainer(
                    duration: animDuration,
                    curve: animCurve,
                    width:
                        _showSidebar
                            ? sidebarExpandedWidth
                            : sidebarCollapsedWidth,
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        if (constraints.maxWidth >= sidebarSwitchWidth) {
                          return _buildSidebarContent(context);
                        }
                        return _buildSidebarRail(context);
                      },
                    ),
                  ),
                  Expanded(
                    child: Column(
                      children: [
                        _buildTopBar(context, topBarHeight),
                        Expanded(
                          child: Stack(
                            children: [
                              Positioned.fill(
                                child: _buildSessionCanvas(
                                  context,
                                  deleteDetection: deleteDetection,
                                ),
                              ),
                              Positioned(
                                left: 0,
                                right: 0,
                                bottom: 0,
                                child: SafeArea(
                                  top: false,
                                  child: _buildBottomBars(isInputActive),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildBackground() {
    return const ColoredBox(color: HorizonColors.surface);
  }

  void _handleTopBarPanStart(DragStartDetails details) {
    if (kIsWeb || !Platform.isMacOS || _topBarInteractivePointers.isNotEmpty) {
      return;
    }
    _systemChannel.invokeMethod('startWindowDrag');
  }

  Widget _markTopBarInteractive({required Widget child}) {
    return Listener(
      behavior: HitTestBehavior.deferToChild,
      onPointerDown: (event) {
        _topBarInteractivePointers.add(event.pointer);
      },
      onPointerUp: (event) {
        _topBarInteractivePointers.remove(event.pointer);
      },
      onPointerCancel: (event) {
        _topBarInteractivePointers.remove(event.pointer);
      },
      child: child,
    );
  }

  Widget _buildTopBar(BuildContext context, double height) {
    final leftPad = _showSidebar ? 0.0 : 32.0;
    final tabs = _visibleSessions;

    return GestureDetector(
      // Keep the immersive titlebar draggable, but never steal drags that
      // started on interactive controls such as tab buttons or window toggles.
      onPanStart: _handleTopBarPanStart,
      behavior: HitTestBehavior.translucent,
      child: Container(
        height: height,
        padding: EdgeInsets.fromLTRB(leftPad, 8, 12, 8),
        decoration: const BoxDecoration(color: HorizonColors.surface),
        child: Row(
          children: [
            Expanded(
              child: _markTopBarInteractive(child: _buildTabStrip(tabs)),
            ),
            const SizedBox(width: 12),
            _markTopBarInteractive(child: _buildViewModeToggleButton()),
          ],
        ),
      ),
    );
  }

  Widget _buildSidebarToggle() {
    return Tooltip(
      message: _showSidebar ? 'Collapse sidebar' : 'Expand sidebar',
      child: InkWell(
        onTap: () => setState(() => _showSidebar = !_showSidebar),
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: HorizonColors.surfaceBright,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: HorizonColors.borderSubtle),
          ),
          child: CustomPaint(
            size: const Size(18, 14),
            painter: _SidebarIconPainter(
              color: HorizonColors.textSecondary,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildGroupBadge(String name) {
    return Container(
      height: 32,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: HorizonColors.surfaceBright,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: HorizonColors.borderSubtle),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.folder_open_rounded,
            size: 16,
            color: HorizonColors.textSecondary,
          ),
          const SizedBox(width: 8),
          Text(
            name,
            style: const TextStyle(
              color: HorizonColors.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTopStatusPill({required bool showLabel}) {
    final bool hasError = _error != null && _error!.isNotEmpty;
    final bool pairing = _clientPairingPending;
    final bool active = _isSystemActive;
    String label;
    Color color;
    if (hasError) {
      label = _error!;
      color = HorizonColors.error;
    } else if (pairing) {
      label = 'Pairing pending';
      color = HorizonColors.statusAmber;
    } else {
      label = active ? 'Connected' : 'Offline';
      color = active ? HorizonColors.success : HorizonColors.textMuted;
    }

    return Container(
      constraints: BoxConstraints(minHeight: 32, maxHeight: 32),
      margin: EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: HorizonColors.surfaceBright,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: HorizonColors.borderSubtle),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: color.withValues(alpha: 0.35),
                  blurRadius: 6,
                  spreadRadius: 0,
                ),
              ],
            ),
          ),
          if (showLabel) const SizedBox(width: 8),
          if (showLabel)
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: HorizonColors.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildViewModeToggleButton() {
    final Widget icon =
        _multiWindow
            ? SvgPicture.asset(
              'assets/icons/square.grid.2x2.svg',
              width: 16,
              height: 16,
              colorFilter: const ColorFilter.mode(
                HorizonColors.textSecondary,
                BlendMode.srcIn,
              ),
            )
            : const Icon(
              Icons.crop_square,
              size: 18,
              color: HorizonColors.textSecondary,
            );
    return Tooltip(
      message: _multiWindow ? 'Multi session' : 'Single session',
      child: InkWell(
        onTap: _toggleMultiWindow,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: HorizonColors.surfaceBright,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: HorizonColors.borderSubtle),
          ),
          child: Center(child: icon),
        ),
      ),
    );
  }

  Widget _buildTabStrip(List<String> sessions) {
    if (sessions.isEmpty) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          onPressed: _sendCreateSession,
          icon: const Icon(Icons.add_rounded, size: 16),
          label: const Text('New session'),
        ),
      );
    }
    _scheduleTabFadeUpdate();

    return Row(
      children: [
        Expanded(
          child: Stack(
            children: [
              SizedBox(
                height: 32,
                child: ReorderableListView.builder(
                  scrollController: _tabScrollController,
                  scrollDirection: Axis.horizontal,
                  buildDefaultDragHandles: false,
                  shrinkWrap: true,
                  padding: EdgeInsets.zero,
                  proxyDecorator: (child, index, animation) {
                    return Material(
                      color: Colors.transparent,
                      elevation: 6,
                      child: child,
                    );
                  },
                  onReorder: _reorderSessions,
                  itemCount: sessions.length,
                  itemBuilder: (context, index) {
                    final sessionId = sessions[index];
                    final label = _getSessionLabel(sessionId, index);
                    final isActive = sessionId == _activeSessionId;
                    return Padding(
                      key: ValueKey('tab-$sessionId'),
                      padding: const EdgeInsets.only(right: 8),
                      child: _buildTabItem(
                        sessionId: sessionId,
                        label: label,
                        isActive: isActive,
                        index: index,
                      ),
                    );
                  },
                ),
              ),
              if (_showTabLeftFade)
                Positioned(
                  left: 0,
                  top: 0,
                  bottom: 0,
                  width: 14,
                  child: _edgeFade(left: true, color: HorizonColors.surface),
                ),
              if (_showTabRightFade)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  width: 14,
                  child: _edgeFade(left: false, color: HorizonColors.surface),
                ),
            ],
          ),
        ),
        const SizedBox(width: 6),
        Tooltip(
          message: 'New tab',
          child: InkWell(
            onTap: _sendCreateSession,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: HorizonColors.surfaceBright,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: HorizonColors.borderSubtle),
              ),
              child: const Icon(
                Icons.add_rounded,
                size: 16,
                color: HorizonColors.textSecondary,
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildTabItem({
    required String sessionId,
    required String label,
    required bool isActive,
    required int index,
  }) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredTabId = sessionId),
      onExit:
          (_) => setState(() {
            if (_hoveredTabId == sessionId) {
              _hoveredTabId = null;
            }
          }),
      child: InkWell(
        onTap: () => _setActiveSession(sessionId, requestKeyboard: true),
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color:
                isActive
                    ? HorizonColors.surfaceBright
                    : HorizonColors.surfaceVariant,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color:
                  isActive
                      ? HorizonColors.accent.withValues(alpha: 0.5)
                      : HorizonColors.borderSubtle,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        isActive
                            ? HorizonColors.textPrimary
                            : HorizonColors.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildTabActions(sessionId, index),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTabActions(String sessionId, int index) {
    final show =
        _hoveredTabId == sessionId ||
        (!kIsWeb && (Platform.isAndroid || Platform.isIOS));
    return _hoverReveal(
      show: show,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          InkWell(
            onTap: () => _sendCloseSession(sessionId),
            borderRadius: BorderRadius.circular(8),
            child: const SizedBox(
              width: 24,
              height: 32,
              child: Center(
                child: Icon(
                  Icons.close_rounded,
                  size: 14,
                  color: HorizonColors.textMuted,
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          ReorderableDragStartListener(
            index: index,
            child: const SizedBox(
              width: 24,
              height: 32,
              child: Center(
                child: Icon(
                  Icons.drag_indicator_rounded,
                  size: 14,
                  color: HorizonColors.textMuted,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _hoverReveal({required bool show, required Widget child}) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 160),
      switchInCurve: Curves.easeOut,
      switchOutCurve: Curves.easeIn,
      transitionBuilder: (child, animation) {
        return FadeTransition(
          opacity: animation,
          child: SizeTransition(
            sizeFactor: animation,
            axis: Axis.horizontal,
            axisAlignment: -1,
            child: child,
          ),
        );
      },
      child:
          show
              ? KeyedSubtree(key: const ValueKey('show'), child: child)
              : const SizedBox.shrink(),
    );
  }

  Widget _edgeFade({required bool left, required Color color}) {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: left ? Alignment.centerLeft : Alignment.centerRight,
            end: left ? Alignment.centerRight : Alignment.centerLeft,
            colors: [color, color.withValues(alpha: 0.0)],
          ),
        ),
      ),
    );
  }

  Widget _edgeFadeVertical({required bool top, required Color color}) {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: top ? Alignment.topCenter : Alignment.bottomCenter,
            end: top ? Alignment.bottomCenter : Alignment.topCenter,
            colors: [color, color.withValues(alpha: 0.0)],
          ),
        ),
      ),
    );
  }

  void _scheduleTabFadeUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateTabFades();
    });
  }

  void _scheduleGroupFadeUpdate() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _updateGroupFades();
    });
  }

  void _updateTabFades() {
    if (!_tabScrollController.hasClients) {
      return;
    }
    final position = _tabScrollController.position;
    final max = position.maxScrollExtent;
    final offset = position.pixels;
    final left = offset > 0.5;
    final right = offset < max - 0.5;
    if (left == _showTabLeftFade && right == _showTabRightFade) {
      return;
    }
    setState(() {
      _showTabLeftFade = left;
      _showTabRightFade = right;
    });
  }

  void _updateGroupFades() {
    if (!_groupScrollController.hasClients) {
      return;
    }
    final position = _groupScrollController.position;
    final max = position.maxScrollExtent;
    final offset = position.pixels;
    final top = offset > 0.5;
    final bottom = offset < max - 0.5;
    if (top == _showGroupTopFade && bottom == _showGroupBottomFade) {
      return;
    }
    setState(() {
      _showGroupTopFade = top;
      _showGroupBottomFade = bottom;
    });
  }

  Widget _buildSidebarRail(BuildContext context) {
    final chromeTopPad = Platform.isMacOS ? 48.0 : 0.0;
    return Container(
      color: HorizonColors.surface,
      child: SafeArea(
        child: Column(
          children: [
            SizedBox(height: chromeTopPad + 8),
            _buildSidebarToggle(),
            const SizedBox(height: 12),
            if (_groupStore.activeGroup != null)
              _buildCollapsedGroupAvatar(_groupStore.activeGroup!.name),
            const Spacer(),
            Tooltip(
              message: 'New group',
              child: InkWell(
                onTap: _promptCreateGroup,
                borderRadius: BorderRadius.circular(12),
                child: Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: HorizonColors.surfaceBright,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: HorizonColors.borderSubtle),
                  ),
                  child: const Icon(
                    Icons.add_rounded,
                    size: 18,
                    color: HorizonColors.textSecondary,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),
            _buildTopStatusPill(showLabel: false),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildCollapsedGroupAvatar(String name) {
    final letter = name.isNotEmpty ? name.characters.first : 'G';
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: HorizonColors.surfaceBright,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: HorizonColors.borderSubtle),
      ),
      child: Center(
        child: Text(
          letter.toUpperCase(),
          style: const TextStyle(
            color: HorizonColors.textSecondary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  Widget _buildSidebarContent(BuildContext context) {
    final groups = _filteredGroups();
    final chromeTopPad = Platform.isMacOS ? 48.0 : 0.0;
    _scheduleGroupFadeUpdate();

    return Container(
      color: HorizonColors.surface,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(16, 6 + chromeTopPad, 16, 8),
              child: Row(
                children: [
                  Expanded(
                    child: SizedBox(
                      height: 32,
                      child: TextField(
                        style: const TextStyle(
                          color: HorizonColors.textPrimary,
                          fontSize: 12,
                          height: 1.0,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Search',
                          prefixIcon: const Icon(
                            Icons.search_rounded,
                            size: 16,
                            color: HorizonColors.textMuted,
                          ),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: 32,
                            minHeight: 32,
                          ),
                        ),
                        onChanged:
                            (value) =>
                                setState(() => _sidebarSearchQuery = value),
                      ),
                    ),
                  ),
                  SizedBox(width: 4),
                  Tooltip(
                    message: 'New group',
                    child: InkWell(
                      onTap: _promptCreateGroup,
                      borderRadius: BorderRadius.circular(10),
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: BoxDecoration(
                          color: HorizonColors.surfaceBright,
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(color: HorizonColors.borderSubtle),
                        ),
                        child: const Icon(
                          Icons.add_rounded,
                          size: 16,
                          color: HorizonColors.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  SizedBox(width: 4),
                  _buildSidebarToggle(),
                ],
              ),
            ),
            Expanded(
              child: Stack(
                children: [
                  ReorderableListView.builder(
                    scrollController: _groupScrollController,
                    padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                    buildDefaultDragHandles: false,
                    onReorder: _reorderGroups,
                    itemCount: groups.length,
                    itemBuilder: (context, index) {
                      final group = groups[index];
                      return Padding(
                        key: ValueKey('group-${group.id}'),
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _buildGroupTile(group, index),
                      );
                    },
                  ),
                  if (_showGroupTopFade)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      height: 16,
                      child: _edgeFadeVertical(
                        top: true,
                        color: HorizonColors.surface,
                      ),
                    ),
                  if (_showGroupBottomFade)
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      height: 16,
                      child: _edgeFadeVertical(
                        top: false,
                        color: HorizonColors.surface,
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _buildTopStatusPill(showLabel: true),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }

  List<TerminalGroup> _filteredGroups() {
    if (_sidebarSearchQuery.trim().isEmpty) {
      return _groupStore.groups;
    }
    final query = _sidebarSearchQuery.trim().toLowerCase();
    final matches = <TerminalGroup>[];
    for (final group in _groupStore.groups) {
      if (group.name.toLowerCase().contains(query)) {
        matches.add(group);
        continue;
      }
      final hasSession = group.sessionIds.asMap().entries.any((entry) {
        final label = _getSessionLabel(entry.value, entry.key);
        return label.toLowerCase().contains(query);
      });
      if (hasSession) {
        matches.add(group);
      }
    }
    return matches;
  }

  Widget _buildGroupTile(TerminalGroup group, int index) {
    final isActive = group.id == _groupStore.activeGroupId;
    final isCollapsed = _collapsedGroupIds.contains(group.id);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 160),
      decoration: BoxDecoration(
        color:
            isActive
                ? HorizonColors.surfaceBright
                : HorizonColors.surfaceVariant,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color:
              isActive
                  ? HorizonColors.accent.withValues(alpha: 0.45)
                  : HorizonColors.borderSubtle,
        ),
      ),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hoveredGroupId = group.id),
        onExit:
            (_) => setState(() {
              if (_hoveredGroupId == group.id) {
                _hoveredGroupId = null;
              }
            }),
        child: Column(
          children: [
            InkWell(
              onTap: () => _groupStore.setActiveGroup(group.id),
              borderRadius: BorderRadius.circular(14),
              child: SizedBox(
                height: 32,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      GestureDetector(
                        onTap: () => _toggleGroupCollapse(group.id),
                        child: Icon(
                          isCollapsed
                              ? Icons.chevron_right_rounded
                              : Icons.expand_more_rounded,
                          color: HorizonColors.textMuted,
                          size: 16,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          group.name,
                          style: const TextStyle(
                            color: HorizonColors.textPrimary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      _buildGroupActions(group, index),
                    ],
                  ),
                ),
              ),
            ),
            if (!isCollapsed) _buildSessionList(group, isActive),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupActions(TerminalGroup group, int index) {
    final show =
        _hoveredGroupId == group.id ||
        (!kIsWeb && (Platform.isAndroid || Platform.isIOS));
    return _hoverReveal(
      show: show,
      child: SizedBox(
        height: 32,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Tooltip(
              message: 'New session',
              child: InkWell(
                onTap: () => _sendCreateSessionInGroup(group.id),
                borderRadius: BorderRadius.circular(8),
                child: const SizedBox(
                  width: 32,
                  height: 32,
                  child: Center(
                    child: Icon(
                      Icons.add_rounded,
                      size: 16,
                      color: HorizonColors.textMuted,
                    ),
                  ),
                ),
              ),
            ),
            _buildGroupMenu(group),
            if (_sidebarSearchQuery.trim().isEmpty)
              ReorderableDragStartListener(
                index: index,
                child: const SizedBox(
                  width: 24,
                  height: 32,
                  child: Center(
                    child: Icon(
                      Icons.drag_indicator_rounded,
                      size: 16,
                      color: HorizonColors.textMuted,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupMenu(TerminalGroup group) {
    return PopupMenuButton<String>(
      tooltip: 'Group actions',
      color: HorizonColors.surfaceBright,
      onSelected: (value) {
        switch (value) {
          case 'rename':
            _promptRenameGroup(group);
            break;
          case 'delete':
            _confirmDeleteGroup(group, deleteSessions: false);
            break;
          case 'delete_all':
            _confirmDeleteGroup(group, deleteSessions: true);
            break;
        }
      },
      itemBuilder:
          (context) => [
            const PopupMenuItem(value: 'rename', child: Text('Rename group')),
            const PopupMenuItem(value: 'delete', child: Text('Delete group')),
            const PopupMenuItem(
              value: 'delete_all',
              child: Text('Delete group + sessions'),
            ),
          ],
      child: Container(
        width: 32,
        height: 32,
        alignment: Alignment.center,
        child: const Icon(
          Icons.more_vert_rounded,
          size: 16,
          color: HorizonColors.textMuted,
        ),
      ),
    );
  }

  Widget _buildSessionList(TerminalGroup group, bool isActiveGroup) {
    if (group.sessionIds.isEmpty) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(
            'No sessions yet',
            style: TextStyle(
              color: HorizonColors.textMuted.withValues(alpha: 0.8),
              fontSize: 11,
            ),
          ),
        ),
      );
    }

    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 10),
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: group.sessionIds.length,
      itemBuilder: (context, index) {
        final sessionId = group.sessionIds[index];
        final label = _getSessionLabel(sessionId, index);
        final isActive = sessionId == _activeSessionId && isActiveGroup;
        return _buildSessionRow(
          groupId: group.id,
          sessionId: sessionId,
          label: label,
          isActive: isActive,
        );
      },
    );
  }

  Widget _buildSessionRow({
    required String groupId,
    required String sessionId,
    required String label,
    required bool isActive,
  }) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hoveredSessionRowId = sessionId),
      onExit:
          (_) => setState(() {
            if (_hoveredSessionRowId == sessionId) {
              _hoveredSessionRowId = null;
            }
          }),
      child: InkWell(
        onTap: () {
          _groupStore.setActiveGroup(groupId);
          _setActiveSession(sessionId, requestKeyboard: true);
        },
        borderRadius: BorderRadius.circular(10),
        child: Container(
          margin: const EdgeInsets.symmetric(vertical: 4),
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          decoration: BoxDecoration(
            color: isActive ? HorizonColors.surface : Colors.transparent,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color:
                  isActive
                      ? HorizonColors.accent.withValues(alpha: 0.45)
                      : Colors.transparent,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color:
                        isActive
                            ? HorizonColors.textPrimary
                            : HorizonColors.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              _buildSessionRowClose(sessionId),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildSessionRowClose(String sessionId) {
    final show =
        _hoveredSessionRowId == sessionId ||
        (!kIsWeb && (Platform.isAndroid || Platform.isIOS));
    return _hoverReveal(
      show: show,
      child: InkWell(
        onTap: () => _sendCloseSession(sessionId),
        borderRadius: BorderRadius.circular(8),
        child: const SizedBox(
          width: 24,
          height: 32,
          child: Center(
            child: Icon(
              Icons.close_rounded,
              size: 14,
              color: HorizonColors.textMuted,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSessionCanvas(
    BuildContext context, {
    required bool deleteDetection,
  }) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 12, 12),
      child: SizedBox.expand(
        child: Container(
          color: HorizonColors.surface,
          child: SizedBox.expand(
            child: Container(
              decoration: BoxDecoration(
                color: HorizonColors.background,
                borderRadius: BorderRadius.circular(16),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
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
                          ? _buildMultiSessionGrid(deleteDetection)
                          : _buildSingleSessionView(deleteDetection),
                      if (_dragging)
                        Positioned.fill(
                          child: Container(
                            color: HorizonColors.accent.withValues(alpha: 0.12),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildMultiSessionGrid(bool deleteDetection) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        var columns = 1;
        if (width >= 2400) {
          columns = 4;
        } else if (width >= 1800) {
          columns = 3;
        } else if (width >= 1200) {
          columns = 2;
        }
        final sessions =
            _visibleSessions.isNotEmpty
                ? _visibleSessions
                : (_activeSessionId != null ? [_activeSessionId!] : <String>[]);
        final displaySessions = sessions.isEmpty ? <String>[] : sessions;
        final aspectRatio = columns == 1 ? 1.35 : (columns == 2 ? 1.45 : 1.55);
        final padding = EdgeInsets.fromLTRB(18, 16, 18, _bottomBarHeight + 20);

        if (displaySessions.isEmpty) {
          return _buildEmptySessionState(padding);
        }

        return GridView.builder(
          padding: padding,
          physics: const BouncingScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 14,
            mainAxisSpacing: 14,
            childAspectRatio: aspectRatio,
          ),
          itemCount: displaySessions.length + 1,
          itemBuilder: (context, index) {
            if (index == displaySessions.length) {
              return _buildAddSessionCard();
            }
            final sessionId = displaySessions[index];
            final label = _getSessionLabel(sessionId, index);
            return HorizonSessionCard(
              key: _terminalCardKeyFor(sessionId),
              sessionId: sessionId,
              terminal: _terminalFor(sessionId),
              controller: _controllerFor(sessionId),
              scrollController: _scrollControllerFor(sessionId),
              viewKey: _viewKeyFor(sessionId),
              label: label,
              isActive: sessionId == _activeSessionId,
              showHHKB: _showHHKB,
              deleteDetection: deleteDetection,
              hardwareKeyboardOnly: _useHardwareKeyboardOnly,
              isDragTarget: _dragging && _dragTargetSessionId == sessionId,
              terminalStyle: buildTerminalStyle(fontSize: 8),
              onTap: () => _setActiveSession(sessionId, requestKeyboard: false),
              onClose: () => _sendCloseSession(sessionId),
            );
          },
        );
      },
    );
  }

  Widget _buildSingleSessionView(bool deleteDetection) {
    final terminal = _activeTerminal ?? _idleTerminal;
    final controller = _activeController ?? _idleController;
    final scrollController = _activeScrollController ?? _idleScrollController;
    final padding = EdgeInsets.fromLTRB(12, 10, 12, _bottomBarHeight + 12);

    if (_activeSessionId == null) {
      return _buildEmptySessionState(padding);
    }

    return Padding(
      padding: padding,
      child: TerminalView(
        terminal,
        key: _activeViewKey ?? _idleTerminalViewKey,
        controller: controller,
        scrollController: scrollController,
        theme: HorizonTerminalTheme.light,
        autoResize: false,
        autofocus: true,
        deleteDetection: deleteDetection,
        hardwareKeyboardOnly: _useHardwareKeyboardOnly,
        readOnly: _showHHKB,
        keyboardType: _showHHKB ? TextInputType.none : TextInputType.text,
        backgroundOpacity: 1.0,
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
        textStyle: buildTerminalStyle(fontSize: 9),
      ),
    );
  }

  Widget _buildEmptySessionState(EdgeInsets padding) {
    return Padding(
      padding: padding,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.terminal_rounded,
              size: 32,
              color: HorizonColors.textMuted,
            ),
            const SizedBox(height: 12),
            const Text(
              'No sessions yet',
              style: TextStyle(
                color: HorizonColors.textSecondary,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Create a new session to begin.',
              style: TextStyle(color: HorizonColors.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            ElevatedButton.icon(
              onPressed: _sendCreateSession,
              icon: const Icon(Icons.add_rounded, size: 16),
              label: const Text('New session'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAddSessionCard() {
    return InkWell(
      onTap: _sendCreateSession,
      borderRadius: BorderRadius.circular(10),
      child: Container(
        decoration: BoxDecoration(
          color: HorizonColors.surfaceVariant,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: HorizonColors.borderSubtle, width: 1),
        ),
        child: const Center(
          child: Icon(
            Icons.add_rounded,
            size: 30,
            color: HorizonColors.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildBottomBars(bool isInputActive) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        KeyedSubtree(
          key: _quickBarKey,
          child:
              _showKeyboardTools
                  ? QuickActionsBar(
                    connected: isInputActive,
                    ctrl: _ctrl,
                    alt: _alt,
                    meta: _meta,
                    onToggleCtrl: () => setState(() => _ctrl = !_ctrl),
                    onToggleAlt: () => setState(() => _alt = !_alt),
                    onToggleMeta: () => setState(() => _meta = !_meta),
                    onKey: _sendKey,
                    onPaste: _pasteClipboard,
                    onCopy: _copySelection,
                    onSend: _sendRaw,
                    onScrollToBottom: _scrollToBottom,
                  )
                  : const SizedBox.shrink(),
        ),
        if (_showHHKB)
          HHKBKeyboard(
            connected: isInputActive,
            fn: _hhkbFn,
            ctrl: _ctrl,
            alt: _alt,
            onScrollToBottom: _scrollToBottom,
            onKey: (key, {bool isSpecial = false}) {
              if (_ctrl && !isSpecial) {
                _sendCtrl(key);
              } else if (_alt && !isSpecial) {
                _sendRaw('$key');
              } else {
                _sendRaw(key);
              }
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
    );
  }

  String _getSessionLabel(String sessionId, int index) {
    if (_groupStore.hasCustomSessionName(sessionId)) {
      return _groupStore.getSessionName(sessionId, index);
    }
    final xtermTitle = _terminalManager.getTitle(sessionId);
    if (xtermTitle != null && xtermTitle.isNotEmpty) {
      return xtermTitle;
    }
    if (_isHorizonMode) {
      final cwdName = _getCwdDisplayName(sessionId);
      if (cwdName != null && cwdName.isNotEmpty) {
        return cwdName;
      }
    }
    return _groupStore.getSessionName(sessionId, index);
  }

  void _toggleGroupCollapse(String groupId) {
    setState(() {
      if (_collapsedGroupIds.contains(groupId)) {
        _collapsedGroupIds.remove(groupId);
      } else {
        _collapsedGroupIds.add(groupId);
      }
    });
  }

  void _reorderGroups(int oldIndex, int newIndex) {
    if (_sidebarSearchQuery.trim().isNotEmpty) {
      return;
    }
    if (newIndex > oldIndex) {
      newIndex -= 1;
    }
    final groups = _groupStore.groups;
    if (oldIndex < 0 || oldIndex >= groups.length) {
      return;
    }
    final groupId = groups[oldIndex].id;
    _groupStore.reorderGroup(groupId, newIndex);
  }

  void _promptCreateGroup() {
    final controller = TextEditingController();
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Create group'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Group name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                final name = controller.text.trim();
                if (name.isEmpty) {
                  _groupStore.createGroup();
                } else {
                  _groupStore.createGroup(name: name);
                }
                Navigator.of(context).pop();
              },
              child: const Text('Create'),
            ),
          ],
        );
      },
    ).whenComplete(controller.dispose);
  }

  void _promptRenameGroup(TerminalGroup group) {
    final controller = TextEditingController(text: group.name);
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Rename group'),
          content: TextField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(hintText: 'Group name'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                _groupStore.renameGroup(group.id, controller.text);
                Navigator.of(context).pop();
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    ).whenComplete(controller.dispose);
  }

  void _confirmDeleteGroup(
    TerminalGroup group, {
    required bool deleteSessions,
  }) {
    showDialog<void>(
      context: context,
      builder: (context) {
        return AlertDialog(
          title: const Text('Delete group?'),
          content: Text(
            deleteSessions
                ? 'This will delete the group and all its sessions.'
                : 'This will remove the group but keep its sessions.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                if (deleteSessions) {
                  _groupStore.deleteGroupWithSessions(group.id);
                } else {
                  _groupStore.deleteGroup(group.id);
                }
                Navigator.of(context).pop();
              },
              child: const Text('Delete'),
            ),
          ],
        );
      },
    );
  }

  bool _isLocalHost(String host) {
    final normalized = host.trim().toLowerCase();
    if (normalized.isEmpty) {
      return false;
    }
    if (normalized == 'localhost' ||
        normalized == '127.0.0.1' ||
        normalized == '::1') {
      return true;
    }
    return _hostController.addresses.contains(host);
  }
}

/// Sidebar toggle icon based on SF Symbols sidebar.left design.
class _SidebarIconPainter extends CustomPainter {
  _SidebarIconPainter({required this.color});

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    // Original viewBox: 0 0 23.3887 17.9785
    final sx = size.width / 23.3887;
    final sy = size.height / 17.9785;
    canvas.scale(sx, sy);

    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    // Outer rounded rect (border)
    final outer = Path()
      ..moveTo(4.12109, 17.9785)
      ..lineTo(19.1504, 17.9785)
      ..cubicTo(21.6113, 17.9785, 23.0273, 16.4941, 23.0273, 13.8574)
      ..lineTo(23.0273, 4.13086)
      ..cubicTo(23.0273, 1.49414, 21.6113, 0, 19.1504, 0)
      ..lineTo(4.12109, 0)
      ..cubicTo(1.49414, 0, 0, 1.49414, 0, 4.13086)
      ..lineTo(0, 13.8574)
      ..cubicTo(0, 16.4941, 1.49414, 17.9785, 4.12109, 17.9785)
      ..close();
    // Inner cutout
    final inner = Path()
      ..moveTo(4.13086, 16.4062)
      ..cubicTo(2.50977, 16.4062, 1.57227, 15.4785, 1.57227, 13.8574)
      ..lineTo(1.57227, 4.13086)
      ..cubicTo(1.57227, 2.50977, 2.50977, 1.57227, 4.13086, 1.57227)
      ..lineTo(18.8965, 1.57227)
      ..cubicTo(20.5176, 1.57227, 21.4551, 2.50977, 21.4551, 4.13086)
      ..lineTo(21.4551, 13.8574)
      ..cubicTo(21.4551, 15.4785, 20.5176, 16.4062, 18.8965, 16.4062)
      ..close();
    final border = Path.combine(PathOperation.difference, outer, inner);
    canvas.drawPath(border, paint);

    // Vertical divider
    canvas.drawRect(
      const Rect.fromLTWH(7.44141, 1.28906, 1.53320, 15.42974),
      paint,
    );

    // Three horizontal lines (left sidebar content)
    const lineRects = [
      Rect.fromLTWH(2.91992, 4.11133, 3.20313, 1.09375), // top
      Rect.fromLTWH(2.91992, 6.64062, 3.20313, 1.09375), // middle
      Rect.fromLTWH(2.91992, 9.16992, 3.20313, 1.09375), // bottom
    ];
    final linePaint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    for (final r in lineRects) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(0.55)),
        linePaint,
      );
    }
  }

  @override
  bool shouldRepaint(_SidebarIconPainter oldDelegate) =>
      color != oldDelegate.color;
}
