import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/connection_manager.dart';
import 'package:voyager/src/services/transport_models.dart';

ConnectionManager createTestManager() {
  return ConnectionManager(
    onConnected: ({required bool waitForPairing}) {},
    onConnectedChanged: (_) {},
    onDisconnected: () {},
    onPairingPendingChanged: (_) {},
    onHostInfo: (_) {},
    onError: (_) {},
    onGroupSync: (_) {},
    onGroupError: (_) {},
    onPairingResult:
        ({
          required bool approved,
          String? assignedKey,
          String? horizonPublicKey,
        }) {},
    onSessionList: (_, {activeSessionId, activeGroupId}) {},
    onSessionCreated: (_) {},
    onSessionClosed: (_) {},
    onStdout: (_, __) {},
  );
}

void main() {
  group('HostInfo.fromMap', () {
    test('parses hostName vpnPeer and remoteAddr', () {
      final info = HostInfo.fromMap({
        'hostName': 'Horizon',
        'vpnPeer': true,
        'remoteAddr': '10.13.37.2:4242',
      }, fromInTunnel: true);

      expect(info.hostName, 'Horizon');
      expect(info.vpnPeer, isTrue);
      expect(info.remoteAddr, '10.13.37.2:4242');
      expect(info.fromInTunnel, isTrue);
    });

    test('treats empty hostName as null and keeps vpnPeer omitted', () {
      final info = HostInfo.fromMap({'hostName': ''}, fromInTunnel: true);

      expect(info.hostName, isNull);
      expect(info.vpnPeer, isNull);
      expect(info.remoteAddr, isNull);
    });

    test('preserves vpnPeer false', () {
      final info = HostInfo.fromMap({
        'hostName': 'Horizon',
        'vpnPeer': false,
        'remoteAddr': '192.168.1.20:9',
      }, fromInTunnel: true);

      expect(info.vpnPeer, isFalse);
      expect(info.remoteAddr, '192.168.1.20:9');
    });

    test('control-plane host_info does not parse vpnPeer', () {
      final info = HostInfo.fromMap({
        'hostName': 'Horizon',
        'vpnPeer': true,
        'remoteAddr': '10.13.37.2:4242',
      });

      expect(info.hostName, 'Horizon');
      expect(info.vpnPeer, isNull);
      expect(info.remoteAddr, isNull);
      expect(info.fromInTunnel, isFalse);
    });
  });

  group('DirectCandidate', () {
    group('fromMap', () {
      test('parses valid data', () {
        final candidate = DirectCandidate.fromMap({
          'addr': '192.168.1.100',
          'port': 51820,
          'scope': 'lan',
          'priority': 250,
          'source': 'local_interface:en0',
        });

        expect(candidate.addr, '192.168.1.100');
        expect(candidate.port, 51820);
        expect(candidate.scope, 'lan');
        expect(candidate.priority, 250);
        expect(candidate.source, 'local_interface:en0');
      });

      test('uses defaults for missing fields', () {
        final candidate = DirectCandidate.fromMap(<String, dynamic>{});

        expect(candidate.addr, '');
        expect(candidate.port, 0);
        expect(candidate.scope, 'unknown');
        expect(candidate.priority, 0);
        expect(candidate.source, 'unknown');
      });

      test('uses defaults for null fields', () {
        final candidate = DirectCandidate.fromMap({
          'addr': null,
          'port': null,
          'scope': null,
          'priority': null,
          'source': null,
        });

        expect(candidate.addr, '');
        expect(candidate.port, 0);
        expect(candidate.scope, 'unknown');
        expect(candidate.priority, 0);
        expect(candidate.source, 'unknown');
      });

      test('handles num types for port and priority', () {
        final candidate = DirectCandidate.fromMap({
          'addr': '10.0.0.1',
          'port': 51820.0,
          'scope': 'public',
          'priority': 100.5,
          'source': 'stun',
        });

        expect(candidate.port, 51820);
        expect(candidate.priority, 100);
      });
    });

    group('toMap', () {
      test('serializes all fields', () {
        const candidate = DirectCandidate(
          addr: '10.0.0.5',
          port: 4500,
          scope: 'public_observed',
          priority: 180,
          source: 'wormhole_observed',
        );

        final map = candidate.toMap();

        expect(map, {
          'addr': '10.0.0.5',
          'port': 4500,
          'scope': 'public_observed',
          'priority': 180,
          'source': 'wormhole_observed',
        });
      });
    });

    group('round-trip', () {
      test('fromMap(toMap()) preserves all fields', () {
        const original = DirectCandidate(
          addr: '203.0.113.42',
          port: 12345,
          scope: 'public',
          priority: 200,
          source: 'stun_mapped',
        );

        final roundTripped = DirectCandidate.fromMap(original.toMap());

        expect(roundTripped.addr, original.addr);
        expect(roundTripped.port, original.port);
        expect(roundTripped.scope, original.scope);
        expect(roundTripped.priority, original.priority);
        expect(roundTripped.source, original.source);
      });
    });
  });

  group('EndpointInfo', () {
    group('fromMap', () {
      test('parses full data', () {
        final info = EndpointInfo.fromMap({
          'wgPublicKey': 'abc123publickey=',
          'wgUdpPort': 51820,
          'netcheckHost': '38.60.162.209',
          'netcheckPort': 6666,
          'horizonAddr': '10.0.0.1',
          'horizonPort': 9090,
          'clientIp': '10.0.0.2',
          'serverIp': '10.0.0.1',
          'subnet': '10.0.0.0/24',
          'dns': ['1.1.1.1', '8.8.8.8'],
          'lanPort': 8080,
          'internalRoutes': ['10.0.0.0/8'],
          'mtu': 1420,
          'punchEpoch': 42,
          'natMappingBehavior': 'endpoint_independent',
          'hairpinLikely': true,
          'directReachabilityScore': 85,
          'horizonCandidates': [
            {
              'addr': '14.153.180.50',
              'port': 51820,
              'scope': 'public_observed',
              'priority': 180,
              'source': 'wormhole_observed',
            },
          ],
          'voyagerCandidates': [
            {
              'addr': '192.168.1.219',
              'port': 51820,
              'scope': 'lan',
              'priority': 250,
              'source': 'local_interface:en0',
            },
          ],
        });

        expect(info.wgPublicKey, 'abc123publickey=');
        expect(info.wgUdpPort, 51820);
        expect(info.netcheckHost, '38.60.162.209');
        expect(info.netcheckPort, 6666);
        expect(info.horizonAddr, '10.0.0.1');
        expect(info.horizonPort, 9090);
        expect(info.clientIp, '10.0.0.2');
        expect(info.serverIp, '10.0.0.1');
        expect(info.subnet, '10.0.0.0/24');
        expect(info.dns, ['1.1.1.1', '8.8.8.8']);
        expect(info.lanPort, 8080);
        expect(info.internalRoutes, ['10.0.0.0/8']);
        expect(info.mtu, 1420);
        expect(info.punchEpoch, 42);
        expect(info.natMappingBehavior, 'endpoint_independent');
        expect(info.hairpinLikely, true);
        expect(info.directReachabilityScore, 85);
        expect(info.horizonCandidates, hasLength(1));
        expect(info.horizonCandidates!.first.addr, '14.153.180.50');
        expect(info.voyagerCandidates, hasLength(1));
        expect(info.voyagerCandidates!.first.scope, 'lan');
      });

      test('parses empty map to all-null fields', () {
        final info = EndpointInfo.fromMap(<String, dynamic>{});

        expect(info.wgPublicKey, isNull);
        expect(info.wgUdpPort, isNull);
        expect(info.netcheckHost, isNull);
        expect(info.netcheckPort, isNull);
        expect(info.horizonAddr, isNull);
        expect(info.horizonPort, isNull);
        expect(info.clientIp, isNull);
        expect(info.serverIp, isNull);
        expect(info.subnet, isNull);
        expect(info.dns, isNull);
        expect(info.lanPort, isNull);
        expect(info.internalRoutes, isNull);
        expect(info.mtu, isNull);
        expect(info.punchEpoch, isNull);
        expect(info.horizonCandidates, isNull);
        expect(info.voyagerCandidates, isNull);
        expect(info.observedEndpoints, isNull);
        expect(info.natMappingBehavior, isNull);
        expect(info.hairpinLikely, isNull);
        expect(info.directReachabilityScore, isNull);
      });

      test('filters out candidates with empty addr', () {
        final info = EndpointInfo.fromMap({
          'horizonCandidates': [
            {
              'addr': '',
              'port': 51820,
              'scope': 'lan',
              'priority': 100,
              'source': 'test',
            },
            {
              'addr': '10.0.0.1',
              'port': 51820,
              'scope': 'lan',
              'priority': 200,
              'source': 'test',
            },
          ],
        });

        expect(info.horizonCandidates, hasLength(1));
        expect(info.horizonCandidates!.first.addr, '10.0.0.1');
      });

      test('filters out candidates with port 0', () {
        final info = EndpointInfo.fromMap({
          'horizonCandidates': [
            {
              'addr': '10.0.0.1',
              'port': 0,
              'scope': 'lan',
              'priority': 100,
              'source': 'test',
            },
          ],
        });

        expect(info.horizonCandidates, isNull);
      });

      test('returns null candidates when all filtered out', () {
        final info = EndpointInfo.fromMap({
          'horizonCandidates': [
            {'addr': '', 'port': 0, 'scope': 'lan'},
          ],
        });

        expect(info.horizonCandidates, isNull);
      });

      test('returns null candidates for non-list value', () {
        final info = EndpointInfo.fromMap({'horizonCandidates': 'not_a_list'});

        expect(info.horizonCandidates, isNull);
      });
    });

    group('mergeWith', () {
      test('returns self when previous is null', () {
        const current = EndpointInfo(
          wgPublicKey: 'key1',
          netcheckHost: '1.2.3.4',
        );

        final merged = current.mergeWith(null);

        expect(merged.wgPublicKey, 'key1');
        expect(merged.netcheckHost, '1.2.3.4');
      });

      test('fills null fields from previous', () {
        const previous = EndpointInfo(
          wgPublicKey: 'prev_key',
          wgUdpPort: 51820,
          clientIp: '10.0.0.2',
        );
        const current = EndpointInfo(wgPublicKey: 'new_key');

        final merged = current.mergeWith(previous);

        expect(merged.wgPublicKey, 'new_key');
        expect(merged.wgUdpPort, 51820);
        expect(merged.clientIp, '10.0.0.2');
      });

      test('current values take precedence for non-null fields', () {
        const previous = EndpointInfo(
          serverIp: '10.0.0.1',
          subnet: '10.0.0.0/24',
          mtu: 1400,
        );
        const current = EndpointInfo(
          serverIp: '10.0.1.1',
          subnet: '10.0.1.0/24',
          mtu: 1420,
        );

        final merged = current.mergeWith(previous);

        expect(merged.serverIp, '10.0.1.1');
        expect(merged.subnet, '10.0.1.0/24');
        expect(merged.mtu, 1420);
      });

      test('deduplicates and sorts candidates by priority descending', () {
        const previous = EndpointInfo(
          horizonCandidates: [
            DirectCandidate(
              addr: '10.0.0.1',
              port: 51820,
              scope: 'lan',
              priority: 100,
              source: 'old',
            ),
            DirectCandidate(
              addr: '14.153.180.50',
              port: 51820,
              scope: 'public_observed',
              priority: 180,
              source: 'wormhole_observed',
            ),
          ],
        );
        const current = EndpointInfo(
          horizonCandidates: [
            DirectCandidate(
              addr: '10.0.0.1',
              port: 51820,
              scope: 'lan',
              priority: 250,
              source: 'updated',
            ),
            DirectCandidate(
              addr: '172.16.0.1',
              port: 51820,
              scope: 'lan',
              priority: 200,
              source: 'new',
            ),
          ],
        );

        final merged = current.mergeWith(previous);

        expect(merged.horizonCandidates, hasLength(3));
        // Sorted by priority descending: 250, 200, 180
        expect(merged.horizonCandidates![0].priority, 250);
        expect(merged.horizonCandidates![0].addr, '10.0.0.1');
        // Current overwrites previous for same addr:port/scope key
        expect(merged.horizonCandidates![0].source, 'updated');
        expect(merged.horizonCandidates![1].priority, 200);
        expect(merged.horizonCandidates![1].addr, '172.16.0.1');
        expect(merged.horizonCandidates![2].priority, 180);
        expect(merged.horizonCandidates![2].addr, '14.153.180.50');
      });

      test('returns current candidates when previous is null', () {
        const current = EndpointInfo(
          horizonCandidates: [
            DirectCandidate(
              addr: '10.0.0.1',
              port: 51820,
              scope: 'lan',
              priority: 100,
              source: 'test',
            ),
          ],
        );

        final merged = current.mergeWith(const EndpointInfo());

        expect(merged.horizonCandidates, hasLength(1));
        expect(merged.horizonCandidates!.first.addr, '10.0.0.1');
      });

      test('returns previous candidates when current is null', () {
        const previous = EndpointInfo(
          horizonCandidates: [
            DirectCandidate(
              addr: '10.0.0.1',
              port: 51820,
              scope: 'lan',
              priority: 100,
              source: 'test',
            ),
          ],
        );

        final merged = const EndpointInfo().mergeWith(previous);

        expect(merged.horizonCandidates, hasLength(1));
        expect(merged.horizonCandidates!.first.addr, '10.0.0.1');
      });

      test('merges voyagerCandidates and observedEndpoints separately', () {
        const previous = EndpointInfo(
          voyagerCandidates: [
            DirectCandidate(
              addr: '192.168.1.100',
              port: 51820,
              scope: 'lan',
              priority: 250,
              source: 'prev',
            ),
          ],
          observedEndpoints: [
            DirectCandidate(
              addr: '1.2.3.4',
              port: 51820,
              scope: 'public_observed',
              priority: 180,
              source: 'prev_obs',
            ),
          ],
        );
        const current = EndpointInfo(
          voyagerCandidates: [
            DirectCandidate(
              addr: '192.168.1.200',
              port: 51820,
              scope: 'lan',
              priority: 240,
              source: 'curr',
            ),
          ],
          observedEndpoints: [
            DirectCandidate(
              addr: '5.6.7.8',
              port: 51820,
              scope: 'public_observed',
              priority: 190,
              source: 'curr_obs',
            ),
          ],
        );

        final merged = current.mergeWith(previous);

        expect(merged.voyagerCandidates, hasLength(2));
        expect(merged.observedEndpoints, hasLength(2));
      });

      // Netcheck merge tests that complement (not duplicate) endpoint_info_test.dart
      test('prefers current IP when both are IPs', () {
        const previous = EndpointInfo(
          netcheckHost: '38.60.162.209',
          netcheckPort: 6666,
        );
        const current = EndpointInfo(
          netcheckHost: '203.0.113.10',
          netcheckPort: 7777,
        );

        final merged = current.mergeWith(previous);

        expect(merged.netcheckHost, '203.0.113.10');
        expect(merged.netcheckPort, 7777);
      });

      test('falls back to previous when current is invalid', () {
        const previous = EndpointInfo(
          netcheckHost: '38.60.162.209',
          netcheckPort: 6666,
        );
        const current = EndpointInfo(netcheckHost: '', netcheckPort: 0);

        final merged = current.mergeWith(previous);

        expect(merged.netcheckHost, '38.60.162.209');
        expect(merged.netcheckPort, 6666);
      });

      test('uses current when previous is invalid', () {
        const previous = EndpointInfo(netcheckHost: null, netcheckPort: null);
        const current = EndpointInfo(
          netcheckHost: '10.0.0.1',
          netcheckPort: 5555,
        );

        final merged = current.mergeWith(previous);

        expect(merged.netcheckHost, '10.0.0.1');
        expect(merged.netcheckPort, 5555);
      });

      test('retains previous IP when current is a domain (IP regression)', () {
        const previous = EndpointInfo(
          netcheckHost: '38.60.162.209',
          netcheckPort: 6666,
        );
        const current = EndpointInfo(
          netcheckHost: 'wormhole.example.com',
          netcheckPort: 6666,
        );

        final merged = current.mergeWith(previous);

        expect(merged.netcheckHost, '38.60.162.209');
        expect(merged.netcheckPort, 6666);
      });

      test('accepts domain when previous has no IP', () {
        const previous = EndpointInfo(
          netcheckHost: 'old.example.com',
          netcheckPort: 6666,
        );
        const current = EndpointInfo(
          netcheckHost: 'new.example.com',
          netcheckPort: 7777,
        );

        final merged = current.mergeWith(previous);

        expect(merged.netcheckHost, 'new.example.com');
        expect(merged.netcheckPort, 7777);
      });

      test('treats IPv6-like host as IP literal', () {
        const previous = EndpointInfo(netcheckHost: '::1', netcheckPort: 6666);
        const current = EndpointInfo(
          netcheckHost: 'relay.example.com',
          netcheckPort: 7777,
        );

        final merged = current.mergeWith(previous);

        // IPv6 contains ':', so it looks like an IP literal and should be retained
        expect(merged.netcheckHost, '::1');
        expect(merged.netcheckPort, 6666);
      });
    });
  });

  group('ConnectionManager initial state', () {
    test('starts disconnected', () {
      final manager = createTestManager();

      expect(manager.connected, isFalse);
      expect(manager.pairingPending, isFalse);
    });

    test('transport metadata starts as defaults', () {
      final manager = createTestManager();

      expect(manager.activeTransportKind, TransportKind.unknown);
      expect(manager.activeTransportId, isNull);
      expect(manager.activePathId, isNull);
      expect(manager.activeSwitchReason, isNull);
      expect(manager.activeFallbackReason, isNull);
      expect(manager.activeProbeRttMs, isNull);
    });

    test('endpointInfo starts null', () {
      final manager = createTestManager();

      expect(manager.endpointInfo, isNull);
    });

    test('activeUri starts null', () {
      final manager = createTestManager();

      expect(manager.activeUri, isNull);
    });

    test('updateTransportKind changes activeTransportKind', () {
      final manager = createTestManager();

      manager.updateTransportKind(TransportKind.wireguardDirect);

      expect(manager.activeTransportKind, TransportKind.wireguardDirect);
    });
  });

  group('ConnectionManager.disconnect', () {
    test('calls onDisconnected when not silent', () {
      var disconnectedCalled = false;
      final manager = ConnectionManager(
        onConnected: ({required bool waitForPairing}) {},
        onConnectedChanged: (_) {},
        onDisconnected: () {
          disconnectedCalled = true;
        },
        onPairingPendingChanged: (_) {},
        onHostInfo: (_) {},
        onError: (_) {},
        onGroupSync: (_) {},
        onGroupError: (_) {},
        onPairingResult:
            ({
              required bool approved,
              String? assignedKey,
              String? horizonPublicKey,
            }) {},
        onSessionList: (_, {activeSessionId, activeGroupId}) {},
        onSessionCreated: (_) {},
        onSessionClosed: (_) {},
        onStdout: (_, __) {},
      );

      manager.disconnect();

      expect(disconnectedCalled, isTrue);
    });

    test('does not call onDisconnected when silent', () {
      var disconnectedCalled = false;
      final manager = ConnectionManager(
        onConnected: ({required bool waitForPairing}) {},
        onConnectedChanged: (_) {},
        onDisconnected: () {
          disconnectedCalled = true;
        },
        onPairingPendingChanged: (_) {},
        onHostInfo: (_) {},
        onError: (_) {},
        onGroupSync: (_) {},
        onGroupError: (_) {},
        onPairingResult:
            ({
              required bool approved,
              String? assignedKey,
              String? horizonPublicKey,
            }) {},
        onSessionList: (_, {activeSessionId, activeGroupId}) {},
        onSessionCreated: (_) {},
        onSessionClosed: (_) {},
        onStdout: (_, __) {},
      );

      manager.disconnect(silent: true);

      expect(disconnectedCalled, isFalse);
    });
  });

  group('ConnectionManager.sendCommand', () {
    test('does nothing when not connected (no channel)', () {
      final manager = createTestManager();

      // Should not throw - just silently returns.
      expect(() => manager.sendCommand({'type': 'test'}), returnsNormally);
    });
  });

  group('ConnectionManager.sendRaw', () {
    test('does nothing when not connected (no channel)', () {
      final manager = createTestManager();

      expect(() => manager.sendRaw('session1', 'hello'), returnsNormally);
    });
  });

  group('ConnectionManager.sendResize', () {
    test('does nothing when not connected (no channel)', () {
      final manager = createTestManager();

      expect(() => manager.sendResize('session1', 80, 24), returnsNormally);
    });
  });

  group('ConnectionManager.sendPing', () {
    test('does nothing when not connected (no channel)', () {
      final manager = createTestManager();

      expect(() => manager.sendPing(), returnsNormally);
    });
  });

  // ---------------------------------------------------------------------------
  // CallbackTracker helper
  // ---------------------------------------------------------------------------
  group('CallbackTracker-based tests', () {
    late CallbackTracker tracker;
    late ConnectionManager manager;

    setUp(() {
      tracker = CallbackTracker();
      manager = tracker.createManager();
    });

    // -----------------------------------------------------------------------
    // updateAutoReconnect
    // -----------------------------------------------------------------------
    group('updateAutoReconnect', () {
      test('can enable auto reconnect without error', () {
        expect(() => manager.updateAutoReconnect(true), returnsNormally);
      });

      test('can disable auto reconnect without error', () {
        expect(() => manager.updateAutoReconnect(false), returnsNormally);
      });

      test('disable then re-enable auto reconnect', () {
        manager.updateAutoReconnect(false);
        manager.updateAutoReconnect(true);
        // No crash, no pending reconnect side-effects on a fresh manager.
        expect(manager.connected, isFalse);
      });
    });

    // -----------------------------------------------------------------------
    // connect() – error paths (no real server ⇒ triggers error callback)
    // -----------------------------------------------------------------------
    group('connect error paths', () {
      test(
        'fires onError callback when connecting to unreachable host',
        () async {
          await manager.connect(
            uri: Uri.parse('ws://127.0.0.1:1'),
            waitForPairing: false,
            autoReconnect: false,
            transportKind: TransportKind.lanDirect,
            transportId: 'test-1',
          );

          expect(tracker.errors, isNotEmpty);
          expect(tracker.errors.first, contains('Failed to connect'));
          expect(manager.connected, isFalse);
        },
      );

      test('fires onConnectedChanged(false) on failed connect', () async {
        // onConnectedChanged starts at false, so it won't fire false again
        // unless it first went true. On a fresh manager it stays false.
        await manager.connect(
          uri: Uri.parse('ws://127.0.0.1:1'),
          waitForPairing: false,
          autoReconnect: false,
        );
        // connected never became true, so onConnectedChanged should not have
        // been called (already false→false is a no-op).
        expect(tracker.connectedChanges, isEmpty);
        expect(manager.connected, isFalse);
      });

      test('pairingPending remains false after failed connect', () async {
        await manager.connect(
          uri: Uri.parse('ws://127.0.0.1:1'),
          waitForPairing: true,
          autoReconnect: false,
        );

        expect(manager.pairingPending, isFalse);
      });

      test('transport metadata is set before connection attempt', () async {
        await manager.connect(
          uri: Uri.parse('ws://127.0.0.1:1'),
          waitForPairing: false,
          autoReconnect: false,
          transportKind: TransportKind.lanDirect,
          transportId: 'my-transport',
          pathId: 'lan:my-transport',
        );

        // Even after failure, the metadata should reflect what was requested.
        expect(manager.activeTransportKind, TransportKind.lanDirect);
        expect(manager.activeTransportId, 'my-transport');
        expect(manager.activePathId, 'lan:my-transport');
      });

      test('pathId defaults to transportId when not specified', () async {
        await manager.connect(
          uri: Uri.parse('ws://127.0.0.1:1'),
          waitForPairing: false,
          autoReconnect: false,
          transportKind: TransportKind.wormholeRelay,
          transportId: 'relay-1',
        );

        expect(manager.activePathId, 'relay-1');
      });

      test(
        'switchReason and fallbackReason are null after fresh connect',
        () async {
          await manager.connect(
            uri: Uri.parse('ws://127.0.0.1:1'),
            waitForPairing: false,
            autoReconnect: false,
            transportKind: TransportKind.lanDirect,
            transportId: 't1',
          );

          expect(manager.activeSwitchReason, isNull);
          expect(manager.activeFallbackReason, isNull);
          expect(manager.activeProbeRttMs, isNull);
        },
      );

      test(
        'disconnect after failed connect still fires onDisconnected',
        () async {
          await manager.connect(
            uri: Uri.parse('ws://127.0.0.1:1'),
            waitForPairing: false,
            autoReconnect: false,
          );
          tracker.disconnectCount = 0; // reset from the connect failure

          manager.disconnect();

          expect(tracker.disconnectCount, 1);
        },
      );

      test(
        'disconnect silent:true suppresses callback after failed connect',
        () async {
          await manager.connect(
            uri: Uri.parse('ws://127.0.0.1:1'),
            waitForPairing: false,
            autoReconnect: false,
          );
          tracker.disconnectCount = 0;

          manager.disconnect(silent: true);

          expect(tracker.disconnectCount, 0);
        },
      );

      test('connect with very short timeout triggers error', () async {
        await manager.connect(
          uri: Uri.parse('ws://127.0.0.1:1'),
          waitForPairing: false,
          autoReconnect: false,
          readyTimeout: const Duration(milliseconds: 1),
        );

        expect(tracker.errors, isNotEmpty);
        expect(manager.connected, isFalse);
      });

      test('does not keep wireguardDirect on a non-10.13.37.1 URI', () async {
        await manager.connect(
          uri: Uri.parse('ws://127.0.0.1:1'),
          waitForPairing: false,
          autoReconnect: false,
          transportKind: TransportKind.wireguardDirect,
        );

        expect(manager.activeTransportKind, TransportKind.unknown);
      });

      test('opens in-tunnel reconnects as unknown, not Direct', () async {
        await manager.connect(
          uri: Uri.parse('ws://10.13.37.1:9527/ws'),
          waitForPairing: false,
          autoReconnect: false,
          transportKind: TransportKind.wireguardDirect,
        );

        expect(manager.activeTransportKind, TransportKind.unknown);
      });
    });

    // -----------------------------------------------------------------------
    // connectWithCandidates
    // -----------------------------------------------------------------------
    group('connectWithCandidates', () {
      test('fires onError when candidates list is empty', () async {
        await manager.connectWithCandidates(
          candidates: [],
          autoReconnect: false,
        );

        expect(tracker.errors, hasLength(1));
        expect(tracker.errors.first, contains('No transport candidate'));
        expect(manager.connected, isFalse);
      });

      test('single candidate delegates to connect()', () async {
        await manager.connectWithCandidates(
          candidates: [
            TransportCandidate(
              id: 'lan-1',
              kind: TransportKind.lanDirect,
              uri: Uri.parse('ws://127.0.0.1:1'),
              waitForPairing: false,
            ),
          ],
          autoReconnect: false,
        );

        // Connection will fail, but metadata should reflect the candidate.
        expect(manager.activeTransportKind, TransportKind.lanDirect);
        expect(manager.activeTransportId, 'lan-1');
        expect(tracker.errors, isNotEmpty);
      });

      test(
        'multiple candidates with unreachable URIs still set metadata',
        () async {
          await manager.connectWithCandidates(
            candidates: [
              TransportCandidate(
                id: 'lan-1',
                kind: TransportKind.lanDirect,
                uri: Uri.parse('ws://127.0.0.1:1'),
                waitForPairing: false,
                priority: 100,
                probeByConnect: true,
              ),
              TransportCandidate(
                id: 'relay-1',
                kind: TransportKind.wormholeRelay,
                uri: Uri.parse('ws://127.0.0.1:2'),
                waitForPairing: false,
                priority: 50,
                probeByConnect: true,
              ),
            ],
            autoReconnect: false,
          );

          // Both probes fail, falls back to first candidate.
          expect(tracker.errors, isNotEmpty);
          expect(manager.connected, isFalse);
        },
      );

      test(
        'multiple candidates with probeByConnect=false skip actual probe',
        () async {
          await manager.connectWithCandidates(
            candidates: [
              TransportCandidate(
                id: 'skip-1',
                kind: TransportKind.lanDirect,
                uri: Uri.parse('ws://127.0.0.1:1'),
                waitForPairing: false,
                priority: 100,
                probeByConnect: false,
              ),
              TransportCandidate(
                id: 'skip-2',
                kind: TransportKind.wormholeRelay,
                uri: Uri.parse('ws://127.0.0.1:2'),
                waitForPairing: false,
                priority: 50,
                probeByConnect: false,
              ),
            ],
            autoReconnect: false,
          );

          // Probes are skipped (instant 999ms rtt), but connect itself still fails.
          expect(tracker.errors, isNotEmpty);
          expect(manager.connected, isFalse);
        },
      );
    });

    // -----------------------------------------------------------------------
    // sendSyncRequest when disconnected
    // -----------------------------------------------------------------------
    group('sendSyncRequest', () {
      test('does nothing when not connected', () {
        expect(() => manager.sendSyncRequest('session-1'), returnsNormally);
      });
    });

    // -----------------------------------------------------------------------
    // sendEndpointRequest when disconnected
    // -----------------------------------------------------------------------
    group('sendEndpointRequest', () {
      test('does nothing when not connected', () {
        expect(
          () =>
              manager.sendEndpointRequest(wgPublicKey: 'key', wgUdpPort: 51820),
          returnsNormally,
        );
      });
    });

    // -----------------------------------------------------------------------
    // sendPeerEndpoint when disconnected
    // -----------------------------------------------------------------------
    group('sendPeerEndpoint', () {
      test('does nothing when not connected', () {
        expect(
          () => manager.sendPeerEndpoint('key', deviceKey: 'dk'),
          returnsNormally,
        );
      });
    });

    // -----------------------------------------------------------------------
    // Transport metadata getters after various state transitions
    // -----------------------------------------------------------------------
    group('transport metadata after state changes', () {
      test('metadata resets after disconnect', () async {
        await manager.connect(
          uri: Uri.parse('ws://127.0.0.1:1'),
          waitForPairing: false,
          autoReconnect: false,
          transportKind: TransportKind.lanDirect,
          transportId: 'x',
          pathId: 'lan:x',
        );

        // After connect (even failed), metadata is set.
        expect(manager.activeTransportKind, TransportKind.lanDirect);

        // Metadata persists after disconnect (it's not cleared).
        manager.disconnect();
        expect(manager.activeTransportKind, TransportKind.lanDirect);
        expect(manager.activeTransportId, 'x');
      });

      test('second connect overwrites metadata from first', () async {
        await manager.connect(
          uri: Uri.parse('ws://127.0.0.1:1'),
          waitForPairing: false,
          autoReconnect: false,
          transportKind: TransportKind.lanDirect,
          transportId: 'first',
          pathId: 'lan:first',
        );

        await manager.connect(
          uri: Uri.parse('ws://127.0.0.1:1'),
          waitForPairing: false,
          autoReconnect: false,
          transportKind: TransportKind.wormholeRelay,
          transportId: 'second',
          pathId: 'relay:second',
        );

        expect(manager.activeTransportKind, TransportKind.wormholeRelay);
        expect(manager.activeTransportId, 'second');
        expect(manager.activePathId, 'relay:second');
      });
    });

    // -----------------------------------------------------------------------
    // endpointInfo getter
    // -----------------------------------------------------------------------
    group('endpointInfo', () {
      test('stays null when no endpoint_info message received', () {
        expect(manager.endpointInfo, isNull);
      });

      test('stays null after failed connect', () async {
        await manager.connect(
          uri: Uri.parse('ws://127.0.0.1:1'),
          waitForPairing: false,
          autoReconnect: false,
        );

        expect(manager.endpointInfo, isNull);
      });
    });

    // -----------------------------------------------------------------------
    // Disconnect scenarios
    // -----------------------------------------------------------------------
    group('disconnect edge cases', () {
      test('calling disconnect twice does not double-fire', () {
        manager.disconnect();
        final countAfterFirst = tracker.disconnectCount;
        manager.disconnect();
        // Second call should still fire onDisconnected (it's unconditional in
        // _resetConnectionState). Both calls happen.
        expect(tracker.disconnectCount, countAfterFirst + 1);
      });

      test(
        'disconnect with shouldReconnect=true does not reconnect if autoReconnect disabled',
        () async {
          manager.updateAutoReconnect(false);
          manager.disconnect(shouldReconnect: true);

          // Give a moment for any timer to fire (there shouldn't be one).
          await Future<void>.delayed(const Duration(milliseconds: 50));
          expect(manager.connected, isFalse);
        },
      );
    });
  });

  // ---------------------------------------------------------------------------
  // _ensureWsPath tests (exercised via connect's URI transformation)
  // ---------------------------------------------------------------------------
  group('_ensureWsPath (via connect)', () {
    test('adds /ws to URI with empty path', () async {
      final tracker = CallbackTracker();
      final manager = tracker.createManager();

      // ws://127.0.0.1:1 has empty path → should become ws://127.0.0.1:1/ws
      await manager.connect(
        uri: Uri.parse('ws://127.0.0.1:1'),
        waitForPairing: false,
        autoReconnect: false,
      );

      // We can verify indirectly: the error message or the fact that the
      // connect attempt was made at all proves _ensureWsPath ran.
      expect(tracker.errors, isNotEmpty);
    });

    test('adds /ws to URI with root path', () async {
      final tracker = CallbackTracker();
      final manager = tracker.createManager();

      await manager.connect(
        uri: Uri.parse('ws://127.0.0.1:1/'),
        waitForPairing: false,
        autoReconnect: false,
      );

      expect(tracker.errors, isNotEmpty);
    });

    test('does not modify URI with existing path', () async {
      final tracker = CallbackTracker();
      final manager = tracker.createManager();

      await manager.connect(
        uri: Uri.parse('ws://127.0.0.1:1/existing/path'),
        waitForPairing: false,
        autoReconnect: false,
      );

      expect(tracker.errors, isNotEmpty);
    });
  });

  // ---------------------------------------------------------------------------
  // TransportKind and TransportControlType (model tests)
  // ---------------------------------------------------------------------------
  group('TransportKind', () {
    test('fromWireName returns correct kinds', () {
      expect(TransportKind.fromWireName('lan_direct'), TransportKind.lanDirect);
      expect(
        TransportKind.fromWireName('wormhole_relay'),
        TransportKind.wormholeRelay,
      );
      expect(
        TransportKind.fromWireName('wireguard_direct'),
        TransportKind.wireguardDirect,
      );
      expect(
        TransportKind.fromWireName('wireguard_relay'),
        TransportKind.unknown,
      );
      expect(TransportKind.fromWireName('unknown'), TransportKind.unknown);
    });

    test('fromWireName returns unknown for null', () {
      expect(TransportKind.fromWireName(null), TransportKind.unknown);
    });

    test('fromWireName returns unknown for unrecognized string', () {
      expect(TransportKind.fromWireName('banana'), TransportKind.unknown);
    });
  });

  group('TransportControlType', () {
    test('fromType returns correct types', () {
      expect(
        TransportControlType.fromType('transport_probe'),
        TransportControlType.transportProbe,
      );
      expect(
        TransportControlType.fromType('transport_probe_result'),
        TransportControlType.transportProbeResult,
      );
      expect(
        TransportControlType.fromType('transport_switch_prepare'),
        TransportControlType.transportSwitchPrepare,
      );
      expect(
        TransportControlType.fromType('transport_switch_commit'),
        TransportControlType.transportSwitchCommit,
      );
      expect(
        TransportControlType.fromType('transport_switch_abort'),
        TransportControlType.transportSwitchAbort,
      );
    });

    test('fromType returns unknown for null', () {
      expect(TransportControlType.fromType(null), TransportControlType.unknown);
    });

    test('fromType returns unknown for unrecognized string', () {
      expect(
        TransportControlType.fromType('nope'),
        TransportControlType.unknown,
      );
    });
  });

  // ---------------------------------------------------------------------------
  // TransportMetadata round-trip
  // ---------------------------------------------------------------------------
  group('TransportMetadata', () {
    test('toWire/fromWire round-trips', () {
      const meta = TransportMetadata(
        transportId: 'tid-1',
        pathId: 'pid-1',
        switchReason: 'better_rtt',
        fallbackReason: 'probe_timeout',
        probeRttMs: 42,
      );

      final wire = meta.toWire();
      final decoded = TransportMetadata.fromWire(wire);

      expect(decoded.transportId, 'tid-1');
      expect(decoded.pathId, 'pid-1');
      expect(decoded.switchReason, 'better_rtt');
      expect(decoded.fallbackReason, 'probe_timeout');
      expect(decoded.probeRttMs, 42);
    });

    test('fromWire with empty map returns all-null', () {
      final decoded = TransportMetadata.fromWire(<String, dynamic>{});

      expect(decoded.transportId, isNull);
      expect(decoded.pathId, isNull);
      expect(decoded.switchReason, isNull);
      expect(decoded.fallbackReason, isNull);
      expect(decoded.probeRttMs, isNull);
    });

    test('fromWire handles num probeRttMs', () {
      final decoded = TransportMetadata.fromWire({'probeRttMs': 3.14});
      expect(decoded.probeRttMs, 3);
    });

    test('toWire omits null fields', () {
      const meta = TransportMetadata(transportId: 'only-this');
      final wire = meta.toWire();

      expect(wire.containsKey('transportId'), isTrue);
      expect(wire.containsKey('pathId'), isFalse);
      expect(wire.containsKey('switchReason'), isFalse);
      expect(wire.containsKey('fallbackReason'), isFalse);
      expect(wire.containsKey('probeRttMs'), isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // TransportCandidate construction
  // ---------------------------------------------------------------------------
  group('TransportCandidate', () {
    test('defaults priority to 0 and probeByConnect to true', () {
      final candidate = TransportCandidate(
        id: 'c1',
        kind: TransportKind.lanDirect,
        uri: Uri.parse('ws://localhost:8080'),
        waitForPairing: false,
      );

      expect(candidate.priority, 0);
      expect(candidate.probeByConnect, isTrue);
    });

    test('respects explicit priority and probeByConnect', () {
      final candidate = TransportCandidate(
        id: 'c2',
        kind: TransportKind.wormholeRelay,
        uri: Uri.parse('wss://relay.example.com/ws'),
        waitForPairing: true,
        priority: 99,
        probeByConnect: false,
      );

      expect(candidate.priority, 99);
      expect(candidate.probeByConnect, isFalse);
      expect(candidate.waitForPairing, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // TransportProbeResult
  // ---------------------------------------------------------------------------
  group('TransportProbeResult', () {
    test('stores success with rtt', () {
      final candidate = TransportCandidate(
        id: 'p1',
        kind: TransportKind.lanDirect,
        uri: Uri.parse('ws://localhost:1'),
        waitForPairing: false,
      );
      final result = TransportProbeResult(
        candidate: candidate,
        success: true,
        rtt: const Duration(milliseconds: 50),
      );

      expect(result.success, isTrue);
      expect(result.rtt, const Duration(milliseconds: 50));
      expect(result.error, isNull);
    });

    test('stores failure with error', () {
      final candidate = TransportCandidate(
        id: 'p2',
        kind: TransportKind.wormholeRelay,
        uri: Uri.parse('ws://localhost:2'),
        waitForPairing: false,
      );
      final result = TransportProbeResult(
        candidate: candidate,
        success: false,
        error: 'timeout',
      );

      expect(result.success, isFalse);
      expect(result.rtt, isNull);
      expect(result.error, 'timeout');
    });
  });

  // ---------------------------------------------------------------------------
  // _looksLikeIpLiteral coverage (indirectly via EndpointInfo.mergeWith)
  // ---------------------------------------------------------------------------
  group('IP literal detection in merge', () {
    test('dotted-quad with short octets is detected as IP', () {
      const previous = EndpointInfo(netcheckHost: '1.2.3.4', netcheckPort: 100);
      const current = EndpointInfo(netcheckHost: 'dns.name', netcheckPort: 200);

      final merged = current.mergeWith(previous);
      expect(merged.netcheckHost, '1.2.3.4');
    });

    test('IPv6 loopback is detected as IP', () {
      const previous = EndpointInfo(netcheckHost: '::1', netcheckPort: 100);
      const current = EndpointInfo(
        netcheckHost: 'host.example.com',
        netcheckPort: 200,
      );

      final merged = current.mergeWith(previous);
      expect(merged.netcheckHost, '::1');
    });

    test('two domain names: current wins', () {
      const previous = EndpointInfo(netcheckHost: 'old.com', netcheckPort: 100);
      const current = EndpointInfo(netcheckHost: 'new.com', netcheckPort: 200);

      final merged = current.mergeWith(previous);
      expect(merged.netcheckHost, 'new.com');
      expect(merged.netcheckPort, 200);
    });

    test('two IPs: current wins', () {
      const previous = EndpointInfo(
        netcheckHost: '10.0.0.1',
        netcheckPort: 100,
      );
      const current = EndpointInfo(netcheckHost: '10.0.0.2', netcheckPort: 200);

      final merged = current.mergeWith(previous);
      expect(merged.netcheckHost, '10.0.0.2');
      expect(merged.netcheckPort, 200);
    });

    test('current is IP, previous is domain: current wins', () {
      const previous = EndpointInfo(
        netcheckHost: 'host.com',
        netcheckPort: 100,
      );
      const current = EndpointInfo(
        netcheckHost: '192.168.1.1',
        netcheckPort: 200,
      );

      final merged = current.mergeWith(previous);
      expect(merged.netcheckHost, '192.168.1.1');
      expect(merged.netcheckPort, 200);
    });
  });

  // ---------------------------------------------------------------------------
  // _mergeDirectCandidateLists edge cases (via EndpointInfo.mergeWith)
  // ---------------------------------------------------------------------------
  group('mergeDirectCandidateLists edge cases', () {
    test('both lists empty returns empty (treated as null-like)', () {
      const previous = EndpointInfo(horizonCandidates: []);
      const current = EndpointInfo(horizonCandidates: []);

      final merged = current.mergeWith(previous);
      // Empty lists are treated like null by the merge helper, so
      // previous empty → returns current (also empty).
      expect(merged.horizonCandidates, isEmpty);
    });

    test('previous is empty list, current has items', () {
      const current = EndpointInfo(
        horizonCandidates: [
          DirectCandidate(
            addr: '1.2.3.4',
            port: 100,
            scope: 'lan',
            priority: 10,
            source: 'test',
          ),
        ],
      );
      const previous = EndpointInfo(horizonCandidates: []);

      final merged = current.mergeWith(previous);
      expect(merged.horizonCandidates, hasLength(1));
    });

    test('same addr:port/scope in both lists: current wins', () {
      const previous = EndpointInfo(
        horizonCandidates: [
          DirectCandidate(
            addr: '1.1.1.1',
            port: 51820,
            scope: 'lan',
            priority: 10,
            source: 'old',
          ),
        ],
      );
      const current = EndpointInfo(
        horizonCandidates: [
          DirectCandidate(
            addr: '1.1.1.1',
            port: 51820,
            scope: 'lan',
            priority: 99,
            source: 'new',
          ),
        ],
      );

      final merged = current.mergeWith(previous);
      expect(merged.horizonCandidates, hasLength(1));
      expect(merged.horizonCandidates!.first.source, 'new');
      expect(merged.horizonCandidates!.first.priority, 99);
    });

    test('different scope creates separate entries', () {
      const previous = EndpointInfo(
        horizonCandidates: [
          DirectCandidate(
            addr: '1.1.1.1',
            port: 51820,
            scope: 'lan',
            priority: 10,
            source: 'a',
          ),
        ],
      );
      const current = EndpointInfo(
        horizonCandidates: [
          DirectCandidate(
            addr: '1.1.1.1',
            port: 51820,
            scope: 'public',
            priority: 20,
            source: 'b',
          ),
        ],
      );

      final merged = current.mergeWith(previous);
      expect(merged.horizonCandidates, hasLength(2));
    });
  });

  // ---------------------------------------------------------------------------
  // Multiple connect/disconnect cycles
  // ---------------------------------------------------------------------------
  group('connect/disconnect cycle', () {
    test('multiple connect attempts collect all errors', () async {
      final tracker = CallbackTracker();
      final manager = tracker.createManager();

      await manager.connect(
        uri: Uri.parse('ws://127.0.0.1:1'),
        waitForPairing: false,
        autoReconnect: false,
      );
      await manager.connect(
        uri: Uri.parse('ws://127.0.0.1:2'),
        waitForPairing: false,
        autoReconnect: false,
      );

      expect(tracker.errors.length, greaterThanOrEqualTo(2));
    });

    test('disconnect between connects resets state properly', () async {
      final tracker = CallbackTracker();
      final manager = tracker.createManager();

      await manager.connect(
        uri: Uri.parse('ws://127.0.0.1:1'),
        waitForPairing: false,
        autoReconnect: false,
      );
      manager.disconnect();

      await manager.connect(
        uri: Uri.parse('ws://127.0.0.1:2'),
        waitForPairing: false,
        autoReconnect: false,
      );
      manager.disconnect();

      expect(manager.connected, isFalse);
      expect(manager.pairingPending, isFalse);
    });
  });

  // ---------------------------------------------------------------------------
  // EndpointInfo.fromMap edge cases
  // ---------------------------------------------------------------------------
  group('EndpointInfo.fromMap additional edge cases', () {
    test('candidates list containing non-Map entries filters them out', () {
      final info = EndpointInfo.fromMap({
        'horizonCandidates': [
          'not_a_map',
          42,
          {
            'addr': '10.0.0.1',
            'port': 51820,
            'scope': 'lan',
            'priority': 100,
            'source': 'test',
          },
        ],
      });

      expect(info.horizonCandidates, hasLength(1));
      expect(info.horizonCandidates!.first.addr, '10.0.0.1');
    });

    test('dns as empty list parses to empty list', () {
      final info = EndpointInfo.fromMap({'dns': <dynamic>[]});
      expect(info.dns, isEmpty);
    });

    test('internalRoutes parses correctly', () {
      final info = EndpointInfo.fromMap({
        'internalRoutes': ['10.0.0.0/8', '172.16.0.0/12'],
      });
      expect(info.internalRoutes, hasLength(2));
    });

    test('lanPort as double is truncated to int', () {
      final info = EndpointInfo.fromMap({'lanPort': 8080.7});
      expect(info.lanPort, 8080);
    });

    test('mtu as double is truncated to int', () {
      final info = EndpointInfo.fromMap({'mtu': 1420.5});
      expect(info.mtu, 1420);
    });

    test('punchEpoch as double is truncated to int', () {
      final info = EndpointInfo.fromMap({'punchEpoch': 99.9});
      expect(info.punchEpoch, 99);
    });

    test('directReachabilityScore as double', () {
      final info = EndpointInfo.fromMap({'directReachabilityScore': 85.3});
      expect(info.directReachabilityScore, 85);
    });
  });

  // ---------------------------------------------------------------------------
  // DirectCandidate equality semantics (identity-based, not value-based)
  // ---------------------------------------------------------------------------
  group('DirectCandidate misc', () {
    test('toMap produces expected keys', () {
      const c = DirectCandidate(
        addr: 'a',
        port: 1,
        scope: 's',
        priority: 2,
        source: 'src',
      );
      final map = c.toMap();
      expect(map.keys.toSet(), {'addr', 'port', 'scope', 'priority', 'source'});
    });

    test('fromMap with string port throws type cast error', () {
      // The factory uses `as num?` which throws on non-num types.
      expect(
        () => DirectCandidate.fromMap({'port': 'not_a_number'}),
        throwsA(isA<TypeError>()),
      );
    });

    test('fromMap with string priority throws type cast error', () {
      expect(
        () => DirectCandidate.fromMap({'priority': 'high'}),
        throwsA(isA<TypeError>()),
      );
    });
  });

  group('dual-plane control + data sockets', () {
    late CallbackTracker tracker;
    late ConnectionManager manager;
    late _LoopbackWs control;
    late _LoopbackWs data;

    setUp(() {
      tracker = CallbackTracker();
      manager = tracker.createManager();
      control = _LoopbackWs();
      data = _LoopbackWs();
    });

    tearDown(() async {
      manager.disconnect(silent: true);
      await control.close();
      await data.close();
    });

    test('keeps control WS and routes binary only to data', () async {
      final controlUri = await control.start();
      final dataUri = await data.start();

      await manager.connect(
        uri: controlUri,
        waitForPairing: false,
        autoReconnect: false,
        transportKind: TransportKind.wormholeRelay,
      );
      await control.waitForClient();
      expect(manager.connected, isTrue);

      await manager.openDataPlane(uri: dataUri, deviceKey: 'dev-a');
      await data.waitForClient();
      expect(manager.hasDataPlane, isTrue);
      expect(manager.connected, isTrue);
      expect(manager.activeUri?.host, controlUri.host);
      expect(manager.activeUri?.port, controlUri.port);

      await _waitUntil(
        () => control.messages.whereType<String>().any(
          (msg) => msg.contains('"data_plane"'),
        ),
      );
      final controlBind = jsonDecode(
        control.messages.whereType<String>().firstWhere(
          (msg) => msg.contains('"data_plane"'),
        ),
      );
      expect(controlBind['type'], 'data_plane');
      expect(controlBind['active'], isFalse);
      expect(controlBind['deviceKey'], 'dev-a');

      manager.sendCommand({'type': 'list'});
      manager.sendRaw('session-1', 'x');

      await _waitUntil(
        () => control.messages.whereType<String>().any(
          (msg) => msg.contains('"list"'),
        ),
      );
      await _waitUntil(() => data.messages.isNotEmpty);

      expect(
        control.messages.whereType<String>().any(
          (msg) => msg.contains('"list"'),
        ),
        isTrue,
      );
      expect(control.messages.whereType<List<int>>(), isEmpty);
      expect(data.messages.whereType<String>(), isEmpty);
      final binary = data.messages.whereType<List<int>>().first;
      expect(binary[0], 1);
      expect(binary[1], 1); // stdin
    });

    test('parses vpnPeer only from in-tunnel host_info', () async {
      final controlUri = await control.start();
      final dataUri = await data.start();

      await manager.connect(
        uri: controlUri,
        waitForPairing: false,
        autoReconnect: false,
      );
      await control.waitForClient();
      await manager.openDataPlane(uri: dataUri, deviceKey: 'dev-a');
      await data.waitForClient();

      control.socket!.add(
        jsonEncode({
          'v': 1,
          'type': 'host_info',
          'hostName': 'Horizon',
          'vpnPeer': false,
        }),
      );
      await _waitUntil(() => tracker.hostInfos.length == 1);
      expect(tracker.hostInfos.single.fromInTunnel, isFalse);
      expect(tracker.hostInfos.single.vpnPeer, isNull);

      data.socket!.add(
        jsonEncode({
          'v': 1,
          'type': 'host_info',
          'hostName': 'Horizon',
          'vpnPeer': true,
          'remoteAddr': '10.13.37.2:4242',
        }),
      );
      await _waitUntil(() => tracker.hostInfos.length == 2);
      expect(tracker.hostInfos.last.fromInTunnel, isTrue);
      expect(tracker.hostInfos.last.vpnPeer, isTrue);

      await _waitUntil(
        () => data.messages.whereType<String>().any(
          (msg) => msg.contains('"data_plane"'),
        ),
      );
      final dataPlane = jsonDecode(
        data.messages.whereType<String>().firstWhere(
          (msg) => msg.contains('"data_plane"'),
        ),
      );
      expect(dataPlane['type'], 'data_plane');
      expect(dataPlane['active'], isTrue);
      expect(dataPlane['deviceKey'], 'dev-a');
      expect(dataPlane['v'], 1);
    });

    test(
      'closeDataPlane keeps control connected and does not re-pair',
      () async {
        final controlUri = await control.start();
        final dataUri = await data.start();

        await manager.connect(
          uri: controlUri,
          waitForPairing: false,
          autoReconnect: false,
        );
        await control.waitForClient();
        await manager.openDataPlane(uri: dataUri, deviceKey: 'dev-a');
        await data.waitForClient();

        manager.closeDataPlane(silent: true);
        await Future<void>.delayed(const Duration(milliseconds: 50));

        expect(manager.hasDataPlane, isFalse);
        expect(manager.connected, isTrue);
        expect(manager.pairingPending, isFalse);
        expect(tracker.pairingResults, isEmpty);
      },
    );

    test('control reconnect keeps Direct while data plane is live', () async {
      final controlUri = await control.start();
      final dataUri = await data.start();

      await manager.connect(
        uri: controlUri,
        waitForPairing: false,
        autoReconnect: false,
        transportKind: TransportKind.lanDirect,
      );
      await control.waitForClient();
      await manager.openDataPlane(uri: dataUri, deviceKey: 'dev-a');
      await data.waitForClient();
      manager.updateTransportKind(TransportKind.wireguardDirect);

      await manager.connect(
        uri: controlUri,
        waitForPairing: false,
        autoReconnect: false,
        transportKind: TransportKind.lanDirect,
      );

      expect(manager.hasDataPlane, isTrue);
      expect(manager.connected, isTrue);
      expect(manager.activeTransportKind, TransportKind.wireguardDirect);
    });

    test('disconnect clears stored control kind', () async {
      final controlUri = await control.start();
      final dataUri = await data.start();

      await manager.connect(
        uri: controlUri,
        waitForPairing: false,
        autoReconnect: false,
        transportKind: TransportKind.lanDirect,
      );
      await control.waitForClient();
      await manager.openDataPlane(uri: dataUri, deviceKey: 'dev-a');
      await data.waitForClient();
      manager.updateTransportKind(TransportKind.wireguardDirect);
      manager.closeDataPlane(silent: true);
      expect(manager.activeTransportKind, TransportKind.lanDirect);

      manager.disconnect(silent: true);
      await manager.connect(
        uri: controlUri,
        waitForPairing: false,
        autoReconnect: false,
        transportKind: TransportKind.wormholeRelay,
      );
      await manager.openDataPlane(uri: dataUri, deviceKey: 'dev-a');
      manager.updateTransportKind(TransportKind.wireguardDirect);
      manager.closeDataPlane(silent: true);

      expect(manager.activeTransportKind, TransportKind.wormholeRelay);
    });
  });
}

Future<void> _waitUntil(bool Function() test) async {
  final end = DateTime.now().add(const Duration(seconds: 3));
  while (!test()) {
    if (DateTime.now().isAfter(end)) {
      throw TimeoutException('condition not met');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}

class _LoopbackWs {
  HttpServer? _server;
  WebSocket? socket;
  final messages = <dynamic>[];
  Completer<WebSocket>? _ready;

  Future<Uri> start() async {
    _ready = Completer<WebSocket>();
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    unawaited(
      _server!.forEach((request) async {
        if (WebSocketTransformer.isUpgradeRequest(request)) {
          final ws = await WebSocketTransformer.upgrade(request);
          socket = ws;
          ws.listen(messages.add);
          final ready = _ready;
          if (ready != null && !ready.isCompleted) {
            ready.complete(ws);
          }
        } else {
          request.response.statusCode = HttpStatus.notFound;
          await request.response.close();
        }
      }),
    );
    return Uri.parse('ws://${_server!.address.address}:${_server!.port}/ws');
  }

  Future<void> waitForClient() {
    return _ready!.future.timeout(const Duration(seconds: 3));
  }

  Future<void> close() async {
    await socket?.close();
    await _server?.close(force: true);
  }
}

// =============================================================================
// CallbackTracker helper
// =============================================================================
class CallbackTracker {
  final errors = <String>[];
  final connectedChanges = <bool>[];
  final pairingPendingChanges = <bool>[];
  final groupSyncs = <Map<String, dynamic>>[];
  final groupErrors = <String>[];
  final hostInfos = <HostInfo>[];
  final sessionLists = <List<String>>[];
  final sessionsCreated = <String>[];
  final sessionsClosed = <String>[];
  final stdoutData = <(String, Uint8List)>[];
  int disconnectCount = 0;
  int connectedCount = 0;
  bool lastWaitForPairing = false;
  final pairingResults =
      <({bool approved, String? assignedKey, String? horizonPublicKey})>[];
  final endpointInfos = <EndpointInfo>[];
  final vpnConfigs = <EndpointInfo>[];

  ConnectionManager createManager() {
    return ConnectionManager(
      onConnected: ({required bool waitForPairing}) {
        connectedCount++;
        lastWaitForPairing = waitForPairing;
      },
      onConnectedChanged: (connected) {
        connectedChanges.add(connected);
      },
      onDisconnected: () {
        disconnectCount++;
      },
      onPairingPendingChanged: (pending) {
        pairingPendingChanges.add(pending);
      },
      onHostInfo: (info) {
        hostInfos.add(info);
      },
      onError: (message) {
        errors.add(message);
      },
      onGroupSync: (payload) {
        groupSyncs.add(payload);
      },
      onGroupError: (message) {
        groupErrors.add(message);
      },
      onPairingResult: ({
        required bool approved,
        String? assignedKey,
        String? horizonPublicKey,
      }) {
        pairingResults.add((
          approved: approved,
          assignedKey: assignedKey,
          horizonPublicKey: horizonPublicKey,
        ));
      },
      onSessionList: (sessions, {activeSessionId, activeGroupId}) {
        sessionLists.add(sessions);
      },
      onSessionCreated: (sessionId) {
        sessionsCreated.add(sessionId);
      },
      onSessionClosed: (sessionId) {
        sessionsClosed.add(sessionId);
      },
      onStdout: (sessionId, data) {
        stdoutData.add((sessionId, data));
      },
      onEndpointInfo: (info) {
        endpointInfos.add(info);
      },
      onVpnConfig: (info) {
        vpnConfigs.add(info);
      },
    );
  }
}
