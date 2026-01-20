import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:uuid/uuid.dart';

import '../services/group_manager.dart';
import '../services/terminal_service.dart';
import '../services/ws_server.dart';

/// Represents a paired device that has been approved to connect
enum DeviceType { mobile, desktop, web, unknown }

class PairedDevice {
  PairedDevice({
    required this.deviceKey,
    required this.deviceName,
    required this.firstPairedAt,
    required this.lastSeenAt,
    this.deviceType = DeviceType.unknown,
  });

  final String deviceKey;
  String deviceName;
  final DateTime firstPairedAt;
  DateTime lastSeenAt;
  DeviceType deviceType;

  Map<String, dynamic> toJson() => {
        'deviceKey': deviceKey,
        'deviceName': deviceName,
        'firstPairedAt': firstPairedAt.toIso8601String(),
        'lastSeenAt': lastSeenAt.toIso8601String(),
        'deviceType': deviceType.name,
      };

  factory PairedDevice.fromJson(Map<String, dynamic> json) => PairedDevice(
        deviceKey: json['deviceKey'] as String,
        deviceName: json['deviceName'] as String,
        firstPairedAt: DateTime.parse(json['firstPairedAt'] as String),
        lastSeenAt: DateTime.parse(json['lastSeenAt'] as String),
        deviceType: _parseDeviceType(json['deviceType'] as String?),
      );

  static DeviceType _parseDeviceType(String? type) {
    switch (type) {
      case 'mobile':
        return DeviceType.mobile;
      case 'desktop':
        return DeviceType.desktop;
      case 'web':
        return DeviceType.web;
      default:
        return DeviceType.unknown;
    }
  }
}

/// Represents a pending pairing request waiting for user confirmation
class PendingPairing {
  PendingPairing({
    required this.deviceKey,
    required this.deviceName,
    required this.requestedAt,
    this.deviceType = DeviceType.unknown,
  });

  final String? deviceKey;
  final String deviceName;
  final DateTime requestedAt;
  final DeviceType deviceType;
}

enum _BinaryType {
  stdin(1),
  stdout(2),
  resize(3),
  ping(4),
  pong(5),
  unknown(255);

  const _BinaryType(this.code);

  final int code;

  static _BinaryType fromCode(int code) {
    for (final value in _BinaryType.values) {
      if (value.code == code) {
        return value;
      }
    }
    return _BinaryType.unknown;
  }
}

class HorizonController extends ChangeNotifier {
  HorizonController({
    int port = 9527,
    Duration? pingInterval = const Duration(seconds: 10),
    bool devModeRequested = false,
    bool requireDevModeConfirmation = false,
  })  : _wsServer = WsServer(port: port, pingInterval: pingInterval),
        _devModeRequested = devModeRequested,
        _requireDevModeConfirmation = requireDevModeConfirmation,
        _wormholeBaseUrl = Platform.environment['WORMHOLE_URL'],
        _wormholeToken = Platform.environment['WORMHOLE_TOKEN'],
        _wormholeEnabled =
            (Platform.environment['WORMHOLE_URL'] ?? '').isNotEmpty,
        _hostDeviceName = Platform.localHostname;

  final TerminalPlugin _terminal = TerminalPlugin();
  final StreamController<TerminalOutput> _localOutputController =
      StreamController<TerminalOutput>.broadcast();
  final MethodChannel _systemChannel = const MethodChannel('com.blackhole/system');
  final WsServer _wsServer;
  final GroupManager _groupManager = GroupManager();
  String? _wormholeBaseUrl;
  String? _wormholeToken;
  bool _wormholeEnabled;
  bool _wormholeConnecting = false;
  bool _lanEnabled = true;
  String? _hostDeviceName;

  final Set<String> _sessions = {};
  final bool _devModeRequested;
  final bool _requireDevModeConfirmation;
  bool _running = false;
  bool _devModeConfirmed = false;
  WebSocket? _wormholeSocket;
  StreamSubscription? _wormholeSub;
  String? _wormholeSessionId;
  Timer? _wormholeReconnectTimer;
  int _wormholeReconnectDelaySeconds = 2;
  String? _error;
  String? _accessMessage;
  List<String> _addresses = const [];
  StreamSubscription<TerminalOutput>? _outputSub;
  DateTime? _stdoutProbeUntil;
  bool _stdoutProbeArmed = false;

  // Pairing related state
  List<PairedDevice> _pairedDevices = [];
  PendingPairing? _pendingPairing;
  bool _customSessionEnabled = false;
  String _customSessionId = '';
  static const _uuid = Uuid();

  // Wormhole client tracking
  int _wormholeClientCount = 0;

  bool get running => _running;
  String? get error => _error;
  String? get accessMessage => _accessMessage;
  List<String> get addresses => _addresses;
  int get clientCount => _wsServer.clientCount + _wormholeClientCount;
  int get port => _wsServer.port;
  bool get lanEnabled => _lanEnabled;
  bool get wormholeEnabled => _wormholeEnabled;
  bool get wormholeConnecting => _wormholeConnecting;
  bool get wormholeConnected => _wormholeEnabled && _wormholeSocket != null;
  String get wormholeBaseUrl => _wormholeBaseUrl ?? '';
  String get wormholeToken => _wormholeToken ?? '';
  String? get wormholeSessionId => _wormholeSessionId;
  String get wormholeSessionLabel => _wormholeSessionId ?? 'Connecting...';
  String get hostDeviceName =>
      _hostDeviceName?.trim().isNotEmpty == true
          ? _hostDeviceName!.trim()
          : Platform.localHostname;
  bool get devModeRequested => _devModeRequested;
  bool get devModeEnabled =>
      _devModeRequested && (!_requireDevModeConfirmation || _devModeConfirmed);
  bool get requiresDevModeConfirmation =>
      _devModeRequested && _requireDevModeConfirmation && !_devModeConfirmed;

