import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:voyager_share/voyager_share.dart' show buildTerminalStyle;
import 'package:xterm/xterm.dart';

import '../controllers/horizon_controller.dart';
import '../models/dev_mode_config.dart';
import '../models/terminal_group.dart';
import '../services/connection_manager.dart';
import '../services/group_store.dart';
import '../services/terminal_manager.dart';
import '../services/terminal_service.dart';
import '../widgets/add_terminal_card.dart';
import '../widgets/chrome/header_chrome.dart';
import '../widgets/common/status_dot.dart';
import '../widgets/group_drawer.dart';
import '../widgets/keyboard/hhkb_keyboard.dart';
import '../widgets/quick_actions_bar.dart';
import '../widgets/settings_drawer.dart';
import '../widgets/terminal_window_card.dart';
import '../widgets/dialogs/pairing_dialog.dart';

class HorizonHome extends StatefulWidget {
  const HorizonHome({super.key, required this.devModeConfig});

  final DevModeConfig devModeConfig;

  @override
  State<HorizonHome> createState() => _HorizonHomeState();
}

class _HorizonHomeState extends State<HorizonHome> with WidgetsBindingObserver {
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

  late final HorizonController _hostController;
  late final TextEditingController _hostWormholeUrlController;
  late final TextEditingController _hostWormholeTokenController;
  late final TextEditingController _hostCustomSessionController;
  bool _hostPairingDialogShown = false;
  String? _remoteDeviceName;

  late final ConnectionManager _connectionManager;
  late final TerminalManager _terminalManager;

  bool _connected = false;
  bool _autoReconnect = true;
  bool _chromeHidden = false;
  bool _useWormhole = false;
  bool _isHorizonMode = true; // true = Horizon (host), false = Voyager (client)
  bool _showKeyboardTools = true;
  bool _showHHKB = false;
  bool _hhkbFn = false;
  bool _hhkbShift = false;
  bool _multiWindow = false;
  double _quickBarHeight = 0;
  static const double _hhkbKeyboardHeight = 242; // 5*42 + 4*4 + 16 padding

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

  // GlobalKeys for terminal cards in multi-window mode (for hit testing)
  final Map<String, GlobalKey> _terminalCardKeys = {};

  String? _error;

  // Device pairing related state
  String? _deviceKey;
  String _deviceName = '';
  bool _clientPairingPending = false;
  bool _hostConfigSynced = false;

  // Local mode (Horizon) output subscription
  StreamSubscription<TerminalOutput>? _localOutputSub;
  static const bool _logTerminalOutput =
      bool.fromEnvironment('BH_LOG_TERMINAL_OUTPUT');
  IOSink? _terminalOutputSink;
  String? _terminalOutputLogPath;

  // CWD polling for local sessions (Horizon mode)
  Timer? _cwdPollTimer;
  final Map<String, String> _sessionCwds = {};
  static const Duration _cwdPollInterval = Duration(seconds: 2);

  List<String> get _visibleSessions => _groupStore.activeGroupSessionIds;

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
        if (!mounted) {
          return;
        }
        setState(() {
          _remoteDeviceName = hostName;
        });
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
    if (!_hostController.requiresDevModeConfirmation) {
      _hostController.start();
    }
    _urlController.addListener(_handleAddressChange);
    _wormholeController.addListener(_handleAddressChange);
    _sessionController.addListener(_saveSettings);
    _tokenController.addListener(_saveSettings);
    _loadSettings();
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
    setState(() {
      _urlController.text =
          prefs.getString('lanAddress') ?? 'ws://127.0.0.1:9527';
      _wormholeController.text =
          prefs.getString('wormholeAddress') ?? 'ws://127.0.0.1:8080/ws';
      _sessionController.text = prefs.getString('sessionId') ?? '';
      _tokenController.text = prefs.getString('token') ?? '';
      _useWormhole = prefs.getBool('useWormhole') ?? false;
      _autoReconnect = prefs.getBool('autoReconnect') ?? true;
      _multiWindow = prefs.getBool('multiWindow') ?? false;
      _showKeyboardTools = prefs.getBool('showKeyboardTools') ?? true;
      _showHHKB = prefs.getBool('showHHKB') ?? false;
      _isHorizonMode = prefs.getBool('isHorizonMode') ?? true;
      _deviceKey = prefs.getString('deviceKey');
      _deviceName = deviceName;
    });
    _hostController.setHostDeviceName(deviceName);
    _connectionManager.updateAutoReconnect(_autoReconnect);

