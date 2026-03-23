import 'transport_models.dart';

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
  bool _readyForTransportSwitch = false;
  VpnTunnelSnapshot? _lastSnapshot;
  DateTime? _connectedAt;
  DateTime? _lastTransportSwitchAt;
  DateTime? _disconnectObservedAt;

  final Duration _directReadyWindow;
  final Duration _fallbackGraceWindow;
  final Duration _fallbackSuppressionWindow;

  bool get pendingSwitch => _pendingSwitch;

  void reset() {
    _wasVpnConnected = false;
    _pendingSwitch = false;
    _suppressFallback = false;
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
      lanPort:
          snapshot.lanPort ?? _defaultLanPortFor(snapshot.mode, defaultLanPort),
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
    final desiredTransportKind = transportKindForMode(vpnMode);
    if (!_pendingSwitch ||
        !vpnConnected ||
        endpoint == null ||
        !_needsTransportSwitch(
          activeTransportKind: activeTransportKind,
          desiredTransportKind: desiredTransportKind,
        )) {
      return const VpnTransportDecision.none();
    }
    _readyForTransportSwitch = _isReadyForTransportSwitch(
      mode: vpnMode,
      connectedAt: _connectedAt,
      now: timestamp,
      snapshot: _lastSnapshot,
    );
    if (!_readyForTransportSwitch) {
      return const VpnTransportDecision.none();
    }
    _pendingSwitch = false;
    _lastTransportSwitchAt = timestamp;
    return VpnTransportDecision.switchTransport(
      endpoint: endpoint,
      transportKind: desiredTransportKind,
      reason: 'primary_connection_opened',
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
    final desiredTransportKind = transportKindForMode(snapshot.mode);
    if (snapshot.isConnected && !_wasVpnConnected && endpoint != null) {
      _wasVpnConnected = true;
      _connectedAt = timestamp;
      _disconnectObservedAt = null;
      final readyForSwitch = _isReadyForTransportSwitch(
        mode: snapshot.mode,
        connectedAt: _connectedAt,
        now: timestamp,
        snapshot: snapshot,
      );
      _readyForTransportSwitch = readyForSwitch;
      if (primaryConnectionConnected &&
          _needsTransportSwitch(
            activeTransportKind: activeTransportKind,
            desiredTransportKind: desiredTransportKind,
          )) {
        if (!readyForSwitch) {
          _pendingSwitch = true;
          return const VpnTransportDecision.none();
        }
        _pendingSwitch = false;
        _lastTransportSwitchAt = timestamp;
        return VpnTransportDecision.switchTransport(
          endpoint: endpoint,
          transportKind: desiredTransportKind,
          reason: 'vpn_connected',
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
        mode: snapshot.mode,
        connectedAt: _connectedAt,
        now: timestamp,
        snapshot: snapshot,
      );
      _readyForTransportSwitch = readyForSwitch;
      if (readyForSwitch &&
          primaryConnectionConnected &&
          _needsTransportSwitch(
            activeTransportKind: activeTransportKind,
            desiredTransportKind: desiredTransportKind,
          )) {
        _pendingSwitch = false;
        _lastTransportSwitchAt = timestamp;
        return VpnTransportDecision.switchTransport(
          endpoint: endpoint,
          transportKind: desiredTransportKind,
          reason: 'vpn_stable',
        );
      }
    }

    if (snapshot.isConnected &&
        primaryConnectionConnected &&
        endpoint != null &&
        _isVpnTransport(activeTransportKind) &&
        _needsTransportSwitch(
          activeTransportKind: activeTransportKind,
          desiredTransportKind: desiredTransportKind,
        )) {
      final lastSwitchAt = _lastTransportSwitchAt;
      if (lastSwitchAt != null &&
          !timestamp.isBefore(lastSwitchAt) &&
          timestamp.difference(lastSwitchAt) < const Duration(seconds: 2)) {
        return const VpnTransportDecision.none();
      }
      final readyForSwitch = _isReadyForTransportSwitch(
        mode: snapshot.mode,
        connectedAt: _connectedAt,
        now: timestamp,
        snapshot: snapshot,
      );
      _readyForTransportSwitch = readyForSwitch;
      if (readyForSwitch) {
        _lastTransportSwitchAt = timestamp;
        return VpnTransportDecision.switchTransport(
          endpoint: endpoint,
          transportKind: desiredTransportKind,
          reason: 'vpn_mode_changed',
        );
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

  static TransportKind transportKindForMode(VpnTunnelMode mode) {
    return switch (mode) {
      VpnTunnelMode.relay => TransportKind.unknown,
      VpnTunnelMode.direct => TransportKind.wireguardDirect,
      VpnTunnelMode.unknown => TransportKind.wireguardDirect,
    };
  }

  static bool _isVpnTransport(TransportKind kind) {
    return kind == TransportKind.wireguardDirect;
  }

  static bool _needsTransportSwitch({
    required TransportKind activeTransportKind,
    required TransportKind desiredTransportKind,
  }) {
    if (activeTransportKind == desiredTransportKind) {
      return false;
    }
    if (!_isVpnTransport(desiredTransportKind)) {
      return false;
    }
    return true;
  }

  static int _defaultLanPortFor(VpnTunnelMode mode, int defaultLanPort) {
    return defaultLanPort;
  }

  static bool satisfiesDirectReadinessGate(VpnTunnelSnapshot snapshot) {
    final hasInboundUdp = (snapshot.udpPacketsIn ?? 0) > 0;
    final hasTunnelTraffic = (snapshot.tunPacketsIn ?? 0) > 0;
    final hasWireGuardRx = (snapshot.wgRxBytes ?? 0) > 0;
    return hasInboundUdp && (hasTunnelTraffic || hasWireGuardRx);
  }

  bool _isReadyForTransportSwitch({
    required VpnTunnelMode mode,
    required DateTime? connectedAt,
    required DateTime now,
    VpnTunnelSnapshot? snapshot,
  }) {
    final readySince = connectedAt;
    if (readySince == null || now.difference(readySince) < _directReadyWindow) {
      return false;
    }
    if (snapshot == null) {
      return false;
    }
    return satisfiesDirectReadinessGate(snapshot);
  }
}
