import 'transport_models.dart';

const kVpnAppWebsocketHost = '10.13.37.1';
const kVpnAppWebsocketPort = 9527;
const kVpnPunchRetryInterval = Duration(seconds: 30);

bool isVpnAppWebsocketHost(String? host) => host == kVpnAppWebsocketHost;

enum VpnTunnelMode {
  direct,
  relay,
  unknown;

  static VpnTunnelMode fromName(String? value) {
    for (final mode in values) {
      if (mode.name == value) {
        return mode;
      }
    }
    return VpnTunnelMode.unknown;
  }
}

enum VpnHostInfoAction { ignore, markDirect, fallback }

enum VpnFallbackReason { vpnDisconnected, inTunnelNotPeer }

enum VpnPunchRetryAction { none, sendPeerEndpoint, startUpgrade }

class VpnPunchRetryDecision {
  const VpnPunchRetryDecision._({
    required this.action,
    required this.clearSwitchSuppression,
    required this.rearm,
  });

  const VpnPunchRetryDecision.none()
    : this._(
        action: VpnPunchRetryAction.none,
        clearSwitchSuppression: false,
        rearm: false,
      );

  const VpnPunchRetryDecision.sendPeerEndpoint()
    : this._(
        action: VpnPunchRetryAction.sendPeerEndpoint,
        clearSwitchSuppression: true,
        rearm: true,
      );

  const VpnPunchRetryDecision.startUpgrade()
    : this._(
        action: VpnPunchRetryAction.startUpgrade,
        clearSwitchSuppression: false,
        rearm: false,
      );

  final VpnPunchRetryAction action;
  final bool clearSwitchSuppression;
  final bool rearm;
}

class VpnTransportEndpoint {
  const VpnTransportEndpoint({required this.serverIp, required this.lanPort});

  final String serverIp;
  final int lanPort;

  Uri get websocketUri => Uri.parse('ws://$serverIp:$lanPort/ws');

  @override
  String toString() =>
      'VpnTransportEndpoint(serverIp: $serverIp, lanPort: $lanPort)';
}

class VpnTunnelSnapshot {
  const VpnTunnelSnapshot({
    required this.isActive,
    required this.isConnected,
    required this.mode,
    this.clientIp,
    this.serverIp,
    this.lanPort,
    this.tunPacketsIn,
    this.udpPacketsIn,
    this.wgRxBytes,
    this.directSessionReady,
    this.timeSinceLastHandshakeSecs,
    this.error,
  });

  final bool isActive;
  final bool isConnected;
  final VpnTunnelMode mode;
  final String? clientIp;
  final String? serverIp;
  final int? lanPort;
  final int? tunPacketsIn;
  final int? udpPacketsIn;
  final int? wgRxBytes;
  final bool? directSessionReady;
  final int? timeSinceLastHandshakeSecs;
  final String? error;

  factory VpnTunnelSnapshot.fromJson(Map<String, dynamic> map) {
    final status = map['status'] as String?;
    return VpnTunnelSnapshot(
      isActive:
          map['isActive'] as bool? ??
          status == 'connected' || status == 'connecting',
      isConnected: map['isConnected'] as bool? ?? status == 'connected',
      mode: VpnTunnelMode.fromName(
        (map['mode'] ?? map['connectionMode']) as String?,
      ),
      clientIp: map['clientIp'] as String?,
      serverIp: map['serverIp'] as String?,
      lanPort: (map['lanPort'] as num?)?.toInt(),
      tunPacketsIn: (map['tunPacketsIn'] as num?)?.toInt(),
      udpPacketsIn: (map['udpPacketsIn'] as num?)?.toInt(),
      wgRxBytes: (map['wgRxBytes'] as num?)?.toInt(),
      directSessionReady: map['directSessionReady'] as bool?,
      timeSinceLastHandshakeSecs:
          (map['timeSinceLastHandshakeSecs'] as num?)?.toInt(),
      error: map['error'] as String?,
    );
  }
}

enum VpnTransportDecisionType { none, switchTransport, fallbackToPrimary }

