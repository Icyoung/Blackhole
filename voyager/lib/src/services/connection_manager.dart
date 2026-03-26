import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'remote_log_service.dart';
import 'transport_models.dart';
import 'transport_orchestrator.dart';
import 'transport_telemetry.dart';

/// Horizon's WireGuard endpoint info received via Wormhole signaling.
class DirectCandidate {
  const DirectCandidate({
    required this.addr,
    required this.port,
    required this.scope,
    required this.priority,
    required this.source,
  });

  final String addr;
  final int port;
  final String scope;
  final int priority;
  final String source;

  factory DirectCandidate.fromMap(Map<String, dynamic> map) {
    return DirectCandidate(
      addr: map['addr'] as String? ?? '',
      port: (map['port'] as num?)?.toInt() ?? 0,
      scope: map['scope'] as String? ?? 'unknown',
      priority: (map['priority'] as num?)?.toInt() ?? 0,
      source: map['source'] as String? ?? 'unknown',
    );
  }

  Map<String, dynamic> toMap() => {
    'addr': addr,
    'port': port,
    'scope': scope,
    'priority': priority,
    'source': source,
  };
}

class EndpointInfo {
  const EndpointInfo({
    this.wgPublicKey,
    this.wgUdpPort,
    this.netcheckHost,
    this.netcheckPort,
    this.horizonAddr,
    this.horizonPort,
    this.clientIp,
    this.serverIp,
    this.subnet,
    this.dns,
    this.lanPort,
    this.internalRoutes,
    this.mtu,
    this.punchEpoch,
    this.horizonCandidates,
    this.voyagerCandidates,
    this.observedEndpoints,
    this.natMappingBehavior,
    this.hairpinLikely,
    this.directReachabilityScore,
  });

  final String? wgPublicKey;
  final int? wgUdpPort;
  final String? netcheckHost;
  final int? netcheckPort;
  final String? horizonAddr;
  final int? horizonPort;
  final String? clientIp;
  final String? serverIp;
  final String? subnet;
  final List<String>? dns;
  final int? lanPort;
  final List<String>? internalRoutes;
  final int? mtu;
  final int? punchEpoch;
  final List<DirectCandidate>? horizonCandidates;
  final List<DirectCandidate>? voyagerCandidates;
  final List<DirectCandidate>? observedEndpoints;
  final String? natMappingBehavior;
  final bool? hairpinLikely;
  final int? directReachabilityScore;

  EndpointInfo mergeWith(EndpointInfo? previous) {
    if (previous == null) {
      return this;
    }
    final (mergedNetcheckHost, mergedNetcheckPort) = _mergeNetcheckEndpoint(
      previousHost: previous.netcheckHost,
      previousPort: previous.netcheckPort,
      currentHost: netcheckHost,
      currentPort: netcheckPort,
    );
    return EndpointInfo(
      wgPublicKey: wgPublicKey ?? previous.wgPublicKey,
      wgUdpPort: wgUdpPort ?? previous.wgUdpPort,
      netcheckHost: mergedNetcheckHost,
      netcheckPort: mergedNetcheckPort,
      horizonAddr: horizonAddr ?? previous.horizonAddr,
      horizonPort: horizonPort ?? previous.horizonPort,
      clientIp: clientIp ?? previous.clientIp,
      serverIp: serverIp ?? previous.serverIp,
      subnet: subnet ?? previous.subnet,
      dns: dns ?? previous.dns,
      lanPort: lanPort ?? previous.lanPort,
      internalRoutes: internalRoutes ?? previous.internalRoutes,
      mtu: mtu ?? previous.mtu,
      punchEpoch: punchEpoch ?? previous.punchEpoch,
      horizonCandidates: _mergeDirectCandidateLists(
        previous.horizonCandidates,
        horizonCandidates,
      ),
      voyagerCandidates: _mergeDirectCandidateLists(
        previous.voyagerCandidates,
        voyagerCandidates,
      ),
      observedEndpoints: _mergeDirectCandidateLists(
        previous.observedEndpoints,
        observedEndpoints,
      ),
      natMappingBehavior: natMappingBehavior ?? previous.natMappingBehavior,
      hairpinLikely: hairpinLikely ?? previous.hairpinLikely,
      directReachabilityScore:
          directReachabilityScore ?? previous.directReachabilityScore,
    );
  }

