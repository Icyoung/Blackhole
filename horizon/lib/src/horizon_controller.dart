import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'terminal_service.dart';
import 'ws_server.dart';

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
            (Platform.environment['WORMHOLE_URL'] ?? '').isNotEmpty;

  final TerminalPlugin _terminal = TerminalPlugin();
  final MethodChannel _systemChannel = const MethodChannel('com.blackhole/system');
  final WsServer _wsServer;
  String? _wormholeBaseUrl;
  String? _wormholeToken;
  bool _wormholeEnabled;
  bool _lanEnabled = true;

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

  bool get running => _running;
  String? get error => _error;
  String? get accessMessage => _accessMessage;
  List<String> get addresses => _addresses;
  int get clientCount => _wsServer.clientCount;
  int get port => _wsServer.port;
  bool get lanEnabled => _lanEnabled;
  bool get wormholeEnabled => _wormholeEnabled;
  String get wormholeBaseUrl => _wormholeBaseUrl ?? '';
  String get wormholeToken => _wormholeToken ?? '';
  String? get wormholeSessionId => _wormholeSessionId;
  String get wormholeSessionLabel => _wormholeSessionId ?? 'Connecting...';
  bool get devModeRequested => _devModeRequested;
  bool get devModeEnabled =>
      _devModeRequested && (!_requireDevModeConfirmation || _devModeConfirmed);
  bool get requiresDevModeConfirmation =>
      _devModeRequested && _requireDevModeConfirmation && !_devModeConfirmed;

  void confirmDevMode() {
    if (!requiresDevModeConfirmation) {
      return;
    }
    _devModeConfirmed = true;
    notifyListeners();
    start();
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
    if (_running) {
      if (_lanEnabled) {
        await _wsServer.start(onMessage: _handleMessage);
        _addresses = await _resolveAddresses();
      } else {
        await _wsServer.stop();
        _addresses = const [];
      }
    }
    notifyListeners();
  }

  Future<void> setWormholeEnabled(bool enabled) async {
    if (_wormholeEnabled == enabled) {
      return;
    }
    _wormholeEnabled = enabled;
    if (_running) {
      if (_wormholeEnabled) {
        await _connectWormhole();
      } else {
        await _disconnectWormhole();
      }
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
    if (type == 'ping') {
      _wsServer.sendTo(socket, _buildPongMessage());
      return;
    }
    if (type == 'list') {
      _sendSessionList(socket);
      return;
    }
    if (type == 'create') {
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
    _logDeleteProbe('Horizon/stdout', output.data);
    _logStdoutProbe(output.data);
    final message = _buildStdoutMessage(output.sessionId, output.data);
    _wsServer.broadcast(message);
    _sendToWormhole(message);
  }

  void _sendSessionList(WebSocket socket) {
    _wsServer.sendTo(
      socket,
      _encodeMessage({
        'type': 'session_list',
        'sessions': _sessions.toList(),
      }),
    );
  }

  Future<String?> _createSession() async {
    final sessionId = await _terminal.startShell(rows: 24, cols: 80);
    _sessions.add(sessionId);
    return sessionId;
  }

  Future<void> _closeSession(String sessionId) async {
    if (!_sessions.contains(sessionId)) {
      return;
    }
    await _terminal.kill(sessionId);
    _sessions.remove(sessionId);
  }

  Future<void> _killAllSessions() async {
    final sessions = _sessions.toList();
    for (final sessionId in sessions) {
      await _terminal.kill(sessionId);
    }
    _sessions.clear();
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

  Future<void> _connectWormhole() async {
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
    try {
      final socket = await WebSocket.connect(uri.toString());
      _wormholeSocket = socket;
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
    } catch (error) {
      _error = 'Failed to connect Wormhole: $error';
      notifyListeners();
      _scheduleWormholeReconnect();
    }
  }

  Uri? _buildWormholeUri({String? sessionId}) {
    try {
      final base = Uri.parse(_wormholeBaseUrl!);
      final query = Map<String, String>.from(base.queryParameters);
      query['role'] = 'horizon';
      // Only include session if explicitly provided (for reconnection)
      // Otherwise let Wormhole assign one
      if (sessionId != null && sessionId.isNotEmpty) {
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

  void _sendSessionListToWormhole() {
    _sendToWormhole(
      _encodeMessage({
        'type': 'session_list',
        'sessions': _sessions.toList(),
      }),
    );
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
        _connectWormhole();
      },
    );
    _wormholeReconnectDelaySeconds =
        (_wormholeReconnectDelaySeconds * 2).clamp(2, 10);
  }

  @override
  void dispose() {
    _wsServer.stop();
    _killAllSessions();
    _disconnectWormhole();
    _outputSub?.cancel();
    _outputSub = null;
    super.dispose();
  }
}
