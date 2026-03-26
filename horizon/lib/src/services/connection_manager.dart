import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

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

class ConnectionManager {
  ConnectionManager({
    required this.onConnected,
    required this.onConnectedChanged,
    required this.onDisconnected,
    required this.onPairingPendingChanged,
    required this.onHostInfo,
    required this.onError,
    required this.onGroupSync,
    required this.onGroupError,
    required this.onPairingResult,
    required this.onSessionList,
    required this.onSessionCreated,
    required this.onSessionClosed,
    required this.onStdoutBytes,
    required this.onStdout,
    this.onCwd,
    this.onSessionSync,
  });

  final void Function({required bool waitForPairing}) onConnected;
  final void Function(bool connected) onConnectedChanged;
  final VoidCallback onDisconnected;
  final void Function(bool pending) onPairingPendingChanged;
  final void Function(String? hostName) onHostInfo;
  final void Function(String message) onError;
  final void Function(Map<String, dynamic> payload) onGroupSync;
  final void Function(String message) onGroupError;
  final void Function({required bool approved, String? assignedKey})
  onPairingResult;
  final void Function(List<String> sessions) onSessionList;
  final void Function(String sessionId) onSessionCreated;
  final void Function(String sessionId) onSessionClosed;
  final void Function(String sessionId, Uint8List bytes) onStdoutBytes;
  final void Function(String sessionId, String text) onStdout;
  final void Function(String sessionId, String cwd)? onCwd;
  final void Function(String sessionId, String content)? onSessionSync;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  DateTime? _lastMessageAt;
  DateTime? _stdoutProbeUntil;
  bool _stdoutProbeArmed = false;

  bool _connected = false;
  bool _pairingPending = false;
  bool _autoReconnect = true;
  bool _shouldReconnect = false;
  int _reconnectDelaySeconds = 2;
  Uri? _lastUri;
  bool _lastWaitForPairing = false;

  bool get connected => _connected;
  bool get pairingPending => _pairingPending;

  Future<void> connect({
    required Uri uri,
    required bool waitForPairing,
    required bool autoReconnect,
  }) async {
    _shouldReconnect = true;
    _autoReconnect = autoReconnect;
    // Auto-append /ws if not present
    uri = _ensureWsPath(uri);
    _lastUri = uri;
    _lastWaitForPairing = waitForPairing;
    _resetConnectionState();

    try {
      final channel = WebSocketChannel.connect(uri);
      _channel = channel;
      _subscription = channel.stream.listen(
        _handleMessage,
        onDone: _handleConnectionClosed,
        onError: (error) {
          onError('WebSocket error: $error');
          _handleConnectionClosed();
        },
      );
      try {
        await channel.ready;
      } catch (error) {
        onError('Failed to connect: $error');
        _setConnected(false);
        _setPairingPending(false);
        _scheduleReconnect();
        return;
      }
      _setConnected(true);
      _setPairingPending(waitForPairing);
      _lastMessageAt = DateTime.now();
      _reconnectDelaySeconds = 2;
      onConnected(waitForPairing: waitForPairing);
      _startHeartbeat();
    } catch (error) {
      onError('Failed to connect: $error');
      _setConnected(false);
      _setPairingPending(false);
      _scheduleReconnect();
    }
  }

  void disconnect({bool shouldReconnect = false}) {
    _shouldReconnect = shouldReconnect;
    _resetConnectionState();
  }

  void updateAutoReconnect(bool enabled) {
    _autoReconnect = enabled;
    if (!enabled) {
      _reconnectTimer?.cancel();
      _reconnectTimer = null;
    }
  }

  void sendCommand(Map<String, dynamic> payload) {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    channel.sink.add(_encodeMessage(payload));
  }

  void sendSyncRequest(String sessionId) {
    sendCommand({'type': 'sync', 'sessionId': sessionId});
  }

  void sendRaw(String sessionId, String data) {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    _logDeleteProbe(data);
    final payload = _encodeBinaryMessage(
      _BinaryType.stdin,
      sessionId,
      data: Uint8List.fromList(utf8.encode(data)),
    );
    channel.sink.add(payload);
  }

