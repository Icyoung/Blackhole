import 'dart:convert';

import 'vpn_transport_handoff.dart';

class WgAppFlowValidationResult {
  const WgAppFlowValidationResult({
    required this.clientIp,
    required this.peerPublicKey,
    required this.directAcceptedPeer,
    required this.vpnStatusConnectedDirect,
    required this.directSessionReady,
    required this.directReadinessGateSatisfied,
    required this.addedPeer,
    required this.vpnConfigSent,
    required this.directProbeObserved,
    required this.vpnWebsocketAccepted,
    required this.vpnWebsocketBootstrap,
    required this.vpnTerminalStdinObserved,
    required this.vpnTerminalStdoutObserved,
    required this.failures,
    required this.warnings,
  });

  final String? clientIp;
  final String? peerPublicKey;
  final String? directAcceptedPeer;
  final bool vpnStatusConnectedDirect;
  final bool directSessionReady;
  final bool directReadinessGateSatisfied;
  final bool addedPeer;
  final bool vpnConfigSent;
  final bool directProbeObserved;
  final bool vpnWebsocketAccepted;
  final bool vpnWebsocketBootstrap;
  final bool vpnTerminalStdinObserved;
  final bool vpnTerminalStdoutObserved;
  final List<String> failures;
  final List<String> warnings;

  bool get isSuccess => failures.isEmpty;

  Map<String, dynamic> toJson() {
    return <String, dynamic>{
      'clientIp': clientIp,
      'peerPublicKey': peerPublicKey,
      'directAcceptedPeer': directAcceptedPeer,
      'vpnStatusConnectedDirect': vpnStatusConnectedDirect,
      'directSessionReady': directSessionReady,
      'directReadinessGateSatisfied': directReadinessGateSatisfied,
      'addedPeer': addedPeer,
      'vpnConfigSent': vpnConfigSent,
      'directProbeObserved': directProbeObserved,
      'vpnWebsocketAccepted': vpnWebsocketAccepted,
      'vpnWebsocketBootstrap': vpnWebsocketBootstrap,
      'vpnTerminalStdinObserved': vpnTerminalStdinObserved,
      'vpnTerminalStdoutObserved': vpnTerminalStdoutObserved,
      'failures': failures,
      'warnings': warnings,
    };
  }
}

class WgAppFlowValidator {
  static final RegExp _ansiPattern = RegExp(r'\x1B\[[0-9;]*[A-Za-z]');
  static final RegExp _peerKeyPattern = RegExp(
    r'peer_public_key="?([^"\s]+)"?',
  );
  static final RegExp _remoteAddrPattern = RegExp(r'remote_addr=([0-9.]+):\d+');
  static final RegExp _acceptedPeerPattern = RegExp(r'peer=([0-9.]+:\d+)');

