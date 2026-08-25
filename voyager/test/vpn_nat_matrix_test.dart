import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/transport_models.dart';
import 'package:voyager/src/services/vpn_netcheck_config.dart';
import 'package:voyager/src/services/vpn_transport_handoff.dart';
import 'package:voyager/src/services/wg_app_flow_validator.dart';

const _endpoint = VpnTransportEndpoint(
  serverIp: kVpnAppWebsocketHost,
  lanPort: kVpnAppWebsocketPort,
);

const _inTunnelUri = 'ws://$kVpnAppWebsocketHost:$kVpnAppWebsocketPort/ws';

VpnTunnelSnapshot _snapshot({
  bool isActive = true,
  bool isConnected = true,
  VpnTunnelMode mode = VpnTunnelMode.direct,
  int? tunPacketsIn,
  int? udpPacketsIn,
  int? wgRxBytes,
  bool? directSessionReady,
  int? timeSinceLastHandshakeSecs,
  String? error,
  String? status,
}) {
  if (status != null) {
    return VpnTunnelSnapshot.fromJson(<String, dynamic>{
      'status': status,
      'connectionMode': mode.name,
      'serverIp': kVpnAppWebsocketHost,
      'lanPort': kVpnAppWebsocketPort,
      if (tunPacketsIn != null) 'tunPacketsIn': tunPacketsIn,
      if (udpPacketsIn != null) 'udpPacketsIn': udpPacketsIn,
      if (wgRxBytes != null) 'wgRxBytes': wgRxBytes,
      if (directSessionReady != null) 'directSessionReady': directSessionReady,
      if (timeSinceLastHandshakeSecs != null)
        'timeSinceLastHandshakeSecs': timeSinceLastHandshakeSecs,
      if (error != null) 'error': error,
    });
  }
  return VpnTunnelSnapshot(
    isActive: isActive,
    isConnected: isConnected,
    mode: mode,
    serverIp: kVpnAppWebsocketHost,
    lanPort: kVpnAppWebsocketPort,
    tunPacketsIn: tunPacketsIn,
    udpPacketsIn: udpPacketsIn,
    wgRxBytes: wgRxBytes,
    directSessionReady: directSessionReady,
    timeSinceLastHandshakeSecs: timeSinceLastHandshakeSecs,
    error: error,
  );
}

VpnTransportDecision _switchAfterHandshake(
  VpnTransportHandoffCoordinator coordinator, {
  required DateTime connectedAt,
}) {
  coordinator.onVpnStatusChanged(
    snapshot: _snapshot(),
    primaryConnectionConnected: true,
    activeTransportKind: TransportKind.wormholeRelay,
    endpoint: _endpoint,
    now: connectedAt,
  );
  return coordinator.onVpnStatusChanged(
    snapshot: _snapshot(
      timeSinceLastHandshakeSecs: 0,
      directSessionReady: true,
    ),
    primaryConnectionConnected: true,
    activeTransportKind: TransportKind.wormholeRelay,
    endpoint: _endpoint,
    now: connectedAt.add(const Duration(seconds: 3)),
  );
}