  void sendResize(String sessionId, int cols, int rows) {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    final payload = _encodeBinaryMessage(
      _BinaryType.resize,
      sessionId,
      data: Uint8List.fromList([
        (rows >> 8) & 0xFF,
        rows & 0xFF,
        (cols >> 8) & 0xFF,
        cols & 0xFF,
      ]),
    );
    debugPrint('[Voyager] resize session=$sessionId rows=$rows cols=$cols');
    channel.sink.add(payload);
  }

  void sendPing() {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    channel.sink.add(_encodeMessage({'type': 'ping'}));
  }

  void _handleConnectionClosed() {
    if (!_connected) {
      return;
    }
    _resetConnectionState();
    _scheduleReconnect();
  }

  void _scheduleReconnect() {
    if (!_autoReconnect || !_shouldReconnect || _connected) {
      return;
    }
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(Duration(seconds: _reconnectDelaySeconds), () {
      if (_connected || !_autoReconnect || !_shouldReconnect) {
        return;
      }
      final uri = _lastUri;
      if (uri == null) {
        return;
      }
      unawaited(
        connect(
          uri: uri,
          waitForPairing: _lastWaitForPairing,
          autoReconnect: _autoReconnect,
        ),
      );
    });
    _reconnectDelaySeconds = (_reconnectDelaySeconds * 2).clamp(2, 10);
  }

  void _resetConnectionState() {
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _stopHeartbeat();
    _setConnected(false);
    _setPairingPending(false);
    onDisconnected();
  }

  void _setConnected(bool value) {
    if (_connected == value) {
      return;
    }
    _connected = value;
    onConnectedChanged(value);
  }

  void _setPairingPending(bool value) {
    if (_pairingPending == value) {
      return;
    }
    _pairingPending = value;
    onPairingPendingChanged(value);
  }

  void _handleMessage(dynamic message) {
    final decoded = _decodeIncoming(message);
    if (decoded == null) {
      return;
    }
    if (decoded['type'] == 'unsupported') {
      final version = decoded['version'];
      onError('Unsupported protocol version: $version');
      disconnect(shouldReconnect: false);
      return;
    }
    _lastMessageAt = DateTime.now();
    final type = decoded['type'];
    if (type == 'pong') {
      return;
    }
    if (type == 'host_info') {
      final hostName = decoded['hostName'];
      if (hostName is String && hostName.isNotEmpty) {
        onHostInfo(hostName);
      } else {
        onHostInfo(null);
      }
      return;
    }
    if (type == 'cwd') {
      final sessionId = decoded['sessionId'];
      final cwd = decoded['cwd'];
      if (sessionId is String && cwd is String) {
        onCwd?.call(sessionId, cwd);
      }
      return;
    }
    if (type == 'error') {
      final message = decoded['message'];
      if (message is String) {
        onError('Server error: $message');
        _setPairingPending(false);
      }
      return;
    }
    if (type == 'group_sync') {
      onGroupSync(Map<String, dynamic>.from(decoded));
      return;
    }
    if (type == 'group_error') {
      final message = decoded['message'];
      final code = decoded['code'];
      final text =
          message is String
              ? message
              : code is String
              ? code
              : 'Unknown group error';
      onGroupError(text);
      return;
    }
    if (type == 'pairing_result') {
      final approved = decoded['approved'] as bool? ?? false;
      final assignedKey = decoded['assignedKey'] as String?;
      _setPairingPending(false);
      onPairingResult(approved: approved, assignedKey: assignedKey);
      if (!approved) {
        disconnect(shouldReconnect: false);
      }
      return;
    }
    if (type == 'session_list') {
      final sessions = decoded['sessions'];
      if (sessions is List) {
        onSessionList(sessions.whereType<String>().toList());
      }
      return;
    }
    if (type == 'session_sync') {
      final sessionId = decoded['sessionId'];
      final content = decoded['content'];
      if (sessionId is String && content is String) {
        onSessionSync?.call(sessionId, content);
      }
      return;
    }
    if (type == 'session_created') {
      final sessionId = decoded['sessionId'];
      if (sessionId is String) {
        onSessionCreated(sessionId);
      }
      return;
    }
    if (type == 'session_closed') {
      final sessionId = decoded['sessionId'];
      if (sessionId is String) {
        onSessionClosed(sessionId);
      }
      return;
    }
    if (type == 'stdout') {
      final data = decoded['data'];
      final raw = decoded['raw'];
      final sessionId = decoded['sessionId'];
      if (sessionId is String) {
        if (raw is Uint8List) {
          _logDeleteProbe(utf8.decode(raw, allowMalformed: true));
          _logStdoutProbe(raw);
          onStdoutBytes(sessionId, raw);
        } else if (data is String) {
          _logDeleteProbe(data);
          _logStdoutProbe(utf8.encode(data));
          onStdout(sessionId, data);
        }
      }
    }
  }