  static WgAppFlowValidationResult validate({
    required String horizonLog,
    required Map<String, dynamic> vpnStatusJson,
    String? clientIpOverride,
  }) {
    final normalizedVpnStatus = Map<String, dynamic>.from(vpnStatusJson);
    normalizedVpnStatus['mode'] ??= normalizedVpnStatus['connectionMode'];
    final snapshot = VpnTunnelSnapshot.fromJson(normalizedVpnStatus);
    final clientIp = clientIpOverride ?? snapshot.clientIp;
    final lines = const LineSplitter().convert(_stripAnsi(horizonLog));
    final status = vpnStatusJson['status'] as String?;
    final connectionMode = vpnStatusJson['connectionMode'] as String?;
    final directSessionReady =
        vpnStatusJson['directSessionReady'] as bool? ?? false;
    final endpoint = VpnTransportEndpoint(
      serverIp: snapshot.serverIp ?? '',
      lanPort: snapshot.lanPort ?? kVpnAppWebsocketPort,
    );
    final directReadinessGateSatisfied =
        VpnTransportHandoffCoordinator.satisfiesDirectReadinessGate(
          snapshot,
          endpoint: endpoint,
        );
    final vpnStatusConnectedDirect =
        status == 'connected' && connectionMode == 'direct';

    String? peerPublicKey;
    String? directAcceptedPeer;
    var addedPeer = false;
    var vpnConfigSent = false;
    var directProbeObserved = false;
    var vpnWebsocketAccepted = false;
    var vpnWebsocketBootstrap = false;
    var vpnTerminalStdinObserved = false;
    var vpnTerminalStdoutObserved = false;
    int? directAcceptedLine;

    for (var i = 0; i < lines.length; i += 1) {
      final line = lines[i];

      if (clientIp != null) {
        if (line.contains('added WireGuard peer') &&
            line.contains('client_ip=$clientIp')) {
          addedPeer = true;
          peerPublicKey = _matchFirst(line, _peerKeyPattern) ?? peerPublicKey;
        }
        if (line.contains('vpn_config sent:') &&
            line.contains('client_ip=$clientIp')) {
          vpnConfigSent = true;
        }
        if (line.contains('websocket accepted') &&
            line.contains('vpn_peer=true') &&
            _matchRemoteIp(line) == clientIp) {
          vpnWebsocketAccepted = true;
        }
        if (line.contains('initial session bootstrap sent on websocket') &&
            line.contains('vpn_peer=true') &&
            _matchRemoteIp(line) == clientIp) {
          vpnWebsocketBootstrap = true;
        }
        if (line.contains('received terminal stdin over websocket') &&
            _matchRemoteIp(line) == clientIp) {
          vpnTerminalStdinObserved = true;
        }
        if (line.contains('sent terminal stdout over websocket') &&
            _matchRemoteIp(line) == clientIp) {
          vpnTerminalStdoutObserved = true;
        }
      }

      final currentPeerKey = peerPublicKey;
      if (currentPeerKey != null &&
          line.contains(currentPeerKey) &&
          line.contains('sent direct handshake probe to candidate')) {
        directProbeObserved = true;
      }
      if (currentPeerKey != null &&
          line.contains(currentPeerKey) &&
          line.contains(
            'accepted direct WireGuard traffic; ending direct probe window',
          )) {
        directAcceptedLine = i;
        directAcceptedPeer = _matchFirst(line, _acceptedPeerPattern);
      }
    }

    final failures = <String>[];
    final warnings = <String>[];

    if (clientIp == null || clientIp.isEmpty) {
      failures.add('missing clientIp in vpn_status.json');
    }
    if (snapshot.serverIp != kVpnAppWebsocketHost) {
      failures.add(
        'vpn_status serverIp must be $kVpnAppWebsocketHost for in-tunnel app WS',
      );
    }
    if (!vpnStatusConnectedDirect) {
      failures.add(
        'vpn_status does not show status=connected and connectionMode=direct',
      );
    }
    if (!directSessionReady) {
      failures.add('vpn_status does not show directSessionReady=true');
    }
    if (!directReadinessGateSatisfied) {
      failures.add(
        'direct readiness gate is not satisfied: need host $kVpnAppWebsocketHost, native connected, and handshake (timeSinceLastHandshakeSecs>=0 or directSessionReady)',
      );
    }
    if (!addedPeer) {
      failures.add(
        'Horizon log is missing added WireGuard peer for the client IP',
      );
    }
    if (!vpnConfigSent) {
      failures.add('Horizon log is missing vpn_config sent for the client IP');
    }
    if (!directProbeObserved) {
      failures.add('Horizon log is missing a direct probe for the client peer');
    }
    if (directAcceptedLine == null) {
      failures.add(
        'Horizon log is missing accepted direct WireGuard traffic for the client peer',
      );
    }
    if (!vpnWebsocketAccepted) {
      failures.add(
        'Horizon log is missing a vpn_peer websocket accepted event for the client IP',
      );
    }
    if (!vpnWebsocketBootstrap) {
      failures.add(
        'Horizon log is missing initial session bootstrap on the vpn websocket',
      );
    }
    if (!vpnTerminalStdinObserved) {
      failures.add(
        'Horizon log is missing terminal stdin over the vpn websocket',
      );
    }
    if (!vpnTerminalStdoutObserved) {
      failures.add(
        'Horizon log is missing terminal stdout over the vpn websocket',
      );
    }
    return WgAppFlowValidationResult(
      clientIp: clientIp,
      peerPublicKey: peerPublicKey,
      directAcceptedPeer: directAcceptedPeer,
      vpnStatusConnectedDirect: vpnStatusConnectedDirect,
      directSessionReady: directSessionReady,
      directReadinessGateSatisfied: directReadinessGateSatisfied,
      addedPeer: addedPeer,
      vpnConfigSent: vpnConfigSent,
      directProbeObserved: directProbeObserved,
      vpnWebsocketAccepted: vpnWebsocketAccepted,
      vpnWebsocketBootstrap: vpnWebsocketBootstrap,
      vpnTerminalStdinObserved: vpnTerminalStdinObserved,
      vpnTerminalStdoutObserved: vpnTerminalStdoutObserved,
      failures: List<String>.unmodifiable(failures),
      warnings: List<String>.unmodifiable(warnings),
    );
  }

  static String _stripAnsi(String text) => text.replaceAll(_ansiPattern, '');

  static String? _matchFirst(String text, RegExp pattern) {
    final match = pattern.firstMatch(text);
    return match?.group(1);
  }

  static String? _matchRemoteIp(String line) {
    return _matchFirst(line, _remoteAddrPattern);
  }
}