  // Pairing related getters
  List<PairedDevice> get pairedDevices => List.unmodifiable(_pairedDevices);
  PendingPairing? get pendingPairing => _pendingPairing;
  bool get customSessionEnabled => _customSessionEnabled;
  String get customSessionId => _customSessionId;

  // ============ Local Mode API (for Horizon mode direct access) ============

  /// Get list of local session IDs
  List<String> get localSessions => _sessions.toList();

  /// Get the local terminal output stream (for direct subscription)
  Stream<TerminalOutput> get localOutputStream =>
      _localOutputController.stream;

  Future<void> applyLocalGroupCommand(Map<String, dynamic> payload) async {
    final type = payload['type'];
    if (type == 'group_create') {
      final name = payload['name'];
      await _handleGroupCreate(name is String ? name : null);
      return;
    }
    if (type == 'group_rename') {
      final groupId = payload['groupId'];
      final name = payload['name'];
      if (groupId is String && name is String) {
        _handleGroupRename(groupId, name);
      }
      return;
    }
    if (type == 'group_delete') {
      final groupId = payload['groupId'];
      if (groupId is String) {
        _handleGroupDelete(groupId);
      }
      return;
    }
    if (type == 'group_delete_with_sessions') {
      final groupId = payload['groupId'];
      if (groupId is String) {
        await _handleGroupDeleteWithSessions(groupId);
      }
      return;
    }
    if (type == 'group_move_session') {
      final sessionId = payload['sessionId'];
      final groupId = payload['groupId'];
      final oldIndex = payload['oldIndex'];
      final newIndex = payload['newIndex'];
      if (sessionId is String && groupId is String) {
        _handleGroupMoveSession(
          sessionId,
          groupId,
          oldIndex: oldIndex is int ? oldIndex : null,
          newIndex: newIndex is int ? newIndex : null,
        );
      }
      return;
    }
    if (type == 'group_reorder') {
      final groupId = payload['groupId'];
      final newIndex = payload['newIndex'];
      if (groupId is String && newIndex is int) {
        _handleGroupReorder(groupId, newIndex);
      }
      return;
    }
    if (type == 'session_rename') {
      final sessionId = payload['sessionId'];
      final name = payload['name'];
      if (sessionId is String && name is String) {
        _handleSessionRename(sessionId, name);
      }
    }
  }

  /// Create a new local session (without network broadcast)
  Future<String?> createLocalSession({String? groupId}) async {
    if (!_running) {
      return null;
    }
    final sessionId = await _terminal.startShell(rows: 24, cols: 80);
    _sessions.add(sessionId);
    var changed = false;
    if (groupId != null && groupId.isNotEmpty) {
      final result = _groupManager.moveSession(sessionId, groupId);
      changed = result.changed;
    } else {
      changed = _groupManager.onSessionCreated(sessionId);
    }
    unawaited(_groupManager.save());
    _notifySessionCreated(sessionId);
    if (changed) {
      _broadcastGroupSync();
    }
    notifyListeners();
    return sessionId;
  }

  /// Close a local session (without network broadcast)
  Future<void> closeLocalSession(String sessionId) async {
    if (!_sessions.contains(sessionId)) {
      return;
    }
    await _terminal.kill(sessionId);
    _sessions.remove(sessionId);
    final changed = _groupManager.onSessionClosed(sessionId);
    unawaited(_groupManager.save());
    _notifySessionClosed(sessionId);
    if (changed) {
      _broadcastGroupSync();
    }
    notifyListeners();
  }

  /// Write stdin to a local session
  Future<void> writeLocalStdin(String sessionId, Uint8List data) async {
    if (!_sessions.contains(sessionId)) {
      return;
    }
    await _terminal.writeStdin(sessionId, data);
  }

  /// Resize a local session
  Future<void> resizeLocalSession(String sessionId, int rows, int cols) async {
    if (!_sessions.contains(sessionId)) {
      return;
    }
    await _terminal.resize(sessionId, rows, cols);
  }

  /// Get group sync payload for local mode
  Map<String, dynamic> getLocalGroupSync() {
    _groupManager.reconcileSessions(_sessions);
    return _groupManager.buildSyncPayload();
  }

  void confirmDevMode() {
    if (!requiresDevModeConfirmation) {
      return;
    }
    _devModeConfirmed = true;
    notifyListeners();
    start();
  }