class VpnTransportDecision {
  const VpnTransportDecision._({
    required this.type,
    this.endpoint,
    this.transportKind,
    this.reason,
  });

  const VpnTransportDecision.none()
    : this._(type: VpnTransportDecisionType.none);

  const VpnTransportDecision.switchTransport({
    required VpnTransportEndpoint endpoint,
    required TransportKind transportKind,
    required String reason,
  }) : this._(
         type: VpnTransportDecisionType.switchTransport,
         endpoint: endpoint,
         transportKind: transportKind,
         reason: reason,
       );

  const VpnTransportDecision.fallbackToPrimary({required String reason})
    : this._(type: VpnTransportDecisionType.fallbackToPrimary, reason: reason);

  final VpnTransportDecisionType type;
  final VpnTransportEndpoint? endpoint;
  final TransportKind? transportKind;
  final String? reason;

  bool get shouldSwitch => type == VpnTransportDecisionType.switchTransport;
  bool get shouldFallback => type == VpnTransportDecisionType.fallbackToPrimary;
}

class VpnTransportHandoffCoordinator {
  VpnTransportHandoffCoordinator({
    Duration directReadyWindow = const Duration(seconds: 2),
    Duration fallbackGraceWindow = const Duration(seconds: 4),
    Duration fallbackSuppressionWindow = const Duration(seconds: 8),
  }) : _directReadyWindow = directReadyWindow,
       _fallbackGraceWindow = fallbackGraceWindow,
       _fallbackSuppressionWindow = fallbackSuppressionWindow;

  bool _wasVpnConnected = false;
  bool _pendingSwitch = false;
  bool _suppressFallback = false;
  bool _switchSuppressed = false;
  bool _readyForTransportSwitch = false;
  VpnTunnelSnapshot? _lastSnapshot;
  DateTime? _connectedAt;
  DateTime? _lastTransportSwitchAt;
  DateTime? _disconnectObservedAt;

  final Duration _directReadyWindow;
  final Duration _fallbackGraceWindow;
  final Duration _fallbackSuppressionWindow;

  bool get pendingSwitch => _pendingSwitch;
  bool get switchSuppressed => _switchSuppressed;

  void reset() {
    _wasVpnConnected = false;
    _pendingSwitch = false;
    _suppressFallback = false;
    _switchSuppressed = false;
    _readyForTransportSwitch = false;
    _lastSnapshot = null;
    _connectedAt = null;
    _lastTransportSwitchAt = null;
    _disconnectObservedAt = null;
  }

  void cancelPendingSwitch() {
    _pendingSwitch = false;
  }

  void suppressNextFallback() {
    _suppressFallback = true;
  }

  void clearFallbackSuppression() {
    _suppressFallback = false;
  }

  void suppressSwitch() {
    _switchSuppressed = true;
    _pendingSwitch = false;
  }

  void clearSwitchSuppression() {
    _switchSuppressed = false;
  }

  VpnTransportEndpoint? restoreEndpointFromNativeStatus({
    required VpnTransportEndpoint? currentEndpoint,
    required VpnTunnelSnapshot snapshot,
    required int defaultLanPort,
  }) {
    if (currentEndpoint != null) {
      return null;
    }
    final hasUsableTunnelState =
        snapshot.isActive ||
        snapshot.isConnected ||
        snapshot.mode != VpnTunnelMode.unknown;
    if (!hasUsableTunnelState) {
      return null;
    }
    final serverIp = snapshot.serverIp;
    if (serverIp == null || serverIp.isEmpty) {
      return null;
    }
    return VpnTransportEndpoint(
      serverIp: serverIp,
      lanPort: snapshot.lanPort ?? defaultLanPort,
    );
  }