  int _heartbeatMisses = 0;
  static const int _maxHeartbeatMisses = 3;

  void _startHeartbeat() {
    _stopHeartbeat();
    _heartbeatMisses = 0;
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!_connected) {
        return;
      }
      sendPing();
      final last = _lastMessageAt;
      if (last == null) {
        return;
      }
      final silence = DateTime.now().difference(last);
      if (silence > const Duration(seconds: 20)) {
        _heartbeatMisses++;
        debugPrint(
          '[Connection] heartbeat miss $_heartbeatMisses/$_maxHeartbeatMisses '
          '(silent ${silence.inSeconds}s)',
        );
        if (_heartbeatMisses >= _maxHeartbeatMisses) {
          debugPrint('[Connection] heartbeat exceeded max misses, reconnecting silently');
          _heartbeatMisses = 0;
          disconnect(shouldReconnect: true);
        }
      } else {
        _heartbeatMisses = 0;
      }
    });
  }

  void _stopHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
  }

  void _logDeleteProbe(String data) {
    final runes = data.runes.toList();
    final hasBackspace = runes.contains(0x08) || runes.contains(0x7f);
    if (!hasBackspace) {
      return;
    }
    final bytes = utf8.encode(data);
    final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ');
    debugPrint('[Voyager] stdin delete bytes: $hex');
    _stdoutProbeUntil = DateTime.now().add(const Duration(milliseconds: 400));
    _stdoutProbeArmed = true;
  }

  void _logStdoutProbe(List<int> bytes) {
    if (!_stdoutProbeArmed) {
      return;
    }
    final until = _stdoutProbeUntil;
    if (until == null || DateTime.now().isAfter(until)) {
      _stdoutProbeArmed = false;
      return;
    }
    final sample = bytes.length > 64 ? bytes.sublist(0, 64) : bytes;
    final hex = sample
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join(' ');
    debugPrint('[Voyager] stdout after delete bytes: $hex');
    _stdoutProbeArmed = false;
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

  Uint8List _encodeBinaryMessage(
    _BinaryType type,
    String sessionId, {
    required Uint8List data,
  }) {
    final sessionBytes = utf8.encode(sessionId);
    final buffer =
        BytesBuilder(copy: false)
          ..add([1, type.code])
          ..add([(sessionBytes.length >> 8) & 0xFF, sessionBytes.length & 0xFF])
          ..add(sessionBytes)
          ..add(data);
    return buffer.toBytes();
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

  /// Ensures the URI has /ws path suffix for WebSocket connections.
  /// Only adds /ws if path is empty or root (LAN mode).
  /// For Wormhole URLs with existing paths (e.g., /host/ABC123), leaves unchanged.
  Uri _ensureWsPath(Uri uri) {
    final path = uri.path;
    if (path.isEmpty || path == '/') {
      return uri.replace(path: '/ws');
    }
    // Path already has content (e.g., Wormhole paths), don't modify
    return uri;
  }
}
