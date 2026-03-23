import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/transport_models.dart';
import 'package:voyager/src/services/vpn_transport_handoff.dart';

void main() {
  group('VpnTransportHandoffCoordinator', () {
    test('restores endpoint from active vpn status using default port', () {
      final coordinator = VpnTransportHandoffCoordinator();

      final restored = coordinator.restoreEndpointFromNativeStatus(
        currentEndpoint: null,
        snapshot: const VpnTunnelSnapshot(
          isActive: true,
          isConnected: true,
          mode: VpnTunnelMode.direct,
          serverIp: '10.13.37.1',
        ),
        defaultLanPort: 9527,
      );

      expect(restored, isNotNull);
      expect(restored?.serverIp, '10.13.37.1');
      expect(restored?.lanPort, 9527);
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
            serverIp: '10.13.37.1',
            lanPort: 9529,
            error: 'WireGuard handshake timed out',
          ),
          defaultLanPort: 9527,
        );

        expect(restored, isNull);
      },
    );

    test('switches transport when vpn direct becomes connected on wormhole',
        () {
      final coordinator = VpnTransportHandoffCoordinator();
      final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);

      // First status: connected but not ready (no traffic yet).
      coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: true,
          isConnected: true,
          mode: VpnTunnelMode.direct,
          serverIp: '10.13.37.1',
          lanPort: 9529,
          tunPacketsIn: 0,
          udpPacketsIn: 0,
          wgRxBytes: 0,
        ),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: const VpnTransportEndpoint(
          serverIp: '10.13.37.1',
          lanPort: 9529,
        ),
        now: connectedAt,
      );

      // Second status: traffic flowing, readiness gate satisfied.
      final decision = coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: true,
          isConnected: true,
          mode: VpnTunnelMode.direct,
          serverIp: '10.13.37.1',
          lanPort: 9529,
          tunPacketsIn: 1,
          udpPacketsIn: 1,
          wgRxBytes: 128,
        ),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: const VpnTransportEndpoint(
          serverIp: '10.13.37.1',
          lanPort: 9529,
        ),
        now: connectedAt.add(const Duration(seconds: 3)),
      );

      expect(decision.shouldSwitch, isTrue);
      expect(decision.transportKind, TransportKind.wireguardDirect);
    });

    test('arms pending switch until primary connection opens', () {
      final coordinator = VpnTransportHandoffCoordinator();

      final initial = coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: true,
          isConnected: true,
          mode: VpnTunnelMode.direct,
          serverIp: '10.13.37.1',
          lanPort: 9529,
          udpPacketsIn: 1,
          wgRxBytes: 128,
        ),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.unknown,
        endpoint: const VpnTransportEndpoint(
          serverIp: '10.13.37.1',
          lanPort: 9529,
        ),
        now: DateTime.utc(2026, 1, 1, 0, 0, 0),
      );

      expect(initial.type, VpnTransportDecisionType.none);
      expect(coordinator.pendingSwitch, isTrue);

      final resumed = coordinator.onPrimaryConnectionOpened(
        vpnConnected: true,
        vpnMode: VpnTunnelMode.direct,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: const VpnTransportEndpoint(
          serverIp: '10.13.37.1',
          lanPort: 9529,
        ),
        now: DateTime.utc(2026, 1, 1, 0, 0, 3),
      );

      expect(resumed.shouldSwitch, isTrue);
      expect(resumed.transportKind, TransportKind.wireguardDirect);
    });

    test('falls back when vpn disconnects after being connected', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);

      // Connect with direct mode.
      coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: true,
          isConnected: true,
          mode: VpnTunnelMode.direct,
          serverIp: '10.13.37.1',
          lanPort: 9529,
          tunPacketsIn: 1,
          udpPacketsIn: 1,
          wgRxBytes: 128,
        ),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: const VpnTransportEndpoint(
          serverIp: '10.13.37.1',
          lanPort: 9529,
        ),
        now: connectedAt,
      );

      // Disconnect observed — within grace window, no fallback yet.
      final disconnected = coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: false,
          isConnected: false,
          mode: VpnTunnelMode.direct,
          serverIp: '10.13.37.1',
          lanPort: 9529,
        ),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.wireguardDirect,
        endpoint: const VpnTransportEndpoint(
          serverIp: '10.13.37.1',
          lanPort: 9529,
        ),
        now: connectedAt.add(const Duration(seconds: 10)),
      );

      expect(disconnected.shouldFallback, isFalse);

      // After grace window — fallback to primary.
      final afterGrace = coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: false,
          isConnected: false,
          mode: VpnTunnelMode.direct,
          serverIp: '10.13.37.1',
          lanPort: 9529,
        ),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.wireguardDirect,
        endpoint: const VpnTransportEndpoint(
          serverIp: '10.13.37.1',
          lanPort: 9529,
        ),
        now: connectedAt.add(const Duration(seconds: 15)),
      );

      expect(afterGrace.shouldFallback, isTrue);
    });

    test(
      'direct handoff waits for stable inbound traffic before switching',
      () {
        final coordinator = VpnTransportHandoffCoordinator();
        final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);

        final initial = coordinator.onVpnStatusChanged(
          snapshot: const VpnTunnelSnapshot(
            isActive: true,
            isConnected: true,
            mode: VpnTunnelMode.direct,
            serverIp: '10.13.37.1',
            lanPort: 9529,
            tunPacketsIn: 0,
            udpPacketsIn: 0,
            wgRxBytes: 0,
          ),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: const VpnTransportEndpoint(
            serverIp: '10.13.37.1',
            lanPort: 9529,
          ),
          now: connectedAt,
        );

        expect(initial.type, VpnTransportDecisionType.none);
        expect(coordinator.pendingSwitch, isTrue);

        final ready = coordinator.onVpnStatusChanged(
          snapshot: const VpnTunnelSnapshot(
            isActive: true,
            isConnected: true,
            mode: VpnTunnelMode.direct,
            serverIp: '10.13.37.1',
            lanPort: 9529,
            tunPacketsIn: 2,
            udpPacketsIn: 2,
            wgRxBytes: 256,
          ),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: const VpnTransportEndpoint(
            serverIp: '10.13.37.1',
            lanPort: 9529,
          ),
          now: connectedAt.add(const Duration(seconds: 3)),
        );

        expect(ready.shouldSwitch, isTrue);
        expect(ready.transportKind, TransportKind.wireguardDirect);
      },
    );

    test(
      'direct handoff accepts inbound udp plus wireguard rx bytes even without tun packets',
      () {
        final coordinator = VpnTransportHandoffCoordinator();
        final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);

        coordinator.onVpnStatusChanged(
          snapshot: const VpnTunnelSnapshot(
            isActive: true,
            isConnected: true,
            mode: VpnTunnelMode.direct,
            serverIp: '10.13.37.1',
            lanPort: 9529,
            tunPacketsIn: 0,
            udpPacketsIn: 0,
            wgRxBytes: 0,
          ),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: const VpnTransportEndpoint(
            serverIp: '10.13.37.1',
            lanPort: 9529,
          ),
          now: connectedAt,
        );

        final ready = coordinator.onVpnStatusChanged(
          snapshot: const VpnTunnelSnapshot(
            isActive: true,
            isConnected: true,
            mode: VpnTunnelMode.direct,
            serverIp: '10.13.37.1',
            lanPort: 9529,
            tunPacketsIn: 0,
            udpPacketsIn: 4,
            wgRxBytes: 2048,
          ),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: const VpnTransportEndpoint(
            serverIp: '10.13.37.1',
            lanPort: 9529,
          ),
          now: connectedAt.add(const Duration(seconds: 3)),
        );

        expect(
          VpnTransportHandoffCoordinator.satisfiesDirectReadinessGate(
            const VpnTunnelSnapshot(
              isActive: true,
              isConnected: true,
              mode: VpnTunnelMode.direct,
              serverIp: '10.13.37.1',
              lanPort: 9529,
              tunPacketsIn: 0,
              udpPacketsIn: 4,
              wgRxBytes: 2048,
            ),
          ),
          isTrue,
        );
        expect(ready.shouldSwitch, isTrue);
        expect(ready.transportKind, TransportKind.wireguardDirect);
      },
    );

    test(
      'direct handoff stays pending when inbound udp has not been observed',
      () {
        final coordinator = VpnTransportHandoffCoordinator();
        final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);

        coordinator.onVpnStatusChanged(
          snapshot: const VpnTunnelSnapshot(
            isActive: true,
            isConnected: true,
            mode: VpnTunnelMode.direct,
            serverIp: '10.13.37.1',
            lanPort: 9529,
            tunPacketsIn: 0,
            udpPacketsIn: 0,
            wgRxBytes: 0,
          ),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: const VpnTransportEndpoint(
            serverIp: '10.13.37.1',
            lanPort: 9529,
          ),
          now: connectedAt,
        );

        final notReady = coordinator.onVpnStatusChanged(
          snapshot: const VpnTunnelSnapshot(
            isActive: true,
            isConnected: true,
            mode: VpnTunnelMode.direct,
            serverIp: '10.13.37.1',
            lanPort: 9529,
            tunPacketsIn: 7,
            udpPacketsIn: 0,
            wgRxBytes: 4096,
          ),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: const VpnTransportEndpoint(
            serverIp: '10.13.37.1',
            lanPort: 9529,
          ),
          now: connectedAt.add(const Duration(seconds: 3)),
        );

        expect(
          VpnTransportHandoffCoordinator.satisfiesDirectReadinessGate(
            const VpnTunnelSnapshot(
              isActive: true,
              isConnected: true,
              mode: VpnTunnelMode.direct,
              serverIp: '10.13.37.1',
              lanPort: 9529,
              tunPacketsIn: 7,
              udpPacketsIn: 0,
              wgRxBytes: 4096,
            ),
          ),
          isFalse,
        );
        expect(notReady.type, VpnTransportDecisionType.none);
        expect(coordinator.pendingSwitch, isTrue);
      },
    );

    test('recent vpn switch suppresses immediate fallback flap', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);
      const endpoint = VpnTransportEndpoint(
        serverIp: '10.13.37.1',
        lanPort: 9529,
      );

      // First: connect and switch to wireguardDirect.
      coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: true,
          isConnected: true,
          mode: VpnTunnelMode.direct,
          serverIp: '10.13.37.1',
          lanPort: 9529,
          tunPacketsIn: 0,
          udpPacketsIn: 0,
        ),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: endpoint,
        now: connectedAt,
      );

      final switched = coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: true,
          isConnected: true,
          mode: VpnTunnelMode.direct,
          serverIp: '10.13.37.1',
          lanPort: 9529,
          tunPacketsIn: 1,
          udpPacketsIn: 1,
          wgRxBytes: 128,
        ),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: endpoint,
        now: connectedAt.add(const Duration(seconds: 3)),
      );
      expect(switched.shouldSwitch, isTrue);

      // Disconnect shortly after — within suppression window.
      final disconnectObserved = coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: false,
          isConnected: false,
          mode: VpnTunnelMode.direct,
          serverIp: '10.13.37.1',
          lanPort: 9529,
        ),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.wireguardDirect,
        endpoint: endpoint,
        now: connectedAt.add(const Duration(seconds: 8)),
      );
      expect(disconnectObserved.shouldFallback, isFalse);

      final stillSuppressed = coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: false,
          isConnected: false,
          mode: VpnTunnelMode.direct,
          serverIp: '10.13.37.1',
          lanPort: 9529,
        ),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.wireguardDirect,
        endpoint: endpoint,
        now: connectedAt.add(const Duration(seconds: 10)),
      );
      expect(stillSuppressed.shouldFallback, isFalse);

      final unsuppressed = coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: false,
          isConnected: false,
          mode: VpnTunnelMode.direct,
          serverIp: '10.13.37.1',
          lanPort: 9529,
        ),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.wireguardDirect,
        endpoint: endpoint,
        now: connectedAt.add(const Duration(seconds: 13)),
      );
      expect(unsuppressed.shouldFallback, isTrue);
    });
  });

  group('relay removal safety', () {
    test('relay mode maps to unknown transport kind, not vpn transport', () {
      // ARCH-BLOCKER-1 validation: VpnTunnelMode.relay must NOT map to a
      // VPN transport kind. This prevents _needsTransportSwitch from
      // triggering a stale handoff to a nonexistent relay transport.
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

        // VPN tunnel reports relay mode (stale iOS tunnel during transition).
        // transportKindForMode(.relay) → .unknown → _isVpnTransport false →
        // _needsTransportSwitch returns false → no switch.
        final decision = coordinator.onVpnStatusChanged(
          snapshot: const VpnTunnelSnapshot(
            isActive: true,
            isConnected: true,
            mode: VpnTunnelMode.relay,
            serverIp: '10.13.37.1',
            lanPort: 9529,
            tunPacketsIn: 1,
            udpPacketsIn: 1,
          ),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wormholeRelay,
          endpoint: const VpnTransportEndpoint(
            serverIp: '10.13.37.1',
            lanPort: 9529,
          ),
        );

        // Must NOT switch — relay is a dead transport kind.
        expect(decision.type, VpnTransportDecisionType.none);
      },
    );

    test(
      'unknown transport kind as active does not crash or trigger switch',
      () {
        final coordinator = VpnTransportHandoffCoordinator();

        final decision = coordinator.onVpnStatusChanged(
          snapshot: const VpnTunnelSnapshot(
            isActive: true,
            isConnected: true,
            mode: VpnTunnelMode.direct,
            serverIp: '10.13.37.1',
            lanPort: 9529,
            tunPacketsIn: 1,
            udpPacketsIn: 1,
            wgRxBytes: 128,
          ),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.unknown,
          endpoint: const VpnTransportEndpoint(
            serverIp: '10.13.37.1',
            lanPort: 9529,
          ),
          now: DateTime.utc(2026, 1, 1, 0, 0, 0),
        );

        expect(decision.type, isNot(null));
      },
    );

    test(
      'transportKindForMode returns wireguardDirect for unknown vpn mode',
      () {
        expect(
          VpnTransportHandoffCoordinator.transportKindForMode(
            VpnTunnelMode.unknown,
          ),
          TransportKind.wireguardDirect,
        );
      },
    );

    test(
      'punch timeout: wormholeRelay stays active when desired kind equals '
      'active kind',
      () {
        final coordinator = VpnTransportHandoffCoordinator();

        final decision = coordinator.onVpnStatusChanged(
          snapshot: const VpnTunnelSnapshot(
            isActive: true,
            isConnected: true,
            mode: VpnTunnelMode.unknown,
            serverIp: '10.13.37.1',
            lanPort: 9529,
            tunPacketsIn: 1,
            udpPacketsIn: 1,
            wgRxBytes: 128,
          ),
          primaryConnectionConnected: true,
          activeTransportKind: TransportKind.wireguardDirect,
          endpoint: const VpnTransportEndpoint(
            serverIp: '10.13.37.1',
            lanPort: 9529,
          ),
          now: DateTime.utc(2026, 1, 1, 0, 0, 0),
        );

        expect(decision.type, VpnTransportDecisionType.none);
      },
    );

    test(
      'wireguard_relay wire name deserializes to unknown after enum removal',
      () {
        // Post-removal: old Horizon sends "wireguard_relay" in transport
        // status. New Voyager with removed enum → .unknown.
        expect(
          TransportKind.fromWireName('wireguard_relay'),
          TransportKind.unknown,
        );
      },
    );
  });
}