  VpnTransportDecision onPrimaryConnectionOpened({
    required bool vpnConnected,
    required VpnTunnelMode vpnMode,
    required TransportKind activeTransportKind,
    required VpnTransportEndpoint? endpoint,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now().toUtc();
    if (_switchSuppressed ||
        !_pendingSwitch ||
        !vpnConnected ||
        vpnMode == VpnTunnelMode.relay ||
        endpoint == null ||
        !_needsInTunnelHandoff(activeTransportKind)) {
      return const VpnTransportDecision.none();
    }
    _readyForTransportSwitch = _isReadyForTransportSwitch(
      connectedAt: _connectedAt,
      now: timestamp,
      snapshot: _lastSnapshot,
      endpoint: endpoint,
    );
    if (!_readyForTransportSwitch) {
      return const VpnTransportDecision.none();
    }
    return _switchToInTunnel(
      endpoint: endpoint,
      reason: 'primary_connection_opened',
      timestamp: timestamp,
    );
  }

  VpnTransportDecision onVpnStatusChanged({
    required VpnTunnelSnapshot snapshot,
    required bool primaryConnectionConnected,
    required TransportKind activeTransportKind,
    required VpnTransportEndpoint? endpoint,
    DateTime? now,
  }) {
    final timestamp = now ?? DateTime.now().toUtc();
    _lastSnapshot = snapshot;
    if (snapshot.isConnected && !_wasVpnConnected && endpoint != null) {
      _wasVpnConnected = true;
      _connectedAt = timestamp;
      _disconnectObservedAt = null;
      final readyForSwitch = _isReadyForTransportSwitch(
        connectedAt: _connectedAt,
        now: timestamp,
        snapshot: snapshot,
        endpoint: endpoint,
      );
      _readyForTransportSwitch = readyForSwitch;
      if (_switchSuppressed || snapshot.mode == VpnTunnelMode.relay) {
        _pendingSwitch = true;
        return const VpnTransportDecision.none();
      }
      if (primaryConnectionConnected &&
          _needsInTunnelHandoff(activeTransportKind)) {
        if (!readyForSwitch) {
          _pendingSwitch = true;
          return const VpnTransportDecision.none();
        }
        return _switchToInTunnel(
          endpoint: endpoint,
          reason: 'vpn_connected',
          timestamp: timestamp,
        );
      }
      _pendingSwitch = true;
      return const VpnTransportDecision.none();
    }

    if (snapshot.isConnected &&
        _wasVpnConnected &&
        _pendingSwitch &&
        endpoint != null) {
      final readyForSwitch = _isReadyForTransportSwitch(
        connectedAt: _connectedAt,
        now: timestamp,
        snapshot: snapshot,
        endpoint: endpoint,
      );
      _readyForTransportSwitch = readyForSwitch;
      if (!_switchSuppressed &&
          snapshot.mode != VpnTunnelMode.relay &&
          readyForSwitch &&
          primaryConnectionConnected &&
          _needsInTunnelHandoff(activeTransportKind)) {
        return _switchToInTunnel(
          endpoint: endpoint,
          reason: 'vpn_stable',
          timestamp: timestamp,
        );
      }
    }

    if (snapshot.isConnected &&
        _wasVpnConnected &&
        !_pendingSwitch &&
        !_switchSuppressed &&
        snapshot.mode != VpnTunnelMode.relay &&
        endpoint != null &&
        primaryConnectionConnected &&
        _needsInTunnelHandoff(activeTransportKind)) {
      final lastSwitchAt = _lastTransportSwitchAt;
      final cooldownElapsed =
          lastSwitchAt == null ||
          timestamp.difference(lastSwitchAt) >= _fallbackSuppressionWindow;
      if (cooldownElapsed) {
        final readyForSwitch = _isReadyForTransportSwitch(
          connectedAt: _connectedAt,
          now: timestamp,
          snapshot: snapshot,
          endpoint: endpoint,
        );
        _readyForTransportSwitch = readyForSwitch;
        if (readyForSwitch) {
          return _switchToInTunnel(
            endpoint: endpoint,
            reason: 'vpn_rearm_after_stale_switch',
            timestamp: timestamp,
          );
        }
      }
    }

    if (!snapshot.isConnected && _wasVpnConnected) {
      _disconnectObservedAt ??= timestamp;
      final disconnectedFor = timestamp.difference(_disconnectObservedAt!);
      if (disconnectedFor < _fallbackGraceWindow) {
        return const VpnTransportDecision.none();
      }
      _wasVpnConnected = false;
      _pendingSwitch = false;
      _readyForTransportSwitch = false;
      _lastSnapshot = snapshot;
      _connectedAt = null;
      _disconnectObservedAt = null;
      if (_suppressFallback) {
        _suppressFallback = false;
        return const VpnTransportDecision.none();
      }
      final lastSwitchAt = _lastTransportSwitchAt;
      if (lastSwitchAt != null &&
          !timestamp.isBefore(lastSwitchAt) &&
          timestamp.difference(lastSwitchAt) < _fallbackSuppressionWindow) {
        return const VpnTransportDecision.none();
      }
      return const VpnTransportDecision.fallbackToPrimary(
        reason: 'vpn_disconnected',
      );
    }

    return const VpnTransportDecision.none();
  }

  VpnTransportDecision _switchToInTunnel({
    required VpnTransportEndpoint endpoint,
    required String reason,
    required DateTime timestamp,
  }) {
    _pendingSwitch = false;
    _lastTransportSwitchAt = timestamp;
    return VpnTransportDecision.switchTransport(
      endpoint: endpoint,
      transportKind: TransportKind.unknown,
      reason: reason,
    );
  }

  static TransportKind transportKindForMode(VpnTunnelMode mode) {
    return switch (mode) {
      VpnTunnelMode.relay => TransportKind.unknown,
      VpnTunnelMode.direct => TransportKind.wireguardDirect,
      VpnTunnelMode.unknown => TransportKind.unknown,
    };
  }

  static VpnHostInfoAction hostInfoAction({
    required String? socketHost,
    required bool? vpnPeer,
  }) {
    if (!isVpnAppWebsocketHost(socketHost)) {
      return VpnHostInfoAction.ignore;
    }
    if (vpnPeer == true) {
      return VpnHostInfoAction.markDirect;
    }
    return VpnHostInfoAction.fallback;
  }

  static bool isStayOnWs({
    required bool handoffPending,
    required TransportKind activeKind,
    required String? socketHost,
    required bool connected,
  }) {
    if (handoffPending) {
      return false;
    }
    if (activeKind == TransportKind.wireguardDirect) {
      return false;
    }
    // lastUri is not the live socket until connected.
    if (connected && isVpnAppWebsocketHost(socketHost)) {
      return false;
    }
    return true;
  }

  static bool keepPunchIdentity(VpnFallbackReason reason) {
    return reason == VpnFallbackReason.inTunnelNotPeer;
  }

  static VpnPunchRetryDecision onPunchRetryTimer({
    required bool stayOnWs,
    required bool connected,
    required String? publicKey,
  }) {
    if (!stayOnWs) {
      return const VpnPunchRetryDecision.none();
    }
    if (publicKey != null && publicKey.isNotEmpty && connected) {
      return const VpnPunchRetryDecision.sendPeerEndpoint();
    }
    return const VpnPunchRetryDecision.startUpgrade();
  }

  static bool _needsInTunnelHandoff(TransportKind activeTransportKind) {
    return activeTransportKind == TransportKind.wormholeRelay ||
        activeTransportKind == TransportKind.lanDirect;
  }

  static bool satisfiesDirectReadinessGate(
    VpnTunnelSnapshot snapshot, {
    required VpnTransportEndpoint? endpoint,
  }) {
    if (!isVpnAppWebsocketHost(endpoint?.serverIp)) {
      return false;
    }
    if (!snapshot.isConnected) {
      return false;
    }
    final handshakeSecs = snapshot.timeSinceLastHandshakeSecs;
    final handshakeReady = handshakeSecs != null && handshakeSecs >= 0;
    return handshakeReady || snapshot.directSessionReady == true;
  }

  bool _isReadyForTransportSwitch({
    required DateTime? connectedAt,
    required DateTime now,
    required VpnTransportEndpoint? endpoint,
    VpnTunnelSnapshot? snapshot,
  }) {
    final readySince = connectedAt;
    if (readySince == null || now.difference(readySince) < _directReadyWindow) {
      return false;
    }
    if (snapshot == null) {
      return false;
    }
    return satisfiesDirectReadinessGate(snapshot, endpoint: endpoint);
  }
}