  factory EndpointInfo.fromMap(Map<String, dynamic> map) {
    List<DirectCandidate>? parseCandidates(String key) {
      final raw = map[key];
      if (raw is! List) {
        return null;
      }
      final candidates =
          raw
              .whereType<Map>()
              .map(
                (entry) =>
                    DirectCandidate.fromMap(Map<String, dynamic>.from(entry)),
              )
              .where(
                (candidate) => candidate.addr.isNotEmpty && candidate.port > 0,
              )
              .toList();
      return candidates.isEmpty ? null : candidates;
    }

    return EndpointInfo(
      wgPublicKey: map['wgPublicKey'] as String?,
      wgUdpPort: (map['wgUdpPort'] as num?)?.toInt(),
      netcheckHost: map['netcheckHost'] as String?,
      netcheckPort: (map['netcheckPort'] as num?)?.toInt(),
      horizonAddr: map['horizonAddr'] as String?,
      horizonPort: (map['horizonPort'] as num?)?.toInt(),
      clientIp: map['clientIp'] as String?,
      serverIp: map['serverIp'] as String?,
      subnet: map['subnet'] as String?,
      dns: (map['dns'] as List<dynamic>?)?.map((e) => e as String).toList(),
      lanPort: (map['lanPort'] as num?)?.toInt(),
      internalRoutes:
          (map['internalRoutes'] as List<dynamic>?)
              ?.map((e) => e as String)
              .toList(),
      mtu: (map['mtu'] as num?)?.toInt(),
      punchEpoch: (map['punchEpoch'] as num?)?.toInt(),
      horizonCandidates: parseCandidates('horizonCandidates'),
      voyagerCandidates: parseCandidates('voyagerCandidates'),
      observedEndpoints: parseCandidates('observedEndpoints'),
      natMappingBehavior: map['natMappingBehavior'] as String?,
      hairpinLikely: map['hairpinLikely'] as bool?,
      directReachabilityScore:
          (map['directReachabilityScore'] as num?)?.toInt(),
    );
  }
}

(String?, int?) _mergeNetcheckEndpoint({
  required String? previousHost,
  required int? previousPort,
  required String? currentHost,
  required int? currentPort,
}) {
  final normalizedPreviousHost = previousHost?.trim();
  final normalizedCurrentHost = currentHost?.trim();
  final previousValid =
      normalizedPreviousHost != null &&
      normalizedPreviousHost.isNotEmpty &&
      previousPort != null &&
      previousPort > 0;
  final currentValid =
      normalizedCurrentHost != null &&
      normalizedCurrentHost.isNotEmpty &&
      currentPort != null &&
      currentPort > 0;

  if (!previousValid) {
    return (normalizedCurrentHost, currentPort);
  }
  if (!currentValid) {
    return (normalizedPreviousHost, previousPort);
  }
  if (normalizedPreviousHost == normalizedCurrentHost) {
    return (normalizedCurrentHost, currentPort);
  }
  if (_looksLikeIpLiteral(normalizedPreviousHost) &&
      !_looksLikeIpLiteral(normalizedCurrentHost)) {
    return (normalizedPreviousHost, previousPort);
  }
  return (normalizedCurrentHost, currentPort);
}

List<DirectCandidate>? _mergeDirectCandidateLists(
  List<DirectCandidate>? previous,
  List<DirectCandidate>? current,
) {
  if (previous == null || previous.isEmpty) {
    return current;
  }
  if (current == null || current.isEmpty) {
    return previous;
  }

  final merged = <String, DirectCandidate>{};

  void putAll(List<DirectCandidate> candidates) {
    for (final candidate in candidates) {
      final key = '${candidate.addr}:${candidate.port}/${candidate.scope}';
      merged[key] = candidate;
    }
  }

  putAll(previous);
  putAll(current);

  final result =
      merged.values.toList()..sort((a, b) => b.priority.compareTo(a.priority));
  return result;
}

