import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/transport_models.dart';
import 'package:voyager/src/services/vpn_transport_handoff.dart';

const _endpoint = VpnTransportEndpoint(
  serverIp: kVpnAppWebsocketHost,
  lanPort: kVpnAppWebsocketPort,
);

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
}) {
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

void main() {
  group('VpnTunnelSnapshot.fromJson', () {
    test('parses handshake fields that used to be dropped', () {
      final snapshot = VpnTunnelSnapshot.fromJson({
        'status': 'connected',
        'connectionMode': 'direct',
        'serverIp': kVpnAppWebsocketHost,
        'lanPort': kVpnAppWebsocketPort,
        'directSessionReady': true,
        'timeSinceLastHandshakeSecs': 4,
      });

      expect(snapshot.isConnected, isTrue);
      expect(snapshot.directSessionReady, isTrue);
      expect(snapshot.timeSinceLastHandshakeSecs, 4);
    });

    test('keeps missing handshake fields null', () {
      final snapshot = VpnTunnelSnapshot.fromJson({
        'status': 'connected',
        'udpPacketsIn': 9,
      });

      expect(snapshot.directSessionReady, isNull);
      expect(snapshot.timeSinceLastHandshakeSecs, isNull);
    });
  });

  group('VpnTransportHandoffCoordinator', () {
    test('restores endpoint from active vpn status using default port', () {
      final coordinator = VpnTransportHandoffCoordinator();

      final restored = coordinator.restoreEndpointFromNativeStatus(
        currentEndpoint: null,
        snapshot: const VpnTunnelSnapshot(
          isActive: true,
          isConnected: true,
          mode: VpnTunnelMode.direct,
          serverIp: kVpnAppWebsocketHost,
        ),
        defaultLanPort: kVpnAppWebsocketPort,
      );

      expect(restored, isNotNull);
      expect(restored?.serverIp, kVpnAppWebsocketHost);
      expect(restored?.lanPort, kVpnAppWebsocketPort);
    });

    test(
      'does not restore endpoint from stale unknown disconnected status',
      () {
        final coordinator = VpnTransportHandoffCoordinator();

        final restored = coordinator.restoreEndpointFromNativeStatus(
          currentEndpoint: null,
          snapshot: const VpnTunnelSnapshot(
            isActive: false,
            isConnected: false,
            mode: VpnTunnelMode.unknown,
            serverIp: kVpnAppWebsocketHost,
            lanPort: kVpnAppWebsocketPort,
            error: 'WireGuard handshake timed out',
          ),
          defaultLanPort: kVpnAppWebsocketPort,
        );

        expect(restored, isNull);
      },
    );

    test('switches in-tunnel WS as unknown after handshake dwell', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);

      coordinator.onVpnStatusChanged(
        snapshot: _snapshot(),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt,
      );

      final decision = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(timeSinceLastHandshakeSecs: 1),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 3)),
      );

      expect(decision.shouldSwitch, isTrue);
      expect(decision.transportKind, TransportKind.unknown);
      expect(
        decision.endpoint?.websocketUri.toString(),
        'ws://$kVpnAppWebsocketHost:$kVpnAppWebsocketPort/ws',
      );
    });

    test('arms pending switch until primary connection opens', () {
      final coordinator = VpnTransportHandoffCoordinator();

      final initial = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(timeSinceLastHandshakeSecs: 0),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.unknown,
        endpoint: _endpoint,
        now: DateTime.utc(2026, 1, 1, 0, 0, 0),
      );

      expect(initial.type, VpnTransportDecisionType.none);
      expect(coordinator.pendingSwitch, isTrue);

      final resumed = coordinator.onPrimaryConnectionOpened(
        vpnConnected: true,
        vpnMode: VpnTunnelMode.direct,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: DateTime.utc(2026, 1, 1, 0, 0, 3),
      );

      expect(resumed.shouldSwitch, isTrue);
      expect(resumed.transportKind, TransportKind.unknown);
    });

    test('falls back when vpn disconnects after being connected', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);

      coordinator.onVpnStatusChanged(
        snapshot: _snapshot(timeSinceLastHandshakeSecs: 1),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt,
      );

      final disconnected = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(isActive: false, isConnected: false),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.wireguardDirect,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 10)),
      );

      expect(disconnected.shouldFallback, isFalse);

      final afterGrace = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(isActive: false, isConnected: false),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.wireguardDirect,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 15)),
      );

      expect(afterGrace.shouldFallback, isTrue);
    });

    test('direct handoff waits for handshake fields before switching', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);

      final initial = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(udpPacketsIn: 4, tunPacketsIn: 2, wgRxBytes: 256),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt,
      );

      expect(initial.type, VpnTransportDecisionType.none);
      expect(coordinator.pendingSwitch, isTrue);

      final stillPending = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(udpPacketsIn: 4, tunPacketsIn: 2, wgRxBytes: 256),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 3)),
      );
      expect(stillPending.type, VpnTransportDecisionType.none);
      expect(coordinator.pendingSwitch, isTrue);

      final ready = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(directSessionReady: true),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 3)),
      );

      expect(ready.shouldSwitch, isTrue);
      expect(ready.transportKind, TransportKind.unknown);
    });

    test('udpPacketsIn alone does not satisfy the readiness gate', () {
      expect(
        VpnTransportHandoffCoordinator.satisfiesDirectReadinessGate(
          _snapshot(udpPacketsIn: 4, tunPacketsIn: 0, wgRxBytes: 2048),
          endpoint: _endpoint,
        ),
        isFalse,
      );
    });

    test('missing handshake fields fail the gate closed', () {
      expect(
        VpnTransportHandoffCoordinator.satisfiesDirectReadinessGate(
          _snapshot(),
          endpoint: _endpoint,
        ),
        isFalse,
      );
    });

    test('timeSinceLastHandshakeSecs >= 0 satisfies the gate', () {
      expect(
        VpnTransportHandoffCoordinator.satisfiesDirectReadinessGate(
          _snapshot(timeSinceLastHandshakeSecs: 0),
          endpoint: _endpoint,
        ),
        isTrue,
      );
    });

    test('directSessionReady true satisfies the gate', () {
      expect(
        VpnTransportHandoffCoordinator.satisfiesDirectReadinessGate(
          _snapshot(directSessionReady: true),
          endpoint: _endpoint,
        ),
        isTrue,
      );
    });

    test('non-10.13.37.1 endpoint fails the gate closed', () {
      expect(
        VpnTransportHandoffCoordinator.satisfiesDirectReadinessGate(
          _snapshot(directSessionReady: true, timeSinceLastHandshakeSecs: 1),
          endpoint: const VpnTransportEndpoint(
            serverIp: '192.168.1.20',
            lanPort: kVpnAppWebsocketPort,
          ),
        ),
        isFalse,
      );
    });

    test('disconnected native status fails the gate closed', () {
      expect(
        VpnTransportHandoffCoordinator.satisfiesDirectReadinessGate(
          _snapshot(
            isConnected: false,
            directSessionReady: true,
            timeSinceLastHandshakeSecs: 1,
          ),
          endpoint: _endpoint,
        ),
        isFalse,
      );
    });

    test('recent vpn switch suppresses immediate fallback flap', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);

      coordinator.onVpnStatusChanged(
        snapshot: _snapshot(),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt,
      );

      final switched = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(timeSinceLastHandshakeSecs: 1),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 3)),
      );
      expect(switched.shouldSwitch, isTrue);

      final disconnectObserved = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(isActive: false, isConnected: false),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.wireguardDirect,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 8)),
      );
      expect(disconnectObserved.shouldFallback, isFalse);

      final stillSuppressed = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(isActive: false, isConnected: false),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.wireguardDirect,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 10)),
      );
      expect(stillSuppressed.shouldFallback, isFalse);

      final unsuppressed = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(isActive: false, isConnected: false),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.wireguardDirect,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 13)),
      );
      expect(unsuppressed.shouldFallback, isTrue);
    });

    test(
      're-arms switch after VPN briefly errors and recovers within grace window',
      () {
        final coordinator = VpnTransportHandoffCoordinator(
          fallbackSuppressionWindow: const Duration(seconds: 8),
        );
        final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);
        final readySnapshot = _snapshot(
          tunPacketsIn: 1,
          udpPacketsIn: 5,
          wgRxBytes: 128,
          directSessionReady: true,
        );

        coordinator.onVpnStatusChanged(
          snapshot: _snapshot(),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: _endpoint,
          now: connectedAt,
        );
        expect(coordinator.pendingSwitch, isTrue);

        final switched = coordinator.onVpnStatusChanged(
          snapshot: readySnapshot,
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: _endpoint,
          now: connectedAt.add(const Duration(seconds: 3)),
        );
        expect(switched.shouldSwitch, isTrue);
        expect(coordinator.pendingSwitch, isFalse);

        final errored = coordinator.onVpnStatusChanged(
          snapshot: _snapshot(
            isActive: false,
            isConnected: false,
            error: 'WireGuard handshake timed out',
          ),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: _endpoint,
          now: connectedAt.add(const Duration(seconds: 5)),
        );
        expect(errored.shouldFallback, isFalse);
        expect(errored.shouldSwitch, isFalse);

        final recovered = coordinator.onVpnStatusChanged(
          snapshot: readySnapshot,
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: _endpoint,
          now: connectedAt.add(const Duration(seconds: 6)),
        );
        expect(recovered.shouldSwitch, isFalse, reason: 'within cooldown');

        final rearmed = coordinator.onVpnStatusChanged(
          snapshot: readySnapshot,
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: _endpoint,
          now: connectedAt.add(const Duration(seconds: 12)),
        );
        expect(rearmed.shouldSwitch, isTrue);
        expect(rearmed.transportKind, TransportKind.unknown);
        expect(rearmed.reason, 'vpn_rearm_after_stale_switch');
      },
    );

    test(
      're-arm does not fire when transport already switched to wireguardDirect',
      () {
        final coordinator = VpnTransportHandoffCoordinator();
        final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);

        coordinator.onVpnStatusChanged(
          snapshot: _snapshot(),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: _endpoint,
          now: connectedAt,
        );

        final switched = coordinator.onVpnStatusChanged(
          snapshot: _snapshot(timeSinceLastHandshakeSecs: 1),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: _endpoint,
          now: connectedAt.add(const Duration(seconds: 3)),
        );
        expect(switched.shouldSwitch, isTrue);

        final stable = coordinator.onVpnStatusChanged(
          snapshot: _snapshot(timeSinceLastHandshakeSecs: 5),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wireguardDirect,
          endpoint: _endpoint,
          now: connectedAt.add(const Duration(seconds: 20)),
        );
        expect(stable.shouldSwitch, isFalse);
      },
    );

    test('native status=error does not switch to Direct', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final snapshot = VpnTunnelSnapshot.fromJson({
        'status': 'error',
        'connectionMode': 'direct',
        'serverIp': kVpnAppWebsocketHost,
        'lanPort': kVpnAppWebsocketPort,
        'error': 'WireGuard handshake timed out',
      });

      expect(snapshot.isConnected, isFalse);
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
    });

    test('does not reconnect an in-tunnel unknown socket as Direct', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);

      coordinator.onVpnStatusChanged(
        snapshot: _snapshot(),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt,
      );
      coordinator.onVpnStatusChanged(
        snapshot: _snapshot(directSessionReady: true),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 3)),
      );

      final alreadyOnTunnel = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(directSessionReady: true),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.unknown,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 20)),
      );
      expect(alreadyOnTunnel.shouldSwitch, isFalse);
    });
  });

  group('host_info vpnPeer handling', () {
    test('marks Direct only on 10.13.37.1 when vpnPeer is true', () {
      expect(
        VpnTransportHandoffCoordinator.hostInfoAction(
          socketHost: kVpnAppWebsocketHost,
          vpnPeer: true,
        ),
        VpnHostInfoAction.markDirect,
      );
    });

    test('falls back when 10.13.37.1 socket is ready without vpnPeer', () {
      expect(
        VpnTransportHandoffCoordinator.hostInfoAction(
          socketHost: kVpnAppWebsocketHost,
          vpnPeer: false,
        ),
        VpnHostInfoAction.fallback,
      );
      expect(
        VpnTransportHandoffCoordinator.hostInfoAction(
          socketHost: kVpnAppWebsocketHost,
          vpnPeer: null,
        ),
        VpnHostInfoAction.fallback,
      );
    });

    test('ignores control-plane host_info even if vpnPeer is set', () {
      expect(
        VpnTransportHandoffCoordinator.hostInfoAction(
          socketHost: 'wormhole.blackhole-ai.com',
          vpnPeer: true,
        ),
        VpnHostInfoAction.ignore,
      );
      expect(
        VpnTransportHandoffCoordinator.hostInfoAction(
          socketHost: '192.168.1.20',
          vpnPeer: false,
        ),
        VpnHostInfoAction.ignore,
      );
    });
  });

  group('StayOnWs', () {
    test('is true on control-plane sockets before handoff', () {
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

    test('is false while handoff is pending or already Direct', () {
      expect(
        VpnTransportHandoffCoordinator.isStayOnWs(
          handoffPending: true,
          activeKind: TransportKind.unknown,
          socketHost: kVpnAppWebsocketHost,
          connected: true,
        ),
        isFalse,
      );
      expect(
        VpnTransportHandoffCoordinator.isStayOnWs(
          handoffPending: false,
          activeKind: TransportKind.wireguardDirect,
          socketHost: kVpnAppWebsocketHost,
          connected: true,
        ),
        isFalse,
      );
      expect(
        VpnTransportHandoffCoordinator.isStayOnWs(
          handoffPending: false,
          activeKind: TransportKind.unknown,
          socketHost: kVpnAppWebsocketHost,
          connected: true,
        ),
        isFalse,
      );
    });

    test(
      'stale 10.13.37.1 lastUri after silent disconnect is still StayOnWs',
      () {
        expect(
          VpnTransportHandoffCoordinator.isStayOnWs(
            handoffPending: false,
            activeKind: TransportKind.unknown,
            socketHost: kVpnAppWebsocketHost,
            connected: false,
          ),
          isTrue,
        );
      },
    );
  });

  group('vpnPeer false punch retry', () {
    test('in-tunnel not-peer fallback keeps punch identity', () {
      expect(
        VpnTransportHandoffCoordinator.keepPunchIdentity(
          VpnFallbackReason.inTunnelNotPeer,
        ),
        isTrue,
      );
      expect(
        VpnTransportHandoffCoordinator.keepPunchIdentity(
          VpnFallbackReason.vpnDisconnected,
        ),
        isFalse,
      );
    });

    test('punch retry interval is 30s', () {
      expect(kVpnPunchRetryInterval, const Duration(seconds: 30));
    });

    test(
      'timer sends peer_endpoint and only then clears switch suppression',
      () {
        final blocked = VpnTransportHandoffCoordinator.onPunchRetryTimer(
          stayOnWs: false,
          connected: false,
          publicKey: 'pk',
        );
        expect(blocked.action, VpnPunchRetryAction.none);
        expect(blocked.clearSwitchSuppression, isFalse);

        final send = VpnTransportHandoffCoordinator.onPunchRetryTimer(
          stayOnWs: true,
          connected: true,
          publicKey: 'pk',
        );
        expect(send.action, VpnPunchRetryAction.sendPeerEndpoint);
        expect(send.clearSwitchSuppression, isTrue);
        expect(send.rearm, isTrue);

        final noKey = VpnTransportHandoffCoordinator.onPunchRetryTimer(
          stayOnWs: true,
          connected: true,
          publicKey: null,
        );
        expect(noKey.action, VpnPunchRetryAction.startUpgrade);
        expect(noKey.clearSwitchSuppression, isFalse);
      },
    );

    test('switch stays suppressed until punch retry clears it', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);
      coordinator.onVpnStatusChanged(
        snapshot: _snapshot(),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt,
      );
      final switched = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(directSessionReady: true),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 3)),
      );
      expect(switched.shouldSwitch, isTrue);

      coordinator.suppressSwitch();
      expect(coordinator.switchSuppressed, isTrue);

      final stillSuppressed = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(directSessionReady: true),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 20)),
      );
      expect(stillSuppressed.shouldSwitch, isFalse);
      expect(coordinator.switchSuppressed, isTrue);

      coordinator.clearSwitchSuppression();
      expect(coordinator.switchSuppressed, isFalse);

      final retry = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(directSessionReady: true),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: _endpoint,
        now: connectedAt.add(const Duration(seconds: 21)),
      );
      expect(retry.shouldSwitch, isTrue);
      expect(retry.transportKind, TransportKind.unknown);
    });
  });

  group('relay removal safety', () {
    test('relay mode maps to unknown transport kind, not vpn transport', () {
      expect(
        VpnTransportHandoffCoordinator.transportKindForMode(
          VpnTunnelMode.relay,
        ),
        TransportKind.unknown,
      );
    });

    test(
      'relay vpn mode does not trigger transport switch from wormhole relay',
      () {
        final coordinator = VpnTransportHandoffCoordinator();

        final decision = coordinator.onVpnStatusChanged(
          snapshot: _snapshot(
            mode: VpnTunnelMode.relay,
            tunPacketsIn: 1,
            udpPacketsIn: 1,
            directSessionReady: true,
          ),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: _endpoint,
        );

        expect(decision.type, VpnTransportDecisionType.none);
      },
    );

    test('relay mode does not trigger downgrade from wireguard direct', () {
      final coordinator = VpnTransportHandoffCoordinator();

      final decision = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(
          mode: VpnTunnelMode.relay,
          tunPacketsIn: 1,
          udpPacketsIn: 1,
          directSessionReady: true,
        ),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wireguardDirect,
        endpoint: _endpoint,
      );

      expect(decision.type, VpnTransportDecisionType.none);
    });

    test(
      'unknown transport kind as active does not crash or trigger switch',
      () {
        final coordinator = VpnTransportHandoffCoordinator();

        final decision = coordinator.onVpnStatusChanged(
          snapshot: _snapshot(
            tunPacketsIn: 1,
            udpPacketsIn: 1,
            wgRxBytes: 128,
            timeSinceLastHandshakeSecs: 1,
          ),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.unknown,
          endpoint: _endpoint,
          now: DateTime.utc(2026, 1, 1, 0, 0, 0),
        );

        expect(decision.type, VpnTransportDecisionType.none);
      },
    );

    test('transportKindForMode returns unknown for unknown vpn mode', () {
      expect(
        VpnTransportHandoffCoordinator.transportKindForMode(
          VpnTunnelMode.unknown,
        ),
        TransportKind.unknown,
      );
    });

    test('punch timeout: wormholeRelay stays active when already Direct', () {
      final coordinator = VpnTransportHandoffCoordinator();

      final decision = coordinator.onVpnStatusChanged(
        snapshot: _snapshot(
          mode: VpnTunnelMode.unknown,
          tunPacketsIn: 1,
          udpPacketsIn: 1,
          wgRxBytes: 128,
          timeSinceLastHandshakeSecs: 1,
        ),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wireguardDirect,
        endpoint: _endpoint,
        now: DateTime.utc(2026, 1, 1, 0, 0, 0),
      );

      expect(decision.type, VpnTransportDecisionType.none);
    });

    test(
      'wireguard_relay wire name deserializes to unknown after enum removal',
      () {
        expect(
          TransportKind.fromWireName('wireguard_relay'),
          TransportKind.unknown,
        );
      },
    );
  });
}