void main() {
  group('LAN', () {
    test('direct handoff opens app WS on 10.13.37.1 as unknown', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final decision = _switchAfterHandshake(
        coordinator,
        connectedAt: DateTime.utc(2026, 1, 1),
      );

      expect(decision.shouldSwitch, isTrue);
      expect(decision.transportKind, TransportKind.unknown);
      expect(decision.endpoint?.serverIp, kVpnAppWebsocketHost);
      expect(decision.endpoint?.websocketUri.host, kVpnAppWebsocketHost);
      expect(decision.endpoint?.websocketUri.toString(), _inTunnelUri);
    });

    test('host_info vpnPeer true is the in-tunnel accept signal', () {
      expect(
        VpnTransportHandoffCoordinator.hostInfoAction(
          socketHost: kVpnAppWebsocketHost,
          vpnPeer: true,
        ),
        VpnHostInfoAction.markDirect,
      );
    });
  });

  group('WAN cone', () {
    test('Voyager never uses port 443 for STUN/netcheck', () {
      final advertised443 = deriveVpnNetcheckConfig(
        signalingHost: 'wormhole.blackhole-ai.com',
        signalingPort: 443,
        wormholeUrl: 'wss://wormhole.blackhole-ai.com:443/ws',
      );
      expect(advertised443.$1, 'wormhole.blackhole-ai.com');
      expect(advertised443.$2, 6666);
      expect(advertised443.$2, isNot(443));
      expect(usableVpnNetcheckPort(443), 6666);
    });

    test('connected is handshake-gated, not inferred from UDP counters', () {
      expect(
        VpnTransportHandoffCoordinator.satisfiesDirectReadinessGate(
          _snapshot(udpPacketsIn: 9, tunPacketsIn: 3, wgRxBytes: 2048),
          endpoint: _endpoint,
        ),
        isFalse,
      );
      expect(
        VpnTransportHandoffCoordinator.satisfiesDirectReadinessGate(
          _snapshot(timeSinceLastHandshakeSecs: 0),
          endpoint: _endpoint,
        ),
        isTrue,
      );
    });
  });

  group('Symmetric NAT', () {
    test('native status=error stays on WS and never marks Direct', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final snapshot = _snapshot(
        status: 'error',
        isActive: false,
        isConnected: false,
        error: 'WireGuard handshake timed out',
      );

      expect(snapshot.isConnected, isFalse);
      expect(snapshot.isActive, isFalse);
      expect(snapshot.error, 'WireGuard handshake timed out');
      expect(
        VpnTransportHandoffCoordinator.satisfiesDirectReadinessGate(
          snapshot,
          endpoint: _endpoint,
        ),
        isFalse,
      );

      final decision = coordinator.onVpnStatusChanged(
        snapshot: snapshot,
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: DateTime.utc(2026, 1, 1),
      );
      expect(decision.shouldSwitch, isFalse);
      expect(decision.transportKind, isNot(TransportKind.wireguardDirect));
      expect(
        VpnTransportHandoffCoordinator.hostInfoAction(
          socketHost: 'wormhole.blackhole-ai.com',
          vpnPeer: true,
        ),
        VpnHostInfoAction.ignore,
      );
      expect(
        VpnTransportHandoffCoordinator.isStayOnWs(
          handoffPending: false,
          activeKind: TransportKind.wormholeRelay,
          socketHost: 'wormhole.blackhole-ai.com',
          connected: true,
        ),
        isTrue,
      );
    });
  });

  group('Reconnect', () {
    test(
      'vpnPeer=false on 10.13.37.1 falls back, keeps punch, then 30s retry sends peer_endpoint',
      () {
        expect(kVpnPunchRetryInterval, const Duration(seconds: 30));
        expect(
          VpnTransportHandoffCoordinator.hostInfoAction(
            socketHost: kVpnAppWebsocketHost,
            vpnPeer: false,
          ),
          VpnHostInfoAction.fallback,
        );
        expect(
          VpnTransportHandoffCoordinator.keepPunchIdentity(
            VpnFallbackReason.inTunnelNotPeer,
          ),
          isTrue,
        );

        final retry = VpnTransportHandoffCoordinator.onPunchRetryTimer(
          stayOnWs: true,
          connected: true,
          publicKey: 'pk',
        );
        expect(retry.action, VpnPunchRetryAction.sendPeerEndpoint);
        expect(retry.clearSwitchSuppression, isTrue);
        expect(retry.rearm, isTrue);
      },
    );
  });

  group('Replay/validator', () {
    test('successful run asserts URI host 10.13.37.1 and vpnPeer=true', () {
      const horizonLog = '''
2026-03-22T00:00:00Z INFO horizon_daemon::wg_server: added WireGuard peer peer_public_key="peer-key-1" client_ip=10.13.37.7
2026-03-22T00:00:00Z INFO horizon_daemon: vpn_config sent: client_ip=10.13.37.7 server_ip=10.13.37.1 wg_port=Some(51820)
2026-03-22T00:00:00Z INFO horizon_daemon::wg_server: sent direct handshake probe to candidate peer=192.168.1.219:51820 peer_public_key="peer-key-1"
2026-03-22T00:00:03Z INFO horizon_daemon::wg_server: accepted direct WireGuard traffic; ending direct probe window peer_public_key="peer-key-1" peer=192.168.1.219:51820
2026-03-22T00:00:04Z INFO horizon_daemon: websocket accepted remote_addr=10.13.37.7:54012 vpn_peer=true
2026-03-22T00:00:04Z INFO horizon_daemon: initial session bootstrap sent on websocket remote_addr=10.13.37.7:54012 vpn_peer=true
2026-03-22T00:00:05Z INFO horizon_daemon: received terminal stdin over websocket remote_addr=10.13.37.7:54012 session_id=ABC123 payload_len=5
2026-03-22T00:00:05Z INFO horizon_daemon: sent terminal stdout over websocket remote_addr=10.13.37.7:54012 session_id=ABC123 payload_len=7
''';

      final result = WgAppFlowValidator.validate(
        horizonLog: horizonLog,
        vpnStatusJson: <String, dynamic>{
          'status': 'connected',
          'connectionMode': 'direct',
          'clientIp': '10.13.37.7',
          'serverIp': kVpnAppWebsocketHost,
          'lanPort': kVpnAppWebsocketPort,
          'directSessionReady': true,
          'timeSinceLastHandshakeSecs': 2,
        },
      );

      expect(result.isSuccess, isTrue);
      expect(result.appWebsocketHostSatisfied, isTrue);
      expect(result.appWebsocketUri, _inTunnelUri);
      expect(result.vpnPeerTrue, isTrue);
      expect(result.vpnWebsocketAccepted, isTrue);
    });
  });
}