bool _looksLikeIpLiteral(String host) {
  final ipv4 = RegExp(r'^\d{1,3}(?:\.\d{1,3}){3}$');
  if (ipv4.hasMatch(host)) {
    return true;
  }
  if (host.contains(':')) {
    return true;
  }
  return false;
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
    required this.onStdout,
    this.onSessionSync,
    this.onEndpointInfo,
    this.onVpnConfig,
  });

  final void Function({required bool waitForPairing}) onConnected;
  final void Function(bool connected) onConnectedChanged;
  final VoidCallback onDisconnected;
  final void Function(bool pending) onPairingPendingChanged;
  final void Function(String? hostName) onHostInfo;
  final void Function(String message) onError;
  final void Function(Map<String, dynamic> payload) onGroupSync;
  final void Function(String message) onGroupError;
  final void Function({
    required bool approved,
    String? assignedKey,
    String? horizonPublicKey,
  })
  onPairingResult;
  final void Function(List<String> sessions) onSessionList;
  final void Function(String sessionId) onSessionCreated;
  final void Function(String sessionId) onSessionClosed;
  final void Function(String sessionId, Uint8List data) onStdout;
  final void Function(String sessionId, String content)? onSessionSync;

  /// Called when Wormhole provides Horizon's WireGuard endpoint info.
  final void Function(EndpointInfo info)? onEndpointInfo;

  /// Called when Horizon sends a vpn_config response after peer registration.
  final void Function(EndpointInfo info)? onVpnConfig;

  EndpointInfo? _endpointInfo;
  EndpointInfo? get endpointInfo => _endpointInfo;

  WebSocketChannel? _channel;
  StreamSubscription? _subscription;
  Timer? _reconnectTimer;
  Timer? _heartbeatTimer;
  DateTime? _lastMessageAt;
  DateTime? _stdoutProbeUntil;
  bool _stdoutProbeArmed = false;
  final TransportOrchestrator _transportOrchestrator = TransportOrchestrator();
  final TransportTelemetry _telemetry = TransportTelemetry(source: 'voyager');

  bool _connected = false;
  bool _pairingPending = false;
  bool _autoReconnect = true;
  bool _shouldReconnect = false;
  int _reconnectDelaySeconds = 2;
  Uri? _lastUri;
  bool _lastWaitForPairing = false;
  TransportKind _activeTransportKind = TransportKind.unknown;
  String? _activeTransportId;
  String? _activePathId;
  String? _activeSwitchReason;
  String? _activeFallbackReason;
  int? _activeProbeRttMs;

  bool get connected => _connected;
  bool get pairingPending => _pairingPending;
  bool get shouldReconnect => _shouldReconnect;
  TransportKind get activeTransportKind => _activeTransportKind;
  String? get activeTransportId => _activeTransportId;
  String? get activePathId => _activePathId;
  String? get activeSwitchReason => _activeSwitchReason;
  String? get activeFallbackReason => _activeFallbackReason;
  int? get activeProbeRttMs => _activeProbeRttMs;

  Future<void> connect({
    required Uri uri,
    required bool waitForPairing,
    required bool autoReconnect,
    TransportKind transportKind = TransportKind.unknown,
    String? transportId,
    String? pathId,
    Duration readyTimeout = const Duration(seconds: 8),
    bool handoffExisting = false,
  }) async {
    final keepExisting =
        handoffExisting &&
        _channel != null &&
        _subscription != null &&
        _connected;
    final previousChannel = keepExisting ? _channel : null;
    final previousSubscription = keepExisting ? _subscription : null;
    final previousTransportKind = _activeTransportKind;
    final previousTransportId = _activeTransportId;
    final previousPathId = _activePathId;

    _shouldReconnect = true;
    _autoReconnect = autoReconnect;
    // Auto-append /ws if not present (LAN mode).
    uri = _ensureWsPath(uri);
    if (!keepExisting) {
      _lastUri = uri;
      _lastWaitForPairing = waitForPairing;
      _activeTransportKind = transportKind;
      _activeTransportId = transportId;
      _activePathId = pathId ?? transportId;
      _activeSwitchReason = null;
      _activeFallbackReason = null;
      _activeProbeRttMs = null;
      _resetConnectionState();
    }
    debugPrint(
      '[Connection] connect uri=$uri kind=${transportKind.wireName} '
      'transportId=${transportId ?? "-"} waitForPairing=$waitForPairing '
      'handoff=$keepExisting',
    );

    try {
      final channel = WebSocketChannel.connect(uri);
      try {
        await channel.ready.timeout(readyTimeout);
      } catch (error) {
        debugPrint('[Connection] ready failed uri=$uri error=$error');
        channel.sink.close();
        if (keepExisting) {
          onError('Failed to switch transport: $error');
          return;
        }
        _channel = null;
        onError('Failed to connect: $error');
        _setConnected(false);
        _setPairingPending(false);
        _scheduleReconnect();
        return;
      }

      // Close previous connection BEFORE listening on new one to prevent
      // duplicate message delivery during handoff.
      if (keepExisting) {
        _telemetry.emit(
          event: 'connection_closed',
          kind: previousTransportKind,
          transportId: previousTransportId,
          pathId: previousPathId,
          connected: false,
          extra: {'reason': 'transport_switch'},
        );
        previousSubscription?.cancel();
        previousChannel?.sink.close();
      }

      final subscription = channel.stream.listen(
        _handleMessage,
        onDone: () => _handleConnectionClosedFor(channel),
        onError: (error) {
          if (!identical(_channel, channel)) {
            return;
          }
          onError('WebSocket error: $error');
          _handleConnectionClosedFor(channel);
        },
        cancelOnError: false,
      );

      _channel = channel;
      _subscription = subscription;
      _lastUri = uri;
      _lastWaitForPairing = waitForPairing;
      _activeTransportKind = transportKind;
      _activeTransportId = transportId;
      _activePathId = pathId ?? transportId;
      _activeSwitchReason = null;
      _activeFallbackReason = null;
      _activeProbeRttMs = null;
      debugPrint('[Connection] connected uri=$uri');
      RemoteLogService.instance.start();
      RemoteLogService.instance.attach(channel);
      _setConnected(true);
      _setPairingPending(waitForPairing);
      _lastMessageAt = DateTime.now();
      _reconnectDelaySeconds = 2;
      _telemetry.emit(
        event: 'connection_opened',
        kind: _activeTransportKind,
        transportId: _activeTransportId,
        pathId: _activePathId,
        connected: true,
      );
      onConnected(waitForPairing: waitForPairing);
      _startHeartbeat();
    } catch (error) {
      debugPrint('[Connection] connect threw uri=$uri error=$error');
      if (keepExisting) {
        onError('Failed to switch transport: $error');
        return;
      }
      onError('Failed to connect: $error');
      _telemetry.emit(
        event: 'connection_closed',
        kind: _activeTransportKind,
        transportId: _activeTransportId,
        pathId: _activePathId,
        connected: false,
        error: error,
      );
      _setConnected(false);
      _setPairingPending(false);
      _scheduleReconnect();
    }
  }

  Future<void> connectWithCandidates({
    required List<TransportCandidate> candidates,
    required bool autoReconnect,
  }) async {
    if (candidates.isEmpty) {
      onError('No transport candidate available.');
      return;
    }

    // Keep legacy behavior for single candidate to avoid side effects
    // (e.g. pairing prompts triggered by probe connections).
    if (candidates.length == 1) {
      final candidate = candidates.first;
      await connect(
        uri: candidate.uri,
        waitForPairing: candidate.waitForPairing,
        autoReconnect: autoReconnect,
        transportKind: candidate.kind,
        transportId: candidate.id,
        pathId: '${candidate.kind.wireName}:${candidate.id}',
      );
      return;
    }

    final selection = await _transportOrchestrator.selectBest(
      candidates: candidates,
      probe: _probeCandidate,
    );
    final chosen = selection?.candidate ?? candidates.first;
    if (selection == null && chosen.kind == TransportKind.wormholeRelay) {
      _activeFallbackReason = 'probe_unavailable';
      _telemetry.emit(
        event: 'fallback_triggered',
        kind: chosen.kind,
        transportId: chosen.id,
        pathId: '${chosen.kind.wireName}:${chosen.id}',
        fallbackReason: _activeFallbackReason,
      );
    }
    _telemetry.emit(
      event: 'connection_selected',
      kind: chosen.kind,
      transportId: chosen.id,
      pathId: selection?.pathId ?? '${chosen.kind.wireName}:${chosen.id}',
      switchReason: selection?.switchReason,
      fallbackReason: selection?.fallbackReason ?? _activeFallbackReason,
      probeRttMs: selection?.probeResult.rtt?.inMilliseconds,
      extra: {'candidate_count': candidates.length},
    );

    await connect(
      uri: chosen.uri,
      waitForPairing: chosen.waitForPairing,
      autoReconnect: autoReconnect,
      transportKind: chosen.kind,
      transportId: chosen.id,
      pathId: selection?.pathId ?? '${chosen.kind.wireName}:${chosen.id}',
    );
    if (selection != null) {
      _activeSwitchReason = selection.switchReason;
      _activeFallbackReason = selection.fallbackReason;
      _activeProbeRttMs = selection.probeResult.rtt?.inMilliseconds;
    }
  }

  void disconnect({bool shouldReconnect = false, bool silent = false}) {
    if (_connected) {
      _telemetry.emit(
        event: 'connection_closed',
        kind: _activeTransportKind,
        transportId: _activeTransportId,
        pathId: _activePathId,
        connected: false,
        extra: {'reason': silent ? 'transport_switch' : 'manual_disconnect'},
      );
    }
    _shouldReconnect = shouldReconnect;
    _resetConnectionState(silent: silent);
  }

  /// Update the cached reconnect URI, e.g. after receiving an assigned
  /// device key from a pairing response.  Without this, automatic reconnects
  /// reuse the original URI which may lack the device_key parameter, causing
  /// Horizon to treat the device as new and show the pairing dialog again.
  void updateReconnectUri(Uri uri) {
    _lastUri = _ensureWsPath(uri);
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

  // Max chunk size to prevent PTY buffer overflow (1KB is safe for all platforms)
  static const int _maxChunkSize = 1024;

  void sendRaw(String sessionId, String data) {
    final channel = _channel;
    if (channel == null) {
      return;
    }
    _logDeleteProbe(data);

    final bytes = utf8.encode(data);

    // For small data, send directly
    if (bytes.length <= _maxChunkSize) {
      final payload = _encodeBinaryMessage(
        _BinaryType.stdin,
        sessionId,
        data: Uint8List.fromList(bytes),
      );
      channel.sink.add(payload);
      return;
    }

    // For large data, chunk it to prevent PTY buffer overflow
    _sendChunked(sessionId, bytes);
  }

  Future<void> _sendChunked(String sessionId, List<int> bytes) async {
    final channel = _channel;
    if (channel == null) return;

    for (var offset = 0; offset < bytes.length; offset += _maxChunkSize) {
      final end =
          (offset + _maxChunkSize < bytes.length)
              ? offset + _maxChunkSize
              : bytes.length;
      final chunk = bytes.sublist(offset, end);

      final payload = _encodeBinaryMessage(
        _BinaryType.stdin,
        sessionId,
        data: Uint8List.fromList(chunk),
      );
      channel.sink.add(payload);

      // Small delay between chunks to allow PTY buffer to drain
      if (end < bytes.length) {
        await Future.delayed(const Duration(milliseconds: 5));
      }
    }
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

  /// Request Horizon's WireGuard endpoint info from Wormhole.
  void sendEndpointRequest({
    String? wgPublicKey,
    int? wgUdpPort,
    String? deviceKey,
    List<DirectCandidate> voyagerCandidates = const <DirectCandidate>[],
  }) {
    sendCommand({
      'type': 'endpoint_probe_request',
      if (wgPublicKey != null) 'wgPublicKey': wgPublicKey,
      if (wgUdpPort != null) 'wgUdpPort': wgUdpPort,
      if (deviceKey != null) 'deviceKey': deviceKey,
      if (voyagerCandidates.isNotEmpty)
        'voyagerCandidates':
            voyagerCandidates.map((candidate) => candidate.toMap()).toList(),
      'supportsCandidateSet': true,
    });
  }

  /// Send our WireGuard public key to Horizon for peer registration.
  void sendPeerEndpoint(
    String wgPublicKey, {
    String? deviceKey,
    int? wgUdpPort,
    List<DirectCandidate> voyagerCandidates = const <DirectCandidate>[],
  }) {
    sendCommand({
      'type': 'direct_candidates_update',
      'wgPublicKey': wgPublicKey,
      if (deviceKey != null) 'deviceKey': deviceKey,
      if (wgUdpPort != null) 'wgUdpPort': wgUdpPort,
      if (voyagerCandidates.isNotEmpty)
        'voyagerCandidates':
            voyagerCandidates.map((candidate) => candidate.toMap()).toList(),
      'supportsCandidateSet': true,
    });
  }

  Future<TransportProbeResult> _probeCandidate(
    TransportCandidate candidate,
  ) async {
    _telemetry.emit(
      event: 'probe_started',
      kind: candidate.kind,
      transportId: candidate.id,
      pathId: '${candidate.kind.wireName}:${candidate.id}',
    );
    if (!candidate.probeByConnect) {
      _telemetry.emit(
        event: 'probe_result',
        kind: candidate.kind,
        transportId: candidate.id,
        pathId: '${candidate.kind.wireName}:${candidate.id}',
        probeRttMs: 999,
        extra: {'probe_mode': 'connect_skipped'},
      );
      return TransportProbeResult(
        candidate: candidate,
        success: true,
        rtt: const Duration(milliseconds: 999),
      );
    }
    final probeUri = _ensureWsPath(candidate.uri);
    final started = DateTime.now();
    try {
      final channel = WebSocketChannel.connect(probeUri);
      await channel.ready.timeout(const Duration(seconds: 3));
      final elapsed = DateTime.now().difference(started);
      await channel.sink.close();
      _telemetry.emit(
        event: 'probe_result',
        kind: candidate.kind,
        transportId: candidate.id,
        pathId: '${candidate.kind.wireName}:${candidate.id}',
        probeRttMs: elapsed.inMilliseconds,
      );
      return TransportProbeResult(
        candidate: candidate,
        success: true,
        rtt: elapsed,
      );
    } catch (error) {
      _telemetry.emit(
        event: 'probe_result',
        kind: candidate.kind,
        transportId: candidate.id,
        pathId: '${candidate.kind.wireName}:${candidate.id}',
        error: error,
      );
      return TransportProbeResult(
        candidate: candidate,
        success: false,
        error: error,
      );
    }
  }

  void _handleConnectionClosedFor(WebSocketChannel channel) {
    if (!identical(_channel, channel) || !_connected) {
      return;
    }
    RemoteLogService.instance.detach();
    _telemetry.emit(
      event: 'connection_closed',
      kind: _activeTransportKind,
      transportId: _activeTransportId,
      pathId: _activePathId,
      connected: false,
      extra: {'reason': 'remote_closed'},
    );
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
          transportKind: _activeTransportKind,
          transportId: _activeTransportId,
          pathId: _activePathId,
        ),
      );
    });
    _reconnectDelaySeconds = (_reconnectDelaySeconds * 2).clamp(2, 10);
  }

  void _resetConnectionState({bool silent = false}) {
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    _stopHeartbeat();
    _setConnected(false);
    _setPairingPending(false);
    if (!silent) {
      onDisconnected();
    }
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
    final controlType = TransportControlType.fromType(type as String?);
    if (type == 'pong') {
      return;
    }
    if (controlType == TransportControlType.transportProbeResult) {
      _handleTransportProbeResult(decoded);
      return;
    }
    if (controlType == TransportControlType.transportSwitchPrepare ||
        controlType == TransportControlType.transportSwitchCommit ||
        controlType == TransportControlType.transportSwitchAbort) {
      _applyTransportMetadata(decoded);
      _telemetry.emit(
        event: controlType.wireName.replaceAll('transport_', ''),
        kind: _activeTransportKind,
        transportId: _activeTransportId,
        pathId: _activePathId,
        switchReason: _activeSwitchReason,
        fallbackReason: _activeFallbackReason,
        probeRttMs: _activeProbeRttMs,
      );
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
    if (type == 'host_info') {
      final hostName = decoded['hostName'];
      if (hostName is String && hostName.isNotEmpty) {
        onHostInfo(hostName);
      } else {
        onHostInfo(null);
      }
      return;
    }
    if (type == 'endpoint_info' || type == 'endpoint_probe_response') {
      _endpointInfo = EndpointInfo.fromMap(decoded);
      onEndpointInfo?.call(_endpointInfo!);
      return;
    }
    if (type == 'vpn_config') {
      _endpointInfo = EndpointInfo.fromMap(decoded);
      onVpnConfig?.call(_endpointInfo!);
      return;
    }
    if (type == 'pairing_result') {
      final approved = decoded['approved'] as bool? ?? false;
      final assignedKey = decoded['assignedKey'] as String?;
      final horizonPublicKey = decoded['publicKey'] as String?;
      _setPairingPending(false);
      onPairingResult(
        approved: approved,
        assignedKey: assignedKey,
        horizonPublicKey: horizonPublicKey,
      );
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
        Uint8List? bytes;
        if (data is String) {
          bytes = Uint8List.fromList(utf8.encode(data));
        } else if (raw is Uint8List) {
          bytes = raw;
        }
        if (bytes != null) {
          _logDeleteProbe(utf8.decode(bytes, allowMalformed: true));
          _logStdoutProbe(bytes);
          onStdout(sessionId, bytes);
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
  /// For Wormhole URLs with existing paths, leaves unchanged.
  Uri _ensureWsPath(Uri uri) {
    final path = uri.path;
    if (path.isEmpty || path == '/') {
      return uri.replace(path: '/ws');
    }
    return uri;
  }

  void _handleTransportProbeResult(Map<String, dynamic> decoded) {
    final transportKind = TransportKind.fromWireName(
      decoded['transportKind'] as String?,
    );
    if (transportKind != TransportKind.unknown) {
      _activeTransportKind = transportKind;
    }
    _applyTransportMetadata(decoded);
  }

  void _applyTransportMetadata(Map<String, dynamic> decoded) {
    final metadata = TransportMetadata.fromWire(decoded);
    if (metadata.transportId != null && metadata.transportId!.isNotEmpty) {
      _activeTransportId = metadata.transportId;
    }
    if (metadata.pathId != null && metadata.pathId!.isNotEmpty) {
      _activePathId = metadata.pathId;
    }
    if (metadata.switchReason != null && metadata.switchReason!.isNotEmpty) {
      _activeSwitchReason = metadata.switchReason;
    }
    if (metadata.fallbackReason != null &&
        metadata.fallbackReason!.isNotEmpty) {
      _activeFallbackReason = metadata.fallbackReason;
      _telemetry.emit(
        event: 'fallback_triggered',
        kind: _activeTransportKind,
        transportId: _activeTransportId,
        pathId: _activePathId,
        fallbackReason: _activeFallbackReason,
      );
    }
    if (metadata.probeRttMs != null && metadata.probeRttMs! >= 0) {
      _activeProbeRttMs = metadata.probeRttMs;
    }
  }
}
