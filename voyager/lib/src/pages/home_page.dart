import 'dart:async';
import 'dart:io';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';

import '../models/terminal_group.dart';
import '../services/connection_manager.dart';
import '../services/crypto_service.dart';
import '../services/group_store.dart';
import '../services/terminal_manager.dart';
import '../widgets/add_terminal_card.dart';
import '../widgets/chrome/header_chrome.dart';
import '../widgets/common/status_dot.dart';
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
  final TextEditingController _urlController = TextEditingController(
    text: 'ws://127.0.0.1:9527',
  );
  final TextEditingController _wormholeController = TextEditingController(
    text: 'ws://127.0.0.1:8080/ws',
  );
  final TextEditingController _sessionController = TextEditingController();
  final TextEditingController _tokenController = TextEditingController();
  Timer? _metricsDebounce;

  late final ConnectionManager _connectionManager;
  late final TerminalManager _terminalManager;

  bool _connected = false;
  bool _autoReconnect = true;
  bool _chromeHidden = false;
  bool _useWormhole = false;
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
  String? _remoteDeviceName;
  bool _pairingPending = false;

  // E2E encryption
  final CryptoService _crypto = CryptoService();
  String? _publicKey;
  String? _horizonPublicKey;

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
      },
      logPrefix: 'Voyager',
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
        if (!mounted) {
          return;
        }
        setState(() {
          _error = message;
          _pairingPending = false;
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
      onPairingResult: ({
        required approved,
        String? assignedKey,
        String? horizonPublicKey,
      }) {
        if (approved) {
          if (assignedKey != null && assignedKey.isNotEmpty) {
            _deviceKey = assignedKey;
            _saveSettings();
          }
          // Setup encryption if Horizon provided public key
          if (horizonPublicKey != null && horizonPublicKey.isNotEmpty) {
            _horizonPublicKey = horizonPublicKey;
            _setupEncryption(horizonPublicKey);
          }
          if (mounted) {
            setState(() {
              _pairingPending = false;
              _error = null;
            });
          }
          debugPrint(
            '[Voyager] Pairing approved, deviceKey: $_deviceKey, hasHorizonPublicKey: ${horizonPublicKey != null}',
          );
          _sendListSessions();
        } else {
          if (mounted) {
            setState(() {
              _pairingPending = false;
              _error = 'Connection rejected by host';
              _connected = false;
            });
          }
          debugPrint('[Voyager] Pairing rejected');
        }
      },
      onSessionList: _handleSessionList,
      onSessionCreated: _handleSessionCreated,
      onSessionClosed: _handleSessionClosed,
      onStdout: _handleStdout,
      onSessionSync: _handleSessionSync,
    );
    _groupStore = GroupStore(
      onChanged: _handleGroupChange,
      sendCommand: _connectionManager.sendCommand,
    );
    unawaited(_groupStore.loadLocalOrder());
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
    if (needsRefresh && savedDeviceName != deviceName) {
      await prefs.setString('deviceName', deviceName);
    }

    // Load or generate crypto keys
    await _loadOrGenerateKeys(prefs);

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
      _deviceKey = prefs.getString('deviceKey');
      _deviceName = deviceName;
      _horizonPublicKey = prefs.getString('horizonPublicKey');
    });
    _connectionManager.updateAutoReconnect(_autoReconnect);
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
    // Request sync for all sessions in the new group
    for (final sessionId in _visibleSessions) {
      _requestSyncIfNeeded(sessionId);
    }
    setState(() {
      _syncActiveSessionWithGroup();
    });
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
    if (_deviceKey != null) {
      await prefs.setString('deviceKey', _deviceKey!);
    }
    await prefs.setString('deviceName', _deviceName);
  }

  @override
  void dispose() {
    _connectionManager.disconnect(shouldReconnect: false);
    WidgetsBinding.instance.removeObserver(this);
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
    _sessions.clear();
    _syncedSessions.clear();
    _activeSessionId = null;
    _terminalManager.activeSessionId = null;
    _terminalManager.clear();
    if (mounted) {
      setState(() {});
    }
  }

  void _handleSessionList(List<String> sessions) {
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
    _syncActiveSessionWithGroup();
    _terminalManager.activeSessionId = _activeSessionId;
    if (mounted) {
      setState(() {});
    }
    _scheduleActiveResize();
    if (_activeSessionId != null) {
      _restoreScrollOffset(_activeSessionId!);
    }
  }

  void _requestSyncIfNeeded(String sessionId) {
    if (_syncedSessions.contains(sessionId)) {
      return;
    }
    _syncedSessions.add(sessionId);
    _connectionManager.sendSyncRequest(sessionId);
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
  }

  void _handleSessionClosed(String sessionId) {
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
    if (content.isEmpty) {
      return;
    }
    // Write synced content to terminal
    _terminalManager.writeToTerminal(sessionId, content);
    // Note: No setState needed - TerminalView auto-updates via Terminal's notifyListeners
  }

  void _handleStdout(String sessionId, Uint8List data) {
    _terminalManager.writeToTerminalBytes(sessionId, data);
    // Note: No setState needed - TerminalView auto-updates via Terminal's notifyListeners
  }

  Future<void> _connect() async {
    if (mounted) {
      setState(() {
        _error = null;
        _pairingPending = false;
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
    // Add public key for E2E encryption
    if (_publicKey != null && _publicKey!.isNotEmpty) {
      query['public_key'] = _publicKey!;
    }
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

  void _setActiveSession(String sessionId, {bool requestKeyboard = false}) {
    if (_activeSessionId == sessionId) {
      if (requestKeyboard && !_multiWindow) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          _viewKeyFor(sessionId).currentState?.requestKeyboard();
        });
      }
      return;
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
    if (_activeSessionId == null || _activeSessionId != sessionId) {
      return;
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
    _activeTerminal?.keyInput(key);
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
    const barColor = Color(0xFF111620);
    const activeColor = Color(0xFF1E2D3D); // Slightly lighter for contrast
    const overlayColor =
        Colors.transparent; // No longer need overlay with solid background
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

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: Colors.black,
      drawer: _buildGroupDrawer(context),
      endDrawer: _buildSettingsDrawer(context),
      onDrawerChanged: (isOpened) {
        _groupStore.setDeferredSync(isOpened);
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
                                textStyle: TerminalStyle(
                                  fontFamily:
                                      kIsWeb
                                          ? GoogleFonts.jetBrainsMono()
                                              .fontFamily!
                                          : 'JetBrainsMono',
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
                        autoResize: false,
                        autofocus: true,
                        deleteDetection: deleteDetection,
                        readOnly: _showHHKB,
                        keyboardType:
                            _showHHKB ? TextInputType.none : TextInputType.text,
                        backgroundOpacity: 1.0,
                        padding: EdgeInsets.fromLTRB(
                          8,
                          4,
                          8,
                          _bottomBarHeight + 8,
                        ),
                        textStyle: TerminalStyle(
                          fontFamily:
                              kIsWeb
                                  ? GoogleFonts.jetBrainsMono().fontFamily!
                                  : 'JetBrainsMono',
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
              pairingPending: _pairingPending,
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
                return _terminalManager.getTitle(sessionId) ??
                    _groupStore.getSessionName(sessionId, index);
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
                  if (_showHHKB)
                    HHKBKeyboard(
                      connected: _connected,
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
                      onToggleFn: () => setState(() => _hhkbFn = !_hhkbFn),
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
  }

  Widget _buildConnectionContent(BuildContext context) {
    // Title: "Voyager · deviceName" or just "Voyager"
    final title =
        _remoteDeviceName != null && _remoteDeviceName!.isNotEmpty
            ? 'Voyager · $_remoteDeviceName'
            : 'Voyager';

    // Subtitle: "Connected to LAN/Wormhole" or "Disconnected"
    String subtitle;
    if (_connected) {
      subtitle = _useWormhole ? 'Connected to Wormhole' : 'Connected to LAN';
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
              icon: const Icon(Icons.menu, color: Colors.white70, size: 20),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
              tooltip: 'Groups',
            ),
            const SizedBox(width: 4),
            StatusDot(connected: _connected, size: 8),
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
            Switch(
              value: _connected,
              onChanged: (value) {
                if (value) {
                  _connect();
                } else {
                  _connectionManager.disconnect(shouldReconnect: false);
                }
              },
            ),
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

  Widget _buildGroupDrawer(BuildContext context) {
    return GroupDrawer(
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

  Widget _buildSettingsDrawer(BuildContext context) {
    return SettingsDrawer(
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
    );
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