  void setHostDeviceName(String name) {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == _hostDeviceName) {
      return;
    }
    _hostDeviceName = trimmed;
    if (_running) {
      _broadcastHostInfo();
    }
    notifyListeners();
  }

  Future<void> requestFolderAccess() async {
    final home = Platform.environment['HOME'] ?? '/';
    try {
      final granted = await _systemChannel.invokeMethod<bool>('requestFolderAccess', {
        'initialPath': home,
      });
      _accessMessage = granted == true
          ? 'Folder access granted.'
          : 'Folder access denied.';
    } catch (error) {
      _accessMessage = 'Folder access failed: $error';
    }
    notifyListeners();
  }

  Future<void> start() async {
    if (_running) {
      return;
    }
    if (requiresDevModeConfirmation) {
      _error = 'Dev mode requires confirmation in release builds.';
      notifyListeners();
      return;
    }
    _error = null;
    notifyListeners();

    // Load paired devices
    await _loadPairedDevices();
    await _groupManager.load();
    if (_groupManager.reconcileSessions(_sessions)) {
      unawaited(_groupManager.save());
    }

    try {
      if (devModeEnabled) {
        debugPrint(
          '[WARN] Running in DEVELOPMENT MODE - authentication disabled',
        );
        debugPrint(
          '[WARN] Any device on the same network can connect without pairing',
        );
      }
      await _createSession();
      _wsServer.onClientCount = (_) => notifyListeners();
      _wsServer.onClientConnected = _sendSessionList;
      if (_lanEnabled) {
        await _wsServer.start(onMessage: _handleMessage);
      }
      _outputSub = _terminal.outputStream.listen(_handleTerminalOutput,
          onError: (error) {
        _error = 'Terminal output error: $error';
        notifyListeners();
      });
      if (_wormholeEnabled) {
        await _connectWormhole();
      }
      _addresses = _lanEnabled ? await _resolveAddresses() : const [];
      _running = true;
      _broadcastHostInfo();
      notifyListeners();
    } catch (error) {
      await _wsServer.stop();
      await _disconnectWormhole();
      await _killAllSessions();
      await _outputSub?.cancel();
      _outputSub = null;
      _error = 'Failed to start Horizon: $error';
      _running = false;
      notifyListeners();
    }
  }

  Future<void> stop() async {
    if (!_running) {
      return;
    }
    _running = false;
    notifyListeners();

    await _killAllSessions();
    await _wsServer.stop();
    await _disconnectWormhole();
    await _outputSub?.cancel();
    _outputSub = null;
  }

  Future<void> setLanEnabled(bool enabled) async {
    if (_lanEnabled == enabled) {
      return;
    }
    _lanEnabled = enabled;
    if (!_lanEnabled && !_wormholeEnabled) {
      if (_running) {
        await stop();
      } else {
        notifyListeners();
      }
      return;
    }
    if (!_running) {
      await start();
      return;
    }
    if (_lanEnabled) {
      await _wsServer.start(onMessage: _handleMessage);
      _addresses = await _resolveAddresses();
    } else {
      await _wsServer.stop();
      _addresses = const [];
    }
    notifyListeners();
  }

  Future<void> setWormholeEnabled(bool enabled) async {
    if (_wormholeEnabled == enabled) {
      return;
    }
    _wormholeEnabled = enabled;
    if (!_lanEnabled && !_wormholeEnabled) {
      if (_running) {
        await stop();
      } else {
        notifyListeners();
      }
      return;
    }
    if (!_running) {
      await start();
      return;
    }
    if (_wormholeEnabled) {
      await _connectWormhole();
    } else {
      await _disconnectWormhole();
    }
    notifyListeners();
  }

  Future<void> updateWormholeConfig({
    required String baseUrl,
    required String token,
  }) async {
    _wormholeBaseUrl = baseUrl.trim();
    _wormholeToken = token.trim();
    if (_wormholeBaseUrl != null && _wormholeBaseUrl!.isEmpty) {
      _wormholeBaseUrl = null;
    }
    if (_wormholeToken != null && _wormholeToken!.isEmpty) {
      _wormholeToken = null;
    }
    if (_running && _wormholeEnabled) {
      await _disconnectWormhole();
      await _connectWormhole();
    }
    notifyListeners();
  }

  Future<void> _handleMessage(WebSocket socket, dynamic message) async {
    final decoded = _decodeIncoming(message);
    if (decoded is! Map) {
      return;
    }
    if (decoded?['type'] == 'unsupported') {
      _sendError(
        socket,
        'unsupported_version',
        'Unsupported protocol version',
      );
      return;
    }
    final type = decoded?['type'];
    if (type == 'group_list') {
      _handleGroupList(socket: socket);
      return;
    }
    if (type == 'group_create') {
      final name = decoded?['name'];
      unawaited(_handleGroupCreate(name is String ? name : null, socket: socket));
      return;
    }
    if (type == 'group_rename') {
      final groupId = decoded?['groupId'];
      final name = decoded?['name'];
      if (groupId is String && name is String) {
        _handleGroupRename(groupId, name, socket: socket);
      }
      return;
    }
    if (type == 'group_delete') {
      final groupId = decoded?['groupId'];
      if (groupId is String) {
        _handleGroupDelete(groupId, socket: socket);
      }
      return;
    }
    if (type == 'group_move_session') {
      final sessionId = decoded?['sessionId'];
      final groupId = decoded?['groupId'];
      final oldIndex = decoded?['oldIndex'];
      final newIndex = decoded?['newIndex'];
      if (sessionId is String && groupId is String) {
        _handleGroupMoveSession(
          sessionId,
          groupId,
          socket: socket,
          oldIndex: oldIndex is int ? oldIndex : null,
          newIndex: newIndex is int ? newIndex : null,
        );
      }
      return;
    }
    if (type == 'session_rename') {
      final sessionId = decoded?['sessionId'];
      final name = decoded?['name'];
      if (sessionId is String && name is String) {
        _handleSessionRename(sessionId, name, socket: socket);
      }
      return;
    }
    if (type == 'group_reorder') {
      final groupId = decoded?['groupId'];
      final newIndex = decoded?['newIndex'];
      if (groupId is String && newIndex is int) {
        _handleGroupReorder(groupId, newIndex, socket: socket);
      }
      return;
    }
    if (type == 'group_delete_with_sessions') {
      final groupId = decoded?['groupId'];
      if (groupId is String) {
        unawaited(_handleGroupDeleteWithSessions(groupId, socket: socket));
      }
      return;
    }
    if (type == 'ping') {
      _wsServer.sendTo(socket, _buildPongMessage());
      return;
    }
    if (type == 'list') {
      _sendSessionList(socket);
      return;
    }
    if (type == 'create') {
      final groupId = decoded?['groupId'];
      if (groupId is String && groupId.isNotEmpty) {
        final sessionId = await _createSessionInGroup(groupId);
        if (sessionId != null) {
          unawaited(_groupManager.save());
          _broadcastGroupSync();
          _notifySessionCreated(sessionId, socket: socket);
        }
        return;
      }
      final sessionId = await _createSession();
      if (sessionId != null) {
        _notifySessionCreated(sessionId, socket: socket);
      }
      return;
    }
    if (type == 'close') {
      final sessionId = decoded?['sessionId'];
      if (sessionId is String) {
        await _closeSession(sessionId);
        _notifySessionClosed(sessionId);
      }
      return;
    }
    final sessionId = decoded?['sessionId'];
    if (sessionId is! String || !_sessions.contains(sessionId)) {
      return;
    }
    if (type == 'stdin') {
      final data = decoded?['data'];
      final raw = decoded?['raw'];
      if (data is String) {
        _logDeleteProbe('Horizon/LAN data', data.codeUnits);
        _armStdoutProbe(data.codeUnits);
        final bytes = Uint8List.fromList(utf8.encode(data));
        await _terminal.writeStdin(sessionId, bytes);
      } else if (raw is Uint8List) {
        _logDeleteProbe('Horizon/LAN raw', raw);
        _armStdoutProbe(raw);
        await _terminal.writeStdin(sessionId, raw);
      }
    } else if (type == 'resize') {
      final rows = decoded?['rows'];
      final cols = decoded?['cols'];
      if (rows is int && cols is int) {
        await _terminal.resize(sessionId, rows, cols);
      }
    }
  }

  void _handleTerminalOutput(TerminalOutput output) {
    if (!_sessions.contains(output.sessionId)) {
      return;
    }
    _localOutputController.add(output);
    _logDeleteProbe('Horizon/stdout', output.data);
    _logStdoutProbe(output.data);
    final message = _buildStdoutMessage(output.sessionId, output.data);
    _wsServer.broadcast(message);
    _sendToWormhole(message);
  }

  void _sendSessionList(WebSocket socket) {
    final changed = _reconcileGroupSessions();
    _wsServer.sendTo(
      socket,
      _encodeMessage({
        'type': 'session_list',
        'sessions': _sessions.toList(),
      }),
    );
    _wsServer.sendTo(socket, _buildHostInfoMessage());
    if (changed) {
      _broadcastGroupSync();
    } else {
      _sendGroupSync(socket: socket);
    }
  }

  Future<String?> _createSession() async {
    final sessionId = await _terminal.startShell(rows: 24, cols: 80);
    _sessions.add(sessionId);
    if (_groupManager.onSessionCreated(sessionId)) {
      unawaited(_groupManager.save());
      _broadcastGroupSync();
    }
    return sessionId;
  }

  Future<String?> _createSessionInGroup(String groupId) async {
    final sessionId = await _terminal.startShell(rows: 24, cols: 80);
    _sessions.add(sessionId);
    final result = _groupManager.moveSession(sessionId, groupId);
    if (!result.ok) {
      if (_groupManager.onSessionCreated(sessionId)) {
        unawaited(_groupManager.save());
        _broadcastGroupSync();
      }
    }
    return sessionId;
  }

  Future<void> _closeSession(String sessionId) async {
    if (!_sessions.contains(sessionId)) {
      return;
    }
    await _terminal.kill(sessionId);
    _sessions.remove(sessionId);
    if (_groupManager.onSessionClosed(sessionId)) {
      unawaited(_groupManager.save());
      _broadcastGroupSync();
    }
  }

  Future<void> _killAllSessions() async {
    final sessions = _sessions.toList();
    for (final sessionId in sessions) {
      await _terminal.kill(sessionId);
    }
    _sessions.clear();
    if (_groupManager.reconcileSessions(_sessions)) {
      unawaited(_groupManager.save());
    }
  }

  Future<List<String>> _resolveAddresses() async {
    final addresses = <String>[];
    final interfaces = await NetworkInterface.list(
      includeLoopback: false,
      type: InternetAddressType.IPv4,
    );
    for (final interface in interfaces) {
      for (final address in interface.addresses) {
        addresses.add(address.address);
      }
    }
    return addresses;
  }

  Future<void> _connectWormhole({bool isReconnect = false}) async {
    if (!_wormholeEnabled) {
      return;
    }
    if (_wormholeBaseUrl == null || _wormholeBaseUrl!.isEmpty) {
      return;
    }
    if (_wormholeSocket != null) {
      return;
    }
    // Use existing session ID for reconnection, otherwise let Wormhole assign one
    final uri = _buildWormholeUri(sessionId: _wormholeSessionId);
    if (uri == null) {
      return;
    }

    if (!isReconnect) {
      _wormholeConnecting = true;
      notifyListeners();
    }

    try {
      final socket = await WebSocket.connect(uri.toString());
      _wormholeSocket = socket;
      _wormholeConnecting = false;
      _wormholeSub = socket.listen(
        _handleWormholeMessage,
        onDone: () {
          _wormholeSocket = null;
          _scheduleWormholeReconnect();
        },
        onError: (error) {
          _wormholeSocket = null;
          _error = 'Wormhole error: $error';
          notifyListeners();
          _scheduleWormholeReconnect();
        },
      );
      _wormholeReconnectDelaySeconds = 2;
      _sendToWormhole(_buildHostInfoMessage());
      notifyListeners();
    } catch (error) {
      _wormholeConnecting = false;
      if (!isReconnect) {
        // First attempt failed - disable wormhole
        _wormholeEnabled = false;
        _error = 'Failed to connect Wormhole: $error';
      }
      notifyListeners();
      if (isReconnect) {
        _scheduleWormholeReconnect();
      }
    }
  }

  Uri? _buildWormholeUri({String? sessionId}) {
    try {
      final base = Uri.parse(_wormholeBaseUrl!);
      final query = Map<String, String>.from(base.queryParameters);
      query['role'] = 'horizon';

      // Use custom session ID if enabled, otherwise use provided sessionId for reconnection
      if (_customSessionEnabled && _customSessionId.isNotEmpty) {
        query['session'] = _customSessionId;
      } else if (sessionId != null && sessionId.isNotEmpty) {
        query['session'] = sessionId;
      }

      final token = _wormholeToken;
      if (token != null && token.isNotEmpty) {
        query['token'] = token;
      }
      return base.replace(queryParameters: query);
    } catch (_) {
      return null;
    }
  }

  Future<void> _disconnectWormhole() async {
    await _wormholeSub?.cancel();
    _wormholeSub = null;
    try {
      await _wormholeSocket?.close();
    } catch (_) {}
    _wormholeSocket = null;
    _wormholeReconnectTimer?.cancel();
    _wormholeReconnectTimer = null;
    _wormholeClientCount = 0;
  }

  void _sendToWormhole(Object message) {
    final socket = _wormholeSocket;
    if (socket == null) {
      return;
    }
    try {
      socket.add(message);
    } catch (_) {
      _wormholeSocket = null;
    }
  }

  void _handleWormholeMessage(dynamic message) async {
    final decoded = _decodeIncoming(message);
    if (decoded is! Map) {
      return;
    }
    if (decoded?['type'] == 'unsupported') {
      return;
    }
    final type = decoded?['type'];
    if (type == 'group_list') {
      _handleGroupList(fromWormhole: true);
      return;
    }
    if (type == 'group_create') {
      final name = decoded?['name'];
      unawaited(_handleGroupCreate(name is String ? name : null, fromWormhole: true));
      return;
    }
    if (type == 'group_rename') {
      final groupId = decoded?['groupId'];
      final name = decoded?['name'];
      if (groupId is String && name is String) {
        _handleGroupRename(groupId, name, fromWormhole: true);
      }
      return;
    }
    if (type == 'group_delete') {
      final groupId = decoded?['groupId'];
      if (groupId is String) {
        _handleGroupDelete(groupId, fromWormhole: true);
      }
      return;
    }
    if (type == 'group_move_session') {
      final sessionId = decoded?['sessionId'];
      final groupId = decoded?['groupId'];
      final oldIndex = decoded?['oldIndex'];
      final newIndex = decoded?['newIndex'];
      if (sessionId is String && groupId is String) {
        _handleGroupMoveSession(
          sessionId,
          groupId,
          fromWormhole: true,
          oldIndex: oldIndex is int ? oldIndex : null,
          newIndex: newIndex is int ? newIndex : null,
        );
      }
      return;
    }
    if (type == 'session_rename') {
      final sessionId = decoded?['sessionId'];
      final name = decoded?['name'];
      if (sessionId is String && name is String) {
        _handleSessionRename(sessionId, name, fromWormhole: true);
      }
      return;
    }
    if (type == 'group_reorder') {
      final groupId = decoded?['groupId'];
      final newIndex = decoded?['newIndex'];
      if (groupId is String && newIndex is int) {
        _handleGroupReorder(groupId, newIndex, fromWormhole: true);
      }
      return;
    }
    if (type == 'group_delete_with_sessions') {
      final groupId = decoded?['groupId'];
      if (groupId is String) {
        unawaited(_handleGroupDeleteWithSessions(groupId, fromWormhole: true));
      }
      return;
    }
    if (type == 'ping') {
      _sendToWormhole(_buildPongMessage());
      return;
    }
    if (type == 'session_assigned') {
      final assignedId = decoded?['sessionId'];
      if (assignedId is String && assignedId.isNotEmpty) {
        _wormholeSessionId = assignedId;
        debugPrint('[Wormhole] Session assigned: $assignedId');
        notifyListeners();
      }
      return;
    }
    if (type == 'voyager_connect') {
      final deviceKey = decoded?['deviceKey'] as String?;
      final deviceName = decoded?['deviceName'] as String? ?? 'Unknown Device';
      final deviceType =
          PairedDevice._parseDeviceType(decoded?['deviceType'] as String?);
      await _handleVoyagerConnect(deviceKey, deviceName, deviceType);
      _sendToWormhole(_buildHostInfoMessage());
      return;
    }
    if (type == 'voyager_disconnect') {
      final deviceKey = decoded?['deviceKey'] as String?;
      debugPrint('[Horizon] Voyager disconnected: $deviceKey');
      if (_wormholeClientCount > 0) {
        _wormholeClientCount--;
        notifyListeners();
      }
      return;
    }
    if (type == 'error') {
      final code = decoded?['code'] as String?;
      if (code == 'session_in_use') {
        _error = 'Custom session ID is already in use';
        notifyListeners();
      }
      return;
    }
    if (type == 'stdin') {
      final sessionId = decoded?['sessionId'];
      final data = decoded?['data'];
      final raw = decoded?['raw'];
      if (sessionId is String && _sessions.contains(sessionId)) {
        if (data is String) {
          _logDeleteProbe('Horizon/Wormhole data', data.codeUnits);
          _armStdoutProbe(data.codeUnits);
          final bytes = Uint8List.fromList(utf8.encode(data));
          _terminal.writeStdin(sessionId, bytes);
        } else if (raw is Uint8List) {
          _logDeleteProbe('Horizon/Wormhole raw', raw);
          _armStdoutProbe(raw);
          _terminal.writeStdin(sessionId, raw);
        }
      }
      return;
    }
    if (type == 'resize') {
      final sessionId = decoded?['sessionId'];
      final rows = decoded?['rows'];
      final cols = decoded?['cols'];
      if (sessionId is String &&
          rows is int &&
          cols is int &&
          _sessions.contains(sessionId)) {
        debugPrint(
          '[Horizon/Wormhole] resize session=$sessionId rows=$rows cols=$cols',
        );
        _terminal.resize(sessionId, rows, cols);
      }
      return;
    }
    if (type == 'list') {
      _sendSessionListToWormhole();
      return;
    }
    if (type == 'create') {
      final groupId = decoded?['groupId'];
      if (groupId is String && groupId.isNotEmpty) {
        final sessionId = await _createSessionInGroup(groupId);
        if (sessionId != null) {
          unawaited(_groupManager.save());
          _broadcastGroupSync();
          _notifySessionCreated(sessionId);
        }
        return;
      }
      final sessionId = await _createSession();
      if (sessionId != null) {
        _notifySessionCreated(sessionId);
      }
      return;
    }
    if (type == 'close') {
      final sessionId = decoded?['sessionId'];
      if (sessionId is String) {
        await _closeSession(sessionId);
        _notifySessionClosed(sessionId);
      }
    }
  }

  String _encodeMessage(Map<String, dynamic> payload) {
    if (!payload.containsKey('v')) {
      payload['v'] = 1;
    }
    return jsonEncode(payload);
  }

  Map<String, dynamic>? _decodeIncoming(dynamic message) {
    if (message is String) {
      return _decodeMessage(message);
    }
    if (message is Uint8List) {
      return _decodeBinaryMessage(message);
    }
    if (message is List<int>) {
      return _decodeBinaryMessage(Uint8List.fromList(message));
    }
    return null;
  }

  Map<String, dynamic>? _decodeMessage(String message) {
    final decoded = jsonDecode(message);
    if (decoded is! Map) {
      return null;
    }
    final map = Map<String, dynamic>.from(decoded);
    final version = map['v'];
    if (version != null && version != 1) {
      return {'type': 'unsupported', 'version': version};
    }
    return map;
  }

  Object _buildStdoutMessage(String sessionId, Uint8List data) {
    return _encodeBinaryMessage(_BinaryType.stdout, sessionId, data: data);
  }

  Object _buildPongMessage() {
    return _encodeBinaryMessage(_BinaryType.pong, '', data: Uint8List(0));
  }

  Object _buildHostInfoMessage() {
    return _encodeMessage({
      'type': 'host_info',
      'hostName': hostDeviceName,
    });
  }

  void _broadcastHostInfo() {
    final message = _buildHostInfoMessage();
    _wsServer.broadcast(message);
    _sendToWormhole(message);
  }

  void _sendSessionListToWormhole() {
    final changed = _reconcileGroupSessions();
    _sendToWormhole(
      _encodeMessage({
        'type': 'session_list',
        'sessions': _sessions.toList(),
      }),
    );
    if (changed) {
      _broadcastGroupSync();
    } else {
      _sendGroupSync(toWormhole: true);
    }
  }

  void _notifySessionCreated(String sessionId, {WebSocket? socket}) {
    final message = _encodeMessage({
      'type': 'session_created',
      'sessionId': sessionId,
    });
    if (socket != null) {
      _wsServer.sendTo(socket, message);
    } else {
      _wsServer.broadcast(message);
    }
    _sendToWormhole(message);
  }

  void _notifySessionClosed(String sessionId) {
    final message = _encodeMessage({
      'type': 'session_closed',
      'sessionId': sessionId,
    });
    _wsServer.broadcast(message);
    _sendToWormhole(message);
  }

  bool _reconcileGroupSessions() {
    final changed = _groupManager.reconcileSessions(_sessions);
    if (changed) {
      unawaited(_groupManager.save());
    }
    return changed;
  }

  void _broadcastGroupSync() {
    final message = _encodeMessage(_groupManager.buildSyncPayload());
    _wsServer.broadcast(message);
    _sendToWormhole(message);
  }

  void _sendGroupSync({WebSocket? socket, bool toWormhole = false}) {
    final message = _encodeMessage(_groupManager.buildSyncPayload());
    if (socket != null) {
      _wsServer.sendTo(socket, message);
    }
    if (toWormhole) {
      _sendToWormhole(message);
    }
  }

  void _sendGroupError({
    WebSocket? socket,
    bool toWormhole = false,
    required String code,
    required String message,
  }) {
    final payload = _encodeMessage({
      'type': 'group_error',
      'code': code,
      'message': message,
    });
    if (socket != null) {
      _wsServer.sendTo(socket, payload);
    }
    if (toWormhole) {
      _sendToWormhole(payload);
    }
  }

  void _handleGroupList({WebSocket? socket, bool fromWormhole = false}) {
    final changed = _reconcileGroupSessions();
    if (changed) {
      _broadcastGroupSync();
      return;
    }
    if (fromWormhole) {
      _sendGroupSync(toWormhole: true);
    } else if (socket != null) {
      _sendGroupSync(socket: socket);
    }
  }

  Future<void> _handleGroupCreate(
    String? name, {
    WebSocket? socket,
    bool fromWormhole = false,
  }) async {
    final result = _groupManager.createGroup(name: name);
    if (!result.ok) {
      _sendGroupError(
        socket: socket,
        toWormhole: fromWormhole,
        code: result.errorCode ?? 'invalid_request',
        message: result.errorMessage ?? 'Invalid group request.',
      );
      return;
    }
    if (result.changed && result.groupId != null) {
      // Create a terminal session and assign it to the new group
      final sessionId = await _createSessionInGroup(result.groupId!);
      unawaited(_groupManager.save());
      _broadcastGroupSync();
      if (sessionId != null) {
        _notifySessionCreated(sessionId, socket: socket);
      }
    }
  }

  void _handleGroupRename(
    String groupId,
    String name, {
    WebSocket? socket,
    bool fromWormhole = false,
  }) {
    final result = _groupManager.renameGroup(groupId, name);
    if (!result.ok) {
      _sendGroupError(
        socket: socket,
        toWormhole: fromWormhole,
        code: result.errorCode ?? 'invalid_request',
        message: result.errorMessage ?? 'Invalid group request.',
      );
      return;
    }
    if (result.changed) {
      unawaited(_groupManager.save());
      _broadcastGroupSync();
    }
  }

  void _handleGroupDelete(
    String groupId, {
    WebSocket? socket,
    bool fromWormhole = false,
  }) {
    final result = _groupManager.deleteGroup(groupId);
    if (!result.ok) {
      _sendGroupError(
        socket: socket,
        toWormhole: fromWormhole,
        code: result.errorCode ?? 'invalid_request',
        message: result.errorMessage ?? 'Invalid group request.',
      );
      return;
    }
    if (result.changed) {
      unawaited(_groupManager.save());
      _broadcastGroupSync();
    }
  }

  void _handleGroupMoveSession(
    String sessionId,
    String groupId, {
    WebSocket? socket,
    bool fromWormhole = false,
    int? oldIndex,
    int? newIndex,
  }) {
    if (!_sessions.contains(sessionId)) {
      _sendGroupError(
        socket: socket,
        toWormhole: fromWormhole,
        code: 'session_not_found',
        message: 'Session not found.',
      );
      return;
    }
    final result = _groupManager.moveSession(
      sessionId,
      groupId,
      oldIndex: oldIndex,
      newIndex: newIndex,
    );
    if (!result.ok) {
      _sendGroupError(
        socket: socket,
        toWormhole: fromWormhole,
        code: result.errorCode ?? 'invalid_request',
        message: result.errorMessage ?? 'Invalid group request.',
      );
      return;
    }
    if (result.changed) {
      unawaited(_groupManager.save());
      _broadcastGroupSync();
    }
  }

  void _handleSessionRename(
    String sessionId,
    String name, {
    WebSocket? socket,
    bool fromWormhole = false,
  }) {
    if (!_sessions.contains(sessionId)) {
      _sendGroupError(
        socket: socket,
        toWormhole: fromWormhole,
        code: 'session_not_found',
        message: 'Session not found.',
      );
      return;
    }
    final result = _groupManager.renameSession(sessionId, name);
    if (!result.ok) {
      _sendGroupError(
        socket: socket,
        toWormhole: fromWormhole,
        code: result.errorCode ?? 'invalid_request',
        message: result.errorMessage ?? 'Invalid rename request.',
      );
      return;
    }
    if (result.changed) {
      unawaited(_groupManager.save());
      _broadcastGroupSync();
    }
  }

  void _handleGroupReorder(
    String groupId,
    int newIndex, {
    WebSocket? socket,
    bool fromWormhole = false,
  }) {
    final result = _groupManager.reorderGroup(groupId, newIndex);
    if (!result.ok) {
      _sendGroupError(
        socket: socket,
        toWormhole: fromWormhole,
        code: result.errorCode ?? 'invalid_request',
        message: result.errorMessage ?? 'Invalid reorder request.',
      );
      return;
    }
    if (result.changed) {
      unawaited(_groupManager.save());
      _broadcastGroupSync();
    }
  }

  Future<void> _handleGroupDeleteWithSessions(
    String groupId, {
    WebSocket? socket,
    bool fromWormhole = false,
  }) async {
    final result = _groupManager.deleteGroup(groupId, closeSessions: true);
    if (!result.ok) {
      _sendGroupError(
        socket: socket,
        toWormhole: fromWormhole,
        code: result.errorCode ?? 'invalid_request',
        message: result.errorMessage ?? 'Invalid delete request.',
      );
      return;
    }
    // Close all sessions that were in the group
    final sessionsToClose = result.sessionIds ?? [];
    for (final sessionId in sessionsToClose) {
      await _closeSession(sessionId);
      _notifySessionClosed(sessionId);
    }
    if (result.changed) {
      unawaited(_groupManager.save());
      _broadcastGroupSync();
    }
  }

  Map<String, dynamic>? _decodeBinaryMessage(Uint8List data) {
    if (data.length < 4) {
      return null;
    }
    final version = data[0];
    if (version != 1) {
      return {'type': 'unsupported', 'version': version};
    }
    final type = _BinaryType.fromCode(data[1]);
    final sessionLen = (data[2] << 8) | data[3];
    if (data.length < 4 + sessionLen) {
      return null;
    }
    final sessionBytes = data.sublist(4, 4 + sessionLen);
    final sessionId = utf8.decode(sessionBytes, allowMalformed: true);
    final payload = data.sublist(4 + sessionLen);

    switch (type) {
      case _BinaryType.stdin:
        return {
          'type': 'stdin',
          'sessionId': sessionId,
          'raw': Uint8List.fromList(payload),
        };
      case _BinaryType.stdout:
        return {
          'type': 'stdout',
          'sessionId': sessionId,
          'raw': Uint8List.fromList(payload),
        };
      case _BinaryType.resize:
        if (payload.length < 4) {
          return null;
        }
        final rows = (payload[0] << 8) | payload[1];
        final cols = (payload[2] << 8) | payload[3];
        return {
          'type': 'resize',
          'sessionId': sessionId,
          'rows': rows,
          'cols': cols,
        };
      case _BinaryType.ping:
        return {'type': 'ping'};
      case _BinaryType.pong:
        return {'type': 'pong'};
      case _BinaryType.unknown:
        return {'type': 'unsupported', 'version': version};
    }
  }

  Uint8List _encodeBinaryMessage(
    _BinaryType type,
    String sessionId, {
    required Uint8List data,
  }) {
    final sessionBytes = utf8.encode(sessionId);
    final length = 4 + sessionBytes.length + data.length;
    final buffer = BytesBuilder(copy: false)
      ..add([1, type.code])
      ..add([
        (sessionBytes.length >> 8) & 0xFF,
        sessionBytes.length & 0xFF,
      ])
      ..add(sessionBytes)
      ..add(data);
    final result = buffer.toBytes();
    if (result.length != length) {
      return Uint8List.fromList(result);
    }
    return result;
  }

  void _sendError(WebSocket socket, String code, String message) {
    _wsServer.sendTo(
      socket,
      _encodeMessage({'type': 'error', 'code': code, 'message': message}),
    );
  }

  void _logDeleteProbe(String label, List<int> bytes) {
    final hasBackspace = bytes.contains(0x08) || bytes.contains(0x7f);
    if (!hasBackspace) {
      return;
    }
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    debugPrint('[$label] stdin delete bytes: $hex');
  }

  void _armStdoutProbe(List<int> bytes) {
    final hasBackspace = bytes.contains(0x08) || bytes.contains(0x7f);
    if (!hasBackspace) {
      return;
    }
    _stdoutProbeUntil = DateTime.now().add(const Duration(milliseconds: 400));
    _stdoutProbeArmed = true;
  }

  void _logStdoutProbe(Uint8List bytes) {
    if (!_stdoutProbeArmed) {
      return;
    }
    final until = _stdoutProbeUntil;
    if (until == null || DateTime.now().isAfter(until)) {
      _stdoutProbeArmed = false;
      return;
    }
    final sample = bytes.length > 64 ? bytes.sublist(0, 64) : bytes;
    final hex = sample.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    debugPrint('[Horizon] stdout after delete bytes: $hex');
    _stdoutProbeArmed = false;
  }

  void _scheduleWormholeReconnect() {
    if (!_running ||
        !_wormholeEnabled ||
        _wormholeBaseUrl == null ||
        _wormholeBaseUrl!.isEmpty) {
      return;
    }
    if (_wormholeReconnectTimer != null) {
      return;
    }
    _wormholeReconnectTimer = Timer(
      Duration(seconds: _wormholeReconnectDelaySeconds),
      () {
        _wormholeReconnectTimer = null;
        if (!_running) {
          return;
        }
        _connectWormhole(isReconnect: true);
      },
    );
    _wormholeReconnectDelaySeconds =
        (_wormholeReconnectDelaySeconds * 2).clamp(2, 10);
  }

  // ============ Pairing Methods ============

  Future<void> _handleVoyagerConnect(
    String? deviceKey,
    String deviceName,
    DeviceType deviceType,
  ) async {
    // Check if this is a paired device
    final paired =
        _pairedDevices.where((d) => d.deviceKey == deviceKey).firstOrNull;

    if (paired != null) {
      // Already paired, auto-approve and update info
      paired.lastSeenAt = DateTime.now();
      paired.deviceName = deviceName;
      paired.deviceType = deviceType;
      await _savePairedDevices();
      _sendPairingResponse(deviceKey!, approved: true);
      _wormholeClientCount++;
      debugPrint('[Horizon] Auto-approved paired device: $deviceName');
      notifyListeners();
      return;
    }

    // New device, set pending pairing for user confirmation
    _pendingPairing = PendingPairing(
      deviceKey: deviceKey,
      deviceName: deviceName,
      requestedAt: DateTime.now(),
      deviceType: deviceType,
    );
    debugPrint('[Horizon] New device requesting pairing: $deviceName');
    notifyListeners();
  }

  void approvePairing({required bool remember}) {
    if (_pendingPairing == null) {
      return;
    }

    // Generate a new device key if the client didn't provide one
    final assignedKey = _pendingPairing!.deviceKey ?? _uuid.v4();

    if (remember) {
      final device = PairedDevice(
        deviceKey: assignedKey,
        deviceName: _pendingPairing!.deviceName,
        firstPairedAt: DateTime.now(),
        lastSeenAt: DateTime.now(),
        deviceType: _pendingPairing!.deviceType,
      );
      _pairedDevices.add(device);
      _savePairedDevices();
    }

    _sendPairingResponse(
      _pendingPairing!.deviceKey,
      approved: true,
      assignedKey: assignedKey,
    );
    _wormholeClientCount++;
    debugPrint('[Horizon] Approved pairing for: ${_pendingPairing!.deviceName}');
    _pendingPairing = null;
    notifyListeners();
  }

  void rejectPairing() {
    if (_pendingPairing == null) {
      return;
    }

    _sendPairingResponse(_pendingPairing!.deviceKey, approved: false);
    debugPrint('[Horizon] Rejected pairing for: ${_pendingPairing!.deviceName}');
    _pendingPairing = null;
    notifyListeners();
  }

  void _sendPairingResponse(String? deviceKey, {required bool approved, String? assignedKey}) {
    final response = {
      'type': 'pairing_response',
      'deviceKey': deviceKey,
      'approved': approved,
      if (assignedKey != null) 'assignedKey': assignedKey,
    };
    _sendToWormhole(_encodeMessage(response));
  }

  Future<void> removePairedDevice(String deviceKey) async {
    _pairedDevices.removeWhere((d) => d.deviceKey == deviceKey);
    await _savePairedDevices();
    notifyListeners();
  }

  void setCustomSessionEnabled(bool enabled) {
    if (_customSessionEnabled == enabled) {
      return;
    }
    _customSessionEnabled = enabled;
    _savePairedDevices(); // Settings are saved together
    notifyListeners();
  }

  void setCustomSessionId(String sessionId) {
    _customSessionId = sessionId.toUpperCase();
    _savePairedDevices(); // Settings are saved together
    notifyListeners();
  }

  Future<void> _loadPairedDevices() async {
    try {
      final home = Platform.environment['HOME'] ?? '/tmp';
      final dir = Directory('$home/.blackhole/horizon');
      final file = File('${dir.path}/paired_devices.json');

      if (!await file.exists()) {
        return;
      }

      final content = await file.readAsString();
      final json = jsonDecode(content) as Map<String, dynamic>;

      final devices = json['devices'] as List<dynamic>? ?? [];
      _pairedDevices = devices
          .map((d) => PairedDevice.fromJson(d as Map<String, dynamic>))
          .toList();

      final settings = json['settings'] as Map<String, dynamic>? ?? {};
      _customSessionEnabled = settings['customSessionEnabled'] as bool? ?? false;
      _customSessionId = settings['customSessionId'] as String? ?? '';

      debugPrint('[Horizon] Loaded ${_pairedDevices.length} paired devices');
    } catch (e) {
      debugPrint('[Horizon] Failed to load paired devices: $e');
    }
  }

  Future<void> _savePairedDevices() async {
    try {
      final home = Platform.environment['HOME'] ?? '/tmp';
      final dir = Directory('$home/.blackhole/horizon');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }

      final file = File('${dir.path}/paired_devices.json');
      final json = {
        'version': 1,
        'devices': _pairedDevices.map((d) => d.toJson()).toList(),
        'settings': {
          'customSessionEnabled': _customSessionEnabled,
          'customSessionId': _customSessionId,
        },
      };

      await file.writeAsString(const JsonEncoder.withIndent('  ').convert(json));
      debugPrint('[Horizon] Saved ${_pairedDevices.length} paired devices');
    } catch (e) {
      debugPrint('[Horizon] Failed to save paired devices: $e');
    }
  }

  @override
  void dispose() {
    _wsServer.stop();
    _killAllSessions();
    _disconnectWormhole();
    _outputSub?.cancel();
    _outputSub = null;
    _localOutputController.close();
    super.dispose();
  }
}