    // Always subscribe to local output (for Horizon mode)
    if (_hostController.running) {
      _subscribeLocalOutput();
      if (_isHorizonMode) {
        _loadLocalSessions();
      }
    }
    // Always try to connect Voyager client (for Voyager mode)
    _maybeAutoConnectLocal();
  }

  void _handleGroupChange() {
    if (!mounted) {
      return;
    }
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
        _safeSetText(_hostWormholeUrlController, _hostController.wormholeBaseUrl);
        _safeSetText(_hostWormholeTokenController, _hostController.wormholeToken);
        _safeSetText(_hostCustomSessionController, _hostController.customSessionId);
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
      // Always try to auto-connect Voyager client (for Voyager mode data)
      _maybeAutoConnectLocal();
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

  void _handleModeSwitch(bool isHorizon) {
    debugPrint(
      '[Mode] Switching to ${isHorizon ? "Horizon" : "Voyager"} mode, connected=$_connected',
    );
    if (isHorizon) {
      if (_hostController.running) {
        _subscribeLocalOutput();
        _loadLocalSessions();
        // _startCwdPolling() is called inside _loadLocalSessions
      } else {
        _sessions.clear();
        _activeSessionId = null;
        _terminalManager.activeSessionId = null;
        _terminalManager.clear();
        _stopCwdPolling();
      }
      if (mounted) {
        setState(() {});
      }
      return;
    }

    // Switching to Voyager mode - stop cwd polling
    _stopCwdPolling();
    _sessionCwds.clear();

    final keepSessions = _isLocalVoyagerTarget();
    if (!keepSessions) {
      _sessions.clear();
      _activeSessionId = null;
      _terminalManager.activeSessionId = null;
      _terminalManager.clear();
    }
    if (_connected) {
      _sendListSessions();
      _syncActiveTerminalView();
    } else {
      _maybeAutoConnectLocal();
    }
    if (mounted) {
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
    _logTerminalOutputBytes(output.sessionId, output.data);
    _terminalManager.writeToTerminalBytes(output.sessionId, output.data);
    // Note: No setState needed - TerminalView auto-updates via Terminal's notifyListeners
  }

  void _logTerminalOutputBytes(String sessionId, Uint8List data) {
    if (!_logTerminalOutput || data.isEmpty) {
      return;
    }
    _terminalOutputSink ??= _openTerminalOutputLog();
    final sink = _terminalOutputSink;
    if (sink == null) {
      return;
    }
    final timestamp = DateTime.now().toIso8601String();
    sink.writeln('[$timestamp] session=$sessionId bytes=${data.length}');
    _writeHexLines(sink, data);
    final decoded = utf8.decode(data, allowMalformed: true);
    sink.writeln('text: ${_escapeControlCharacters(decoded)}');
    sink.writeln('---');
  }

  IOSink? _openTerminalOutputLog() {
    final path =
        Directory.systemTemp.uri
            .resolve('blackhole_terminal_output.log')
            .toFilePath();
    _terminalOutputLogPath ??= path;
    debugPrint('[Horizon] Logging terminal output to $path');
    try {
      return File(path).openWrite(mode: FileMode.writeOnlyAppend);
    } catch (error) {
      debugPrint('[Horizon] Failed to open terminal log: $error');
      return null;
    }
  }

  void _writeHexLines(IOSink sink, Uint8List data) {
    const bytesPerLine = 32;
    for (int i = 0; i < data.length; i += bytesPerLine) {
      final end = (i + bytesPerLine).clamp(0, data.length);
      final buffer = StringBuffer();
      for (int j = i; j < end; j++) {
        buffer.write(data[j].toRadixString(16).padLeft(2, '0'));
        if (j + 1 < end) {
          buffer.write(' ');
        }
      }
      sink.writeln(buffer.toString());
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
    if (!_isHorizonMode || !_hostController.running) {
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
    if (!_isHorizonMode || !_hostController.running) {
      return;
    }
    var changed = false;
    for (final sessionId in _sessions) {
      final cwd = await _hostController.getLocalCwd(sessionId);
      if (cwd != null && cwd.isNotEmpty) {
        final oldCwd = _sessionCwds[sessionId];
        if (oldCwd != cwd) {
          _sessionCwds[sessionId] = cwd;
          changed = true;
        }
      }
    }
    if (changed && mounted) {
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

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder:
          (context) => PairingDialog(
            pending: pending,
            onApprove: (remember) {
              Navigator.of(context).pop();
              _hostPairingDialogShown = false;
              _hostController.approvePairing(remember: remember);
            },
            onReject: () {
              Navigator.of(context).pop();
              _hostPairingDialogShown = false;
              _hostController.rejectPairing();
            },
          ),
    );
  }

  void _syncHostWormholeConfig() {
    _hostController.updateWormholeConfig(
      baseUrl: _hostWormholeUrlController.text,
      token: _hostWormholeTokenController.text,
    );
  }

  void _syncHostCustomSession() {
    _hostController.setCustomSessionId(_hostCustomSessionController.text);
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
    _unsubscribeLocalOutput();
    _stopCwdPolling();
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
    _terminalManager.dispose();
    _hostController.dispose();
    _terminalOutputSink?.close();
    _terminalOutputSink = null;
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
    _remoteDeviceName = null;

    // Only update UI if in Voyager mode
    if (!_isHorizonMode) {
      _sessions.clear();
      _syncedSessions.clear();
      _activeSessionId = null;
      _terminalManager.activeSessionId = null;
      _terminalManager.clear();
      if (mounted) {
        setState(() {});
      }
    }
  }

  void _handleSessionList(List<String> sessions) {
    debugPrint(
      '[Mode] Received session list: ${sessions.length} sessions, isHorizonMode=$_isHorizonMode',
    );
    // Only update UI if in Voyager mode
    if (_isHorizonMode) {
      debugPrint('[Mode] Ignoring session list (in Horizon mode)');
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
      setState(() {});
    }
    _scheduleActiveResize();
    _restoreScrollOffset(sessionId);
  }

  // Handler for remote session created (Voyager mode / network callback)
  void _handleRemoteSessionCreated(String sessionId) {
    // Only update UI if in Voyager mode
    if (_isHorizonMode) {
      return;
    }
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
  }

  // Handler for remote session closed (Voyager mode / network callback)
  void _handleRemoteSessionClosed(String sessionId) {
    // Only update UI if in Voyager mode
    if (_isHorizonMode) {
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
  }

  void _handleSessionSync(String sessionId, String content) {
    // Only update terminal if in Voyager mode
    if (_isHorizonMode) {
      return;
    }
    if (content.isEmpty) {
      return;
    }
    _terminalManager.writeToTerminal(sessionId, content);
    // Note: No setState needed - TerminalView auto-updates via Terminal's notifyListeners
  }

  void _requestSyncIfNeeded(String sessionId) {
    if (_isHorizonMode) {
      return;
    }
    if (_syncedSessions.contains(sessionId)) {
      return;
    }
    _syncedSessions.add(sessionId);
    _connectionManager.sendSyncRequest(sessionId);
  }

  void _handleStdout(String sessionId, String text) {
    // Only update terminal if in Voyager mode
    if (_isHorizonMode) {
      return;
    }
    _terminalManager.writeToTerminal(sessionId, text);
    // Note: No setState needed - TerminalView auto-updates via Terminal's notifyListeners
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

  void _syncActiveTerminalView() {
    final sessionId = _activeSessionId;
    if (sessionId == null) {
      return;
    }
    _terminalManager.activeSessionId = sessionId;
    _terminalFor(sessionId);
    _scheduleActiveResize();
    _restoreScrollOffset(sessionId);
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
    if (requestKeyboard && !_multiWindow) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _viewKeyFor(sessionId).currentState?.requestKeyboard();
      });
    }
  }

  void _reorderSessions(int oldIndex, int newIndex) {
    _groupStore.reorderSession(_groupStore.activeGroupId, oldIndex, newIndex);
  }

  void _handleTerminalInput(String sessionId, String data) {
    if (_activeSessionId != sessionId) {
      _activeSessionId = sessionId;
      _terminalManager.activeSessionId = sessionId;
      if (mounted) {
        setState(() {});
      }
    }
    var output = data.replaceAll('\n', '\r');
    if (_ctrl) {
      output = _applyCtrl(output);
      _ctrl = false;
    }
    if (_alt || _meta) {
      output = _applyAlt(output);
      _alt = false;
      _meta = false;
    }
    _sendRawFor(sessionId, output);
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
    if (_isHorizonMode) {
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
    if (_isHorizonMode) {
      final bytes = Uint8List.fromList(utf8.encode(data));
      _hostController.writeLocalStdin(sessionId, bytes);
    } else {
      _connectionManager.sendRaw(sessionId, data);
    }
  }

  void _sendCommand(Map<String, dynamic> payload) {
    _connectionManager.sendCommand(payload);
  }

  void _sendGroupCommand(Map<String, dynamic> payload) {
    if (_isHorizonMode) {
      unawaited(_hostController.applyLocalGroupCommand(payload));
      return;
    }
    _connectionManager.sendCommand(payload);
  }

  void _sendListSessions() {
    _sendCommand({'type': 'list'});
    _groupStore.requestGroupList();
  }

  void _sendCreateSession() {
    if (_isHorizonMode) {
      _createLocalSession();
      return;
    }
    final groupId = _groupStore.activeGroupId;
    _sendCommand({
      'type': 'create',
      if (groupId != TerminalGroup.defaultGroupId) 'groupId': groupId,
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
    if (_isHorizonMode) {
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
    _activeTerminal?.keyInput(key);
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
    const barColor = Color(0xFF111620);
    const activeColor = Color(0xFF1E2D3D); // Slightly lighter for contrast
    const overlayColor =
        Colors.transparent; // No longer need overlay with solid background
    final isInputActive = _isHorizonMode ? _hostController.running : _connected;
    final terminal = _activeTerminal ?? _idleTerminal;
    final controller = _activeController ?? _idleController;
    final scrollController = _activeScrollController ?? _idleScrollController;
    final deleteDetection =
        !kIsWeb && (Platform.isAndroid || Platform.isIOS);
    // connectionContent: 32 + 16(padding) = 48, tab栏: 36 + 2(padding) = 38
    final terminalTopInset =
        _chromeHidden ? (_visibleSessions.length <= 1 ? 0 : 38) : 48 + 38;

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

        return Scaffold(
          key: _scaffoldKey,
          backgroundColor: Colors.black,
          drawer: _buildGroupDrawer(context),
          endDrawer: _buildSettingsDrawer(context),
          onDrawerChanged: (isOpened) {
            _groupStore.setDeferredSync(isOpened && !_isHorizonMode);
          },
          body: Stack(
            children: [
              Positioned.fill(child: Container(color: Colors.black)),
              Positioned.fill(
                top: terminalTopInset.toDouble(),
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
                              var columns = 1;
                              if (width >= 2500) {
                                columns = 5;
                              } else if (width >= 2000) {
                                columns = 4;
                              } else if (width >= 1500) {
                                columns = 3;
                              } else if (width >= 1000) {
                                columns = 2;
                              }
                              final sessions =
                                  _visibleSessions.isNotEmpty
                                      ? _visibleSessions
                                      : (_activeSessionId != null
                                          ? [_activeSessionId!]
                                          : <String>[]);
                              final displaySessions =
                                  sessions.isEmpty ? <String>[] : sessions;
                              final aspectRatio =
                                  columns == 1
                                      ? 1.4
                                      : (columns == 2
                                          ? 1.5
                                          : (columns == 3
                                              ? 1.6
                                              : (columns == 4 ? 1.7 : 1.8)));
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
                                    autoResize: true,
                                    autofocus: true,
                                    deleteDetection: deleteDetection,
                                    readOnly: _showHHKB,
                                    keyboardType:
                                        _showHHKB
                                            ? TextInputType.none
                                            : TextInputType.text,
                                    backgroundOpacity: 1.0,
                                    padding: const EdgeInsets.all(8),
                                    textStyle: buildTerminalStyle(
                                      fontSize: 14,
                                    ),
                                  ),
                                );
                              }

                              return GridView.builder(
                                padding: padding,
                                physics: const BouncingScrollPhysics(),
                                gridDelegate:
                                    SliverGridDelegateWithFixedCrossAxisCount(
                                      crossAxisCount: columns,
                                      crossAxisSpacing: 12,
                                      mainAxisSpacing: 12,
                                      childAspectRatio: aspectRatio,
                                    ),
                                itemCount: displaySessions.length + 1,
                                itemBuilder: (context, index) {
                                  if (index == displaySessions.length) {
                                    return AddTerminalCard(
                                      onTap: _sendCreateSession,
                                    );
                                  }
                                  final sessionId = displaySessions[index];
                                  // Generate label with same priority as tab labels
                                  // Priority: custom name > xterm title > cwd name > default
                                  String cardLabel;
                                  if (_groupStore.hasCustomSessionName(sessionId)) {
                                    cardLabel = _groupStore.getSessionName(sessionId, index);
                                  } else {
                                    final xtermTitle = _terminalManager.getTitle(sessionId);
                                    if (xtermTitle != null && xtermTitle.isNotEmpty) {
                                      cardLabel = xtermTitle;
                                    } else if (_isHorizonMode) {
                                      final cwdName = _getCwdDisplayName(sessionId);
                                      cardLabel = cwdName ?? _groupStore.getSessionName(sessionId, index);
                                    } else {
                                      cardLabel = _groupStore.getSessionName(sessionId, index);
                                    }
                                  }
                                  return TerminalWindowCard(
                                    key: _terminalCardKeyFor(sessionId),
                                    sessionId: sessionId,
                                    terminal: _terminalFor(sessionId),
                                    controller: _controllerFor(sessionId),
                                    scrollController: _scrollControllerFor(
                                      sessionId,
                                    ),
                                    viewKey: _viewKeyFor(sessionId),
                                    label: cardLabel,
                                    isActive: sessionId == _activeSessionId,
                                    showHHKB: _showHHKB,
                                    isDragTarget:
                                        _dragging &&
                                        _dragTargetSessionId == sessionId,
                                    showActiveChevron: false,
                                    showActiveShadow: false,
                                    terminalStyle: buildTerminalStyle(
                                      fontSize: 12,
                                    ),
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
                            autoResize: false,
                            autofocus: true,
                            deleteDetection: deleteDetection,
                            readOnly: _showHHKB,
                            keyboardType:
                                _showHHKB
                                    ? TextInputType.none
                                    : TextInputType.text,
                            backgroundOpacity: 1.0,
                            padding: EdgeInsets.fromLTRB(
                              8,
                              4,
                              8,
                              _bottomBarHeight + 8,
                            ),
                            textStyle: buildTerminalStyle(
                              fontSize: 14,
                            ),
                          ),
                      if (_dragging && !_multiWindow)
                        Positioned.fill(
                          child: Container(
                            color: Colors.blue.withValues(alpha: 0.15),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
              if (!_chromeHidden)
                Positioned(
                  top: MediaQuery.of(context).padding.top + 86,
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
                            Colors.black.withValues(alpha: 0.4),
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
                  hidden: _chromeHidden,
                  color: barColor,
                  activeColor: activeColor,
                  overlayColor: overlayColor,
                  error: _error,
                  pairingPending: _clientPairingPending,
                  pairingTitle: 'Waiting for approval...',
                  pairingSubtitle: 'Approve this device on the workstation',
                  onToggle: () {
                    setState(() {
                      _chromeHidden = !_chromeHidden;
                    });
                    _scheduleActiveResize();
                  },
                  onAddSession: _sendCreateSession,
                  sessions: _visibleSessions,
                  activeSessionId: _activeSessionId,
                  sessionLabelBuilder: (sessionId, index) {
                    // Priority: custom name > xterm title > cwd name > default
                    // User custom name has highest priority
                    if (_groupStore.hasCustomSessionName(sessionId)) {
                      return _groupStore.getSessionName(sessionId, index);
                    }
                    final xtermTitle = _terminalManager.getTitle(sessionId);
                    if (xtermTitle != null && xtermTitle.isNotEmpty) {
                      return xtermTitle;
                    }
                    // In Horizon mode, show cwd name
                    if (_isHorizonMode) {
                      final cwdName = _getCwdDisplayName(sessionId);
                      if (cwdName != null && cwdName.isNotEmpty) {
                        return cwdName;
                      }
                    }
                    return _groupStore.getSessionName(sessionId, index);
                  },
                  onSelectSession:
                      (id) => _setActiveSession(id, requestKeyboard: true),
                  onCloseSession: _sendCloseSession,
                  onReorderSessions: _reorderSessions,
                  connectionContent: _buildConnectionContent(context),
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
                                  connected: isInputActive,
                                  ctrl: _ctrl,
                                  alt: _alt,
                                  meta: _meta,
                                  onToggleCtrl:
                                      () => setState(() => _ctrl = !_ctrl),
                                  onToggleAlt:
                                      () => setState(() => _alt = !_alt),
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
                      if (_showHHKB)
                        HHKBKeyboard(
                          connected: isInputActive,
                          fn: _hhkbFn,
                          ctrl: _ctrl,
                          alt: _alt,
                          shift: _hhkbShift,
                          onKey: (key, {bool isSpecial = false}) {
                            if (_ctrl && !isSpecial) {
                              _sendCtrl(key);
                            } else if (_alt && !isSpecial) {
                              _sendRaw('\x1b$key');
                            } else {
                              _sendRaw(key);
                            }
                            // Reset modifiers after key press (except Fn)
                            if (_ctrl || _alt || _hhkbShift) {
                              setState(() {
                                _ctrl = false;
                                _alt = false;
                                _hhkbShift = false;
                              });
                            }
                          },
                          onFnChanged: (fn) => setState(() => _hhkbFn = fn),
                          onToggleCtrl: () => setState(() => _ctrl = !_ctrl),
                          onToggleAlt: () => setState(() => _alt = !_alt),
                          onToggleShift:
                              () => setState(() => _hhkbShift = !_hhkbShift),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildConnectionContent(BuildContext context) {
    // Determine title and subtitle based on mode
    String title;
    String subtitle;
    bool switchValue;
    void Function(bool) onSwitchChanged;

    if (_isHorizonMode) {
      // Horizon mode (host)
      final localName = _hostController.hostDeviceName;
      final isRunning = _hostController.running;
      final clientCount = _hostController.clientCount;
      final lanEnabled = _hostController.lanEnabled;
      final wormholeEnabled = _hostController.wormholeEnabled;
      final wormholeConnected = _hostController.wormholeConnected;

      title = 'Horizon · $localName';

      if (!isRunning) {
        subtitle = 'Service stopped';
      } else {
        final modes = <String>[];
        if (lanEnabled) modes.add('LAN');
        if (wormholeEnabled) {
          modes.add(wormholeConnected ? 'Wormhole' : 'Wormhole (connecting)');
        }
        final modeStr = modes.isEmpty ? 'No sharing' : modes.join(' + ');
        subtitle =
            '$modeStr · $clientCount client${clientCount == 1 ? '' : 's'}';
      }

      switchValue = isRunning;
      onSwitchChanged = (value) {
        if (value) {
          _hostController.start();
        } else {
          _hostController.stop();
        }
      };
    } else {
      // Voyager mode (client)
      // Title: "Voyager · deviceName" or just "Voyager"
      title =
          _remoteDeviceName != null && _remoteDeviceName!.isNotEmpty
              ? 'Voyager · $_remoteDeviceName'
              : 'Voyager';

      // Subtitle: "Connected to LAN/Wormhole" or "Disconnected"
      if (_connected) {
        subtitle = _useWormhole ? 'Connected to Wormhole' : 'Connected to LAN';
      } else {
        subtitle = 'Disconnected';
      }

      switchValue = _connected;
      onSwitchChanged = (value) {
        if (value) {
          _connect();
        } else {
          _connectionManager.disconnect(shouldReconnect: false);
        }
      };
    }

    final isActive = _isHorizonMode ? _hostController.running : _connected;

    return Padding(
      padding: const EdgeInsets.only(top: 8, bottom: 8),
      child: SizedBox(
        height: 32,
        child: Row(
          children: [
            IconButton(
              icon: const Icon(Icons.menu, color: Colors.white70, size: 20),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              tooltip: 'Sessions',
            ),
            const SizedBox(width: 4),
            StatusDot(connected: isActive, size: 8),
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
                      color: Colors.white,
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
                      color: Color(0xFF4B7AA6),
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
            Switch(value: switchValue, onChanged: onSwitchChanged),
            const SizedBox(width: 8),
            IconButton(
              icon: const Icon(
                Icons.settings_outlined,
                color: Colors.white70,
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

  bool _isLocalVoyagerTarget() {
    if (_useWormhole) {
      return false;
    }
    final uri = Uri.tryParse(_urlController.text.trim());
    if (uri == null) {
      return false;
    }
    return _isLocalHost(uri.host);
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

  Widget _buildGroupDrawer(BuildContext context) {
    return GroupDrawer(
      manager: _groupStore,
      activeSessionId: _activeSessionId,
      onSelectSession:
          (sessionId) => _setActiveSession(sessionId, requestKeyboard: true),
      onCloseSession: _sendCloseSession,
      onAddSession: _sendCreateSessionInGroup,
      title: 'Sessions',
      showGroupCount: false,
      sessionLabelBuilder: (sessionId, index) {
        return _terminalManager.getTitle(sessionId) ??
            _groupStore.getSessionName(sessionId, index);
      },
    );
  }

  Widget _buildSettingsDrawer(BuildContext context) {
    return SettingsDrawer(
      isHorizonMode: _isHorizonMode,
      onModeChanged: (isHorizon) {
        setState(() => _isHorizonMode = isHorizon);
        _saveSettings();
        _handleModeSwitch(isHorizon);
      },
      useWormhole: _useWormhole,
      autoReconnect: _autoReconnect,
      multiWindow: _multiWindow,
      showKeyboardTools: _showKeyboardTools,
      showHHKB: _showHHKB,
      urlController: _urlController,
      wormholeController: _wormholeController,
      sessionController: _sessionController,
      tokenController: _tokenController,
      onUseWormholeChanged: (value) {
        if (_useWormhole == value) {
          return;
        }
        setState(() => _useWormhole = value);
        _connectionManager.disconnect(shouldReconnect: false);
        _saveSettings();
        if (!value) {
          _maybeAutoConnectLocal();
        }
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
      onShowHHKBChanged: (value) {
        setState(() => _showHHKB = value);
        _saveSettings();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _scheduleActiveResize();
        });
      },
      hostController: _hostController,
      hostWormholeUrlController: _hostWormholeUrlController,
      hostWormholeTokenController: _hostWormholeTokenController,
      hostCustomSessionController: _hostCustomSessionController,
      onHostWormholeConfigCommit: _syncHostWormholeConfig,
    );
  }
}
