import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/vpn_service.dart';

void main() {
  // ---------------------------------------------------------------------------
  // VpnStatus.fromString
  // ---------------------------------------------------------------------------
  group('VpnStatus.fromString', () {
    test('parses every known status name', () {
      for (final status in VpnStatus.values) {
        expect(VpnStatus.fromString(status.name), status);
      }
    });

    test('returns disconnected for null', () {
      expect(VpnStatus.fromString(null), VpnStatus.disconnected);
    });

    test('returns disconnected for unknown string', () {
      expect(VpnStatus.fromString('bogus'), VpnStatus.disconnected);
    });
  });

  // ---------------------------------------------------------------------------
  // VpnConnectionMode.fromString
  // ---------------------------------------------------------------------------
  group('VpnConnectionMode.fromString', () {
    test('parses every known mode name', () {
      for (final mode in VpnConnectionMode.values) {
        expect(VpnConnectionMode.fromString(mode.name), mode);
      }
    });

    test('returns unknown for null', () {
      expect(VpnConnectionMode.fromString(null), VpnConnectionMode.unknown);
    });

    test('returns unknown for unrecognized string', () {
      expect(VpnConnectionMode.fromString('xyzzy'), VpnConnectionMode.unknown);
    });
  });

  // ---------------------------------------------------------------------------
  // VpnConfig.toMap() serialization
  // ---------------------------------------------------------------------------
  group('VpnConfig.toMap()', () {
    const requiredOnly = VpnConfig(
      privateKey: 'privkey-abc',
      peerPublicKey: 'pubkey-xyz',
      serverAddr: '1.2.3.4',
      serverPort: 51820,
      clientIp: '10.13.37.2',
      serverIp: '10.13.37.1',
    );

    test('includes all required fields with correct keys', () {
      final map = requiredOnly.toMap();
      expect(map['privateKey'], 'privkey-abc');
      expect(map['peerPublicKey'], 'pubkey-xyz');
      expect(map['keepaliveSecs'], 25);
      expect(map['serverAddr'], '1.2.3.4');
      expect(map['serverPort'], 51820);
      expect(map['clientIp'], '10.13.37.2');
      expect(map['serverIp'], '10.13.37.1');
      expect(map['lanPort'], 9527);
      expect(map['subnet'], '10.13.37.0/24');
      expect(map['dns'], ['10.13.37.1']);
      expect(map['dnsMatchDomains'], <String>[]);
      expect(map['internalRoutes'], <String>[]);
      expect(map['mtu'], 1280);
    });

    test('excludes null optional fields', () {
      final map = requiredOnly.toMap();
      expect(map.containsKey('presharedKey'), isFalse);
      expect(map.containsKey('localPort'), isFalse);
      expect(map.containsKey('netcheckHost'), isFalse);
      expect(map.containsKey('netcheckPort'), isFalse);
    });

    test('excludes directCandidates when empty', () {
      final map = requiredOnly.toMap();
      expect(map.containsKey('directCandidates'), isFalse);
    });

    test('includes non-null optional fields when provided', () {
      const config = VpnConfig(
        privateKey: 'pk',
        peerPublicKey: 'ppk',
        presharedKey: 'psk-123',
        serverAddr: '5.6.7.8',
        serverPort: 443,
        clientIp: '10.0.0.2',
        serverIp: '10.0.0.1',
        localPort: 12345,
        netcheckHost: 'netcheck.example.com',
        netcheckPort: 3478,
      );
      final map = config.toMap();
      expect(map['presharedKey'], 'psk-123');
      expect(map['localPort'], 12345);
      expect(map['netcheckHost'], 'netcheck.example.com');
      expect(map['netcheckPort'], 3478);
    });

    test('includes directCandidates when non-empty', () {
      const config = VpnConfig(
        privateKey: 'pk',
        peerPublicKey: 'ppk',
        serverAddr: '1.2.3.4',
        serverPort: 51820,
        clientIp: '10.0.0.2',
        serverIp: '10.0.0.1',
        directCandidates: [
          {'host': '192.168.1.5', 'port': 51821},
          {'host': '10.0.0.5', 'port': 51822},
        ],
      );
      final map = config.toMap();
      expect(map['directCandidates'], isList);
      final candidates = map['directCandidates'] as List<Map<String, dynamic>>;
      expect(candidates, hasLength(2));
      expect(candidates[0]['host'], '192.168.1.5');
      expect(candidates[0]['port'], 51821);
      expect(candidates[1]['host'], '10.0.0.5');
      expect(candidates[1]['port'], 51822);
    });

    test('custom defaults can be overridden', () {
      const config = VpnConfig(
        privateKey: 'pk',
        peerPublicKey: 'ppk',
        serverAddr: '1.2.3.4',
        serverPort: 51820,
        clientIp: '10.0.0.2',
        serverIp: '10.0.0.1',
        keepaliveSecs: 60,
        lanPort: 8080,
        subnet: '172.16.0.0/16',
        dns: ['8.8.8.8', '8.8.4.4'],
        dnsMatchDomains: ['example.com'],
        internalRoutes: ['192.168.0.0/16'],
        mtu: 1400,
      );
      final map = config.toMap();
      expect(map['keepaliveSecs'], 60);
      expect(map['lanPort'], 8080);
      expect(map['subnet'], '172.16.0.0/16');
      expect(map['dns'], ['8.8.8.8', '8.8.4.4']);
      expect(map['dnsMatchDomains'], ['example.com']);
      expect(map['internalRoutes'], ['192.168.0.0/16']);
      expect(map['mtu'], 1400);
    });
  });

  // ---------------------------------------------------------------------------
  // VpnService state machine
  // ---------------------------------------------------------------------------
  group('VpnService state machine', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late VpnService service;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      service = VpnService();
    });

    tearDown(() {
      service.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

    test('initial status is disconnected', () {
      expect(service.status, VpnStatus.disconnected);
      expect(service.isConnected, isFalse);
      expect(service.isActive, isFalse);
      expect(service.error, isNull);
      expect(service.clientIp, isNull);
      expect(service.serverIp, isNull);
    });

    test('beginNegotiation() sets status to connecting and clears fields', () {
      service.beginNegotiation();
      expect(service.status, VpnStatus.connecting);
      expect(service.isConnected, isFalse);
      expect(service.isActive, isTrue);
      expect(service.error, isNull);
      expect(service.clientIp, isNull);
      expect(service.serverIp, isNull);
      expect(service.connectionMode, VpnConnectionMode.unknown);
    });

    test('failNegotiation() sets status to error with message', () {
      service.beginNegotiation();
      service.failNegotiation('timeout reached');
      expect(service.status, VpnStatus.error);
      expect(service.error, 'timeout reached');
      expect(service.isConnected, isFalse);
      expect(service.isActive, isFalse);
    });

    test('cancelPendingStart() sets status to disconnected', () {
      service.beginNegotiation();
      service.cancelPendingStart();
      expect(service.status, VpnStatus.disconnected);
      expect(service.error, isNull);
      expect(service.clientIp, isNull);
      expect(service.serverIp, isNull);
      expect(service.isConnected, isFalse);
      expect(service.isActive, isFalse);
    });

    test('isConnected is true only when status is connected', () {
      // Default state
      expect(service.isConnected, isFalse);

      // Connecting state
      service.beginNegotiation();
      expect(service.isConnected, isFalse);

      // Error state
      service.failNegotiation('err');
      expect(service.isConnected, isFalse);
    });

    test('isActive is true when connecting or connected', () {
      expect(service.isActive, isFalse);

      service.beginNegotiation();
      expect(service.isActive, isTrue);

      service.cancelPendingStart();
      expect(service.isActive, isFalse);
    });

    test('listener is notified on beginNegotiation()', () {
      int callCount = 0;
      service.addListener(() => callCount++);
      service.beginNegotiation();
      expect(callCount, 1);
    });

    test('listener is notified on failNegotiation()', () {
      int callCount = 0;
      service.beginNegotiation();
      service.addListener(() => callCount++);
      service.failNegotiation('oops');
      expect(callCount, 1);
    });

    test('listener is notified on cancelPendingStart()', () {
      int callCount = 0;
      service.beginNegotiation();
      service.addListener(() => callCount++);
      service.cancelPendingStart();
      expect(callCount, 1);
    });

    test('multiple state transitions notify correctly', () {
      final List<VpnStatus> observed = [];
      service.addListener(() => observed.add(service.status));

      service.beginNegotiation();
      service.failNegotiation('first error');
      service.beginNegotiation();
      service.cancelPendingStart();

      expect(observed, [
        VpnStatus.connecting,
        VpnStatus.error,
        VpnStatus.connecting,
        VpnStatus.disconnected,
      ]);
    });

    test('beginNegotiation() clears previous error', () {
      service.beginNegotiation();
      service.failNegotiation('something broke');
      expect(service.error, isNotNull);

      service.beginNegotiation();
      expect(service.error, isNull);
      expect(service.status, VpnStatus.connecting);
    });

    test('cancelPendingStart() clears previous error', () {
      service.beginNegotiation();
      service.failNegotiation('broken');
      // Simulate re-entering connecting then cancelling
      service.beginNegotiation();
      service.cancelPendingStart();
      expect(service.error, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // VpnConfig.toMap() – additional optional-field combinations
  // ---------------------------------------------------------------------------
  group('VpnConfig.toMap() additional combinations', () {
    test('toMap() with only presharedKey set', () {
      const config = VpnConfig(
        privateKey: 'pk',
        peerPublicKey: 'ppk',
        presharedKey: 'psk-only',
        serverAddr: '1.2.3.4',
        serverPort: 51820,
        clientIp: '10.0.0.2',
        serverIp: '10.0.0.1',
      );
      final map = config.toMap();
      expect(map['presharedKey'], 'psk-only');
      expect(map.containsKey('localPort'), isFalse);
      expect(map.containsKey('netcheckHost'), isFalse);
      expect(map.containsKey('netcheckPort'), isFalse);
      expect(map.containsKey('directCandidates'), isFalse);
    });

    test('toMap() with localPort, netcheckHost, netcheckPort set', () {
      const config = VpnConfig(
        privateKey: 'pk',
        peerPublicKey: 'ppk',
        serverAddr: '1.2.3.4',
        serverPort: 51820,
        clientIp: '10.0.0.2',
        serverIp: '10.0.0.1',
        localPort: 9999,
        netcheckHost: 'nc.example.com',
        netcheckPort: 4000,
      );
      final map = config.toMap();
      expect(map['localPort'], 9999);
      expect(map['netcheckHost'], 'nc.example.com');
      expect(map['netcheckPort'], 4000);
    });

    test('toMap() directCandidates with all fields', () {
      const config = VpnConfig(
        privateKey: 'pk',
        peerPublicKey: 'ppk',
        serverAddr: '1.2.3.4',
        serverPort: 51820,
        clientIp: '10.0.0.2',
        serverIp: '10.0.0.1',
        directCandidates: [
          {'host': '192.168.1.5', 'port': 51821, 'priority': 1, 'type': 'lan'},
          {
            'host': '203.0.113.5',
            'port': 51822,
            'priority': 2,
            'type': 'wan',
            'nat': 'symmetric',
          },
        ],
      );
      final map = config.toMap();
      final candidates = map['directCandidates'] as List<Map<String, dynamic>>;
      expect(candidates, hasLength(2));
      expect(candidates[0]['priority'], 1);
      expect(candidates[0]['type'], 'lan');
      expect(candidates[1]['nat'], 'symmetric');
    });

    test('toMap() dns and dnsMatchDomains serialization', () {
      const config = VpnConfig(
        privateKey: 'pk',
        peerPublicKey: 'ppk',
        serverAddr: '1.2.3.4',
        serverPort: 51820,
        clientIp: '10.0.0.2',
        serverIp: '10.0.0.1',
        dns: ['1.1.1.1', '9.9.9.9', '8.8.8.8'],
        dnsMatchDomains: ['corp.example.com', 'internal.test'],
      );
      final map = config.toMap();
      expect(map['dns'], ['1.1.1.1', '9.9.9.9', '8.8.8.8']);
      expect(map['dnsMatchDomains'], ['corp.example.com', 'internal.test']);
    });

    test('toMap() internalRoutes serialization', () {
      const config = VpnConfig(
        privateKey: 'pk',
        peerPublicKey: 'ppk',
        serverAddr: '1.2.3.4',
        serverPort: 51820,
        clientIp: '10.0.0.2',
        serverIp: '10.0.0.1',
        internalRoutes: ['192.168.0.0/16', '172.16.0.0/12', '10.0.0.0/8'],
      );
      final map = config.toMap();
      expect(map['internalRoutes'], [
        '192.168.0.0/16',
        '172.16.0.0/12',
        '10.0.0.0/8',
      ]);
    });
  });

  // ---------------------------------------------------------------------------
  // VpnService with mocked MethodChannel – _applyStatusPayload, start, stop,
  // generateKeypair, getStatus
  // ---------------------------------------------------------------------------
  group('VpnService with mocked MethodChannel', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late VpnService service;
    // Captured calls for assertions.
    final List<MethodCall> methodCalls = [];
    // Configurable return value for the mock.
    Map<String, dynamic>? mockGetStatusResult;
    Map<String, dynamic>? mockGenerateKeypairResult;
    bool mockStartShouldThrow = false;
    bool mockStopShouldThrow = false;

    const channel = MethodChannel('com.blackhole.voyager/vpn');

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      methodCalls.clear();
      mockGetStatusResult = null;
      mockGenerateKeypairResult = null;
      mockStartShouldThrow = false;
      mockStopShouldThrow = false;

      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            methodCalls.add(call);
            if (call.method == 'getStatus') {
              return mockGetStatusResult;
            } else if (call.method == 'generateKeypair') {
              return mockGenerateKeypairResult;
            } else if (call.method == 'start') {
              if (mockStartShouldThrow) {
                throw PlatformException(
                  code: 'START_FAILED',
                  message: 'mock start error',
                );
              }
              return null;
            } else if (call.method == 'stop') {
              if (mockStopShouldThrow) {
                throw PlatformException(
                  code: 'STOP_FAILED',
                  message: 'mock stop error',
                );
              }
              return null;
            }
            return null;
          });

      service = VpnService();
    });

    tearDown(() {
      service.dispose();
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    // -----------------------------------------------------------------------
    // _applyStatusPayload via refreshStatus
    // -----------------------------------------------------------------------
    group('_applyStatusPayload via refreshStatus', () {
      test('connected status with clientIp and serverIp', () async {
        mockGetStatusResult = {
          'status': 'connected',
          'connectionMode': 'direct',
          'clientIp': '10.13.37.2',
          'serverIp': '10.13.37.1',
          'lanPort': 9527,
        };

        await service.refreshStatus();

        expect(service.status, VpnStatus.connected);
        expect(service.connectionMode, VpnConnectionMode.direct);
        expect(service.clientIp, '10.13.37.2');
        expect(service.serverIp, '10.13.37.1');
        expect(service.lanPort, 9527);
        expect(service.isConnected, isTrue);
        expect(service.isActive, isTrue);
      });

      test('relay wire name maps to unknown connection mode', () async {
        mockGetStatusResult = {
          'status': 'connected',
          'connectionMode': 'relay',
          'clientIp': '10.0.0.2',
          'serverIp': '10.0.0.1',
        };

        await service.refreshStatus();

        expect(service.connectionMode, VpnConnectionMode.unknown);
      });

      test('unknown connection mode when missing', () async {
        mockGetStatusResult = {
          'status': 'connected',
          'clientIp': '10.0.0.2',
          'serverIp': '10.0.0.1',
        };

        await service.refreshStatus();

        expect(service.connectionMode, VpnConnectionMode.unknown);
      });

      test('packet counter extraction', () async {
        mockGetStatusResult = {
          'status': 'connected',
          'tunPacketsIn': 100,
          'tunPacketsOut': 200,
          'udpPacketsIn': 30,
          'udpPacketsOut': 40,
          'wgTxBytes': 1024,
          'wgRxBytes': 2048,
          'timeSinceLastHandshakeSecs': 4,
        };

        await service.refreshStatus();

        expect(service.tunPacketsIn, 100);
        expect(service.tunPacketsOut, 200);
        expect(service.udpPacketsIn, 30);
        expect(service.udpPacketsOut, 40);
        expect(service.wgTxBytes, 1024);
        expect(service.wgRxBytes, 2048);
        expect(service.timeSinceLastHandshakeSecs, 4);
      });

      test('direct session fields extraction', () async {
        mockGetStatusResult = {
          'status': 'connected',
          'connectionMode': 'direct',
          'plannedDirectCandidates': [
            {'host': '192.168.1.5', 'port': 51821},
            {'host': '10.0.0.5', 'port': 51822},
          ],
          'observedCandidates': [
            {'host': '203.0.113.1', 'port': 4500},
          ],
          'activeDirectCandidateIndex': 1,
          'activeDirectCandidate': {'host': '10.0.0.5', 'port': 51822},
          'directSessionState': 'established',
          'directSessionViable': true,
          'directSessionReady': true,
          'timeSinceLastHandshakeSecs': 3,
          'pendingDirectQueueDepth': 0,
          'directWriteAttempts': 42,
          'directWriteErrors': 3,
          'directHandshakePacketsPrepared': 10,
          'directHandshakePacketsSuppressed': 2,
          'directProbeWriteAttempts': 5,
          'lastDirectWriteLabel': 'data',
          'lastDirectWriteError': 'timeout',
        };

        await service.refreshStatus();

        expect(service.plannedDirectCandidates, hasLength(2));
        expect(service.plannedDirectCandidates[0]['host'], '192.168.1.5');
        expect(service.observedCandidates, hasLength(1));
        expect(service.activeDirectCandidateIndex, 1);
        expect(service.activeDirectCandidate, isNotNull);
        expect(service.activeDirectCandidate!['host'], '10.0.0.5');
        expect(service.directSessionState, 'established');
        expect(service.directSessionViable, isTrue);
        expect(service.directSessionReady, isTrue);
        expect(service.timeSinceLastHandshakeSecs, 3);
        expect(service.pendingDirectQueueDepth, 0);
        expect(service.directWriteAttempts, 42);
        expect(service.directWriteErrors, 3);
        expect(service.directHandshakePacketsPrepared, 10);
        expect(service.directHandshakePacketsSuppressed, 2);
        expect(service.directProbeWriteAttempts, 5);
        expect(service.lastDirectWriteLabel, 'data');
        expect(service.lastDirectWriteError, 'timeout');
      });

      test('error payload sets status and error message', () async {
        mockGetStatusResult = {'status': 'error', 'error': 'tunnel died'};

        await service.refreshStatus();

        expect(service.status, VpnStatus.error);
        expect(service.error, 'tunnel died');
        expect(service.isActive, isFalse);
      });

      test('disconnected payload', () async {
        mockGetStatusResult = {'status': 'disconnected'};

        await service.refreshStatus();

        expect(service.status, VpnStatus.disconnected);
        expect(service.isActive, isFalse);
      });

      test('null result from getStatus does not crash', () async {
        mockGetStatusResult = null;

        await service.refreshStatus();

        // Status should remain at the default.
        expect(service.status, VpnStatus.disconnected);
      });

      test('notifies listeners on refreshStatus', () async {
        int callCount = 0;
        service.addListener(() => callCount++);

        mockGetStatusResult = {
          'status': 'connected',
          'clientIp': '10.0.0.2',
          'serverIp': '10.0.0.1',
        };

        await service.refreshStatus();

        expect(callCount, 1);
      });

      test('stale payload during negotiation is ignored', () async {
        // Start negotiation – this sets _negotiationStartedAt.
        service.beginNegotiation();

        // Provide a payload with a timestamp BEFORE the negotiation started
        // and a status that should be filtered (connecting or connected).
        final staleTime =
            DateTime.now()
                .toUtc()
                .subtract(const Duration(seconds: 10))
                .toIso8601String();

        mockGetStatusResult = {
          'status': 'connected',
          'timestamp': staleTime,
          'clientIp': '10.0.0.99',
          'serverIp': '10.0.0.1',
        };

        await service.refreshStatus();

        // The stale payload should be ignored so status stays at connecting.
        expect(service.status, VpnStatus.connecting);
        expect(service.clientIp, isNull);
      });

      test('non-stale payload during negotiation is applied', () async {
        service.beginNegotiation();

        final freshTime =
            DateTime.now()
                .toUtc()
                .add(const Duration(seconds: 5))
                .toIso8601String();

        mockGetStatusResult = {
          'status': 'connected',
          'timestamp': freshTime,
          'clientIp': '10.0.0.2',
          'serverIp': '10.0.0.1',
        };

        await service.refreshStatus();

        expect(service.status, VpnStatus.connected);
        expect(service.clientIp, '10.0.0.2');
      });

      test('disconnected payload during negotiation is not filtered', () async {
        service.beginNegotiation();

        final staleTime =
            DateTime.now()
                .toUtc()
                .subtract(const Duration(seconds: 10))
                .toIso8601String();

        mockGetStatusResult = {
          'status': 'disconnected',
          'timestamp': staleTime,
        };

        await service.refreshStatus();

        // 'disconnected' is not filtered even with stale timestamp.
        expect(service.status, VpnStatus.disconnected);
      });

      test('error payload during negotiation is not filtered', () async {
        service.beginNegotiation();

        final staleTime =
            DateTime.now()
                .toUtc()
                .subtract(const Duration(seconds: 10))
                .toIso8601String();

        mockGetStatusResult = {
          'status': 'error',
          'timestamp': staleTime,
          'error': 'tunnel crash',
        };

        await service.refreshStatus();

        // 'error' is not filtered even with stale timestamp.
        expect(service.status, VpnStatus.error);
        expect(service.error, 'tunnel crash');
      });

      test('payload without timestamp is never stale', () async {
        service.beginNegotiation();

        mockGetStatusResult = {
          'status': 'connected',
          'clientIp': '10.0.0.2',
          'serverIp': '10.0.0.1',
        };

        await service.refreshStatus();

        // No timestamp means payloadTimestamp is null, stale check fails,
        // so payload is applied.
        expect(service.status, VpnStatus.connected);
      });

      test('connected payload clears negotiationStartedAt', () async {
        service.beginNegotiation();

        final freshTime =
            DateTime.now()
                .toUtc()
                .add(const Duration(seconds: 5))
                .toIso8601String();

        mockGetStatusResult = {
          'status': 'connected',
          'timestamp': freshTime,
          'clientIp': '10.0.0.2',
          'serverIp': '10.0.0.1',
        };

        await service.refreshStatus();
        expect(service.status, VpnStatus.connected);

        // Now a second payload that would have been stale under the old
        // negotiation time should be applied because negotiationStartedAt
        // was cleared by the connected payload.
        final oldTime =
            DateTime.now()
                .toUtc()
                .subtract(const Duration(seconds: 60))
                .toIso8601String();

        mockGetStatusResult = {
          'status': 'connected',
          'timestamp': oldTime,
          'clientIp': '10.0.0.3',
          'serverIp': '10.0.0.1',
        };

        await service.refreshStatus();
        expect(service.clientIp, '10.0.0.3');
      });

      test('missing list fields default to empty lists', () async {
        mockGetStatusResult = {'status': 'connected'};

        await service.refreshStatus();

        expect(service.plannedDirectCandidates, isEmpty);
        expect(service.observedCandidates, isEmpty);
      });

      test('null numeric fields remain null', () async {
        mockGetStatusResult = {'status': 'connecting'};

        await service.refreshStatus();

        expect(service.tunPacketsIn, isNull);
        expect(service.tunPacketsOut, isNull);
        expect(service.udpPacketsIn, isNull);
        expect(service.udpPacketsOut, isNull);
        expect(service.wgTxBytes, isNull);
        expect(service.wgRxBytes, isNull);
        expect(service.timeSinceLastHandshakeSecs, isNull);
        expect(service.activeDirectCandidateIndex, isNull);
        expect(service.pendingDirectQueueDepth, isNull);
        expect(service.directWriteAttempts, isNull);
        expect(service.directWriteErrors, isNull);
        expect(service.directHandshakePacketsPrepared, isNull);
        expect(service.directHandshakePacketsSuppressed, isNull);
        expect(service.directProbeWriteAttempts, isNull);
      });

      test('null string fields remain null', () async {
        mockGetStatusResult = {'status': 'connecting'};

        await service.refreshStatus();

        expect(service.clientIp, isNull);
        expect(service.serverIp, isNull);
        expect(service.directSessionState, isNull);
        expect(service.directSessionViable, isNull);
        expect(service.directSessionReady, isNull);
        expect(service.timeSinceLastHandshakeSecs, isNull);
        expect(service.lastDirectWriteLabel, isNull);
        expect(service.lastDirectWriteError, isNull);
        expect(service.error, isNull);
      });
    });

    // -----------------------------------------------------------------------
    // start()
    // -----------------------------------------------------------------------
    group('start()', () {
      const testConfig = VpnConfig(
        privateKey: 'test-priv',
        peerPublicKey: 'test-pub',
        presharedKey: 'test-psk',
        serverAddr: '1.2.3.4',
        serverPort: 51820,
        clientIp: '10.13.37.2',
        serverIp: '10.13.37.1',
        localPort: 12345,
        netcheckHost: 'nc.example.com',
        netcheckPort: 3478,
      );

      test('sends correct arguments to method channel', () async {
        mockGetStatusResult = {'status': 'connecting'};

        await service.start(testConfig);

        // The first call should be 'start', the second 'getStatus' from
        // refreshStatus.
        expect(methodCalls.first.method, 'start');
        final args = methodCalls.first.arguments as Map;
        expect(args['privateKey'], 'test-priv');
        expect(args['peerPublicKey'], 'test-pub');
        expect(args['presharedKey'], 'test-psk');
        expect(args['serverAddr'], '1.2.3.4');
        expect(args['serverPort'], 51820);
        expect(args['clientIp'], '10.13.37.2');
        expect(args['serverIp'], '10.13.37.1');
        expect(args['localPort'], 12345);
        expect(args['netcheckHost'], 'nc.example.com');
        expect(args['netcheckPort'], 3478);
      });

      test('sets status to connecting and updates IPs', () async {
        mockGetStatusResult = {
          'status': 'connecting',
          'clientIp': '10.13.37.2',
          'serverIp': '10.13.37.1',
          'lanPort': 9527,
        };

        final statuses = <VpnStatus>[];
        service.addListener(() => statuses.add(service.status));

        await service.start(testConfig);

        // First notification is connecting (from start before invokeMethod),
        // second is from refreshStatus.
        expect(statuses.first, VpnStatus.connecting);
        expect(service.clientIp, '10.13.37.2');
        expect(service.serverIp, '10.13.37.1');
        expect(service.lanPort, 9527);
      });

      test('calls refreshStatus after invokeMethod', () async {
        mockGetStatusResult = {
          'status': 'connected',
          'clientIp': '10.13.37.2',
          'serverIp': '10.13.37.1',
        };

        await service.start(testConfig);

        final methods = methodCalls.map((c) => c.method).toList();
        expect(methods, contains('start'));
        expect(methods, contains('getStatus'));
        expect(methods, isNot(contains('setActiveCandidate')));
        // getStatus should come after start.
        expect(
          methods.indexOf('start'),
          lessThan(methods.indexOf('getStatus')),
        );
      });

      test('clears packet counters on start', () async {
        // First establish some state.
        mockGetStatusResult = {
          'status': 'connected',
          'tunPacketsIn': 999,
          'tunPacketsOut': 888,
        };
        await service.refreshStatus();
        expect(service.tunPacketsIn, 999);

        // Now start a new connection.
        mockGetStatusResult = {'status': 'connecting'};
        await service.start(testConfig);

        // After the start call (before refreshStatus applies), counters
        // should have been cleared. The refreshStatus with 'connecting'
        // doesn't set them either.
        expect(service.tunPacketsIn, isNull);
        expect(service.tunPacketsOut, isNull);
      });

      test('PlatformException sets error status and rethrows', () async {
        mockStartShouldThrow = true;

        expect(
          () => service.start(testConfig),
          throwsA(isA<PlatformException>()),
        );

        // Allow the future to complete.
        await Future<void>.delayed(Duration.zero);

        expect(service.status, VpnStatus.error);
        expect(service.error, 'mock start error');
      });
    });

    // -----------------------------------------------------------------------
    // stop()
    // -----------------------------------------------------------------------
    group('stop()', () {
      test('sets status to disconnecting and calls method channel', () async {
        mockGetStatusResult = {'status': 'disconnected'};

        final statuses = <VpnStatus>[];
        service.addListener(() => statuses.add(service.status));

        await service.stop();

        expect(statuses.first, VpnStatus.disconnecting);
        final methods = methodCalls.map((c) => c.method).toList();
        expect(methods, contains('stop'));
      });

      test('calls refreshStatus after stop', () async {
        mockGetStatusResult = {'status': 'disconnected'};

        await service.stop();

        final methods = methodCalls.map((c) => c.method).toList();
        expect(methods.indexOf('stop'), lessThan(methods.indexOf('getStatus')));
      });

      test('PlatformException sets error and rethrows', () async {
        mockStopShouldThrow = true;

        expect(() => service.stop(), throwsA(isA<PlatformException>()));

        await Future<void>.delayed(Duration.zero);

        expect(service.error, 'mock stop error');
      });
    });

    // -----------------------------------------------------------------------
    // generateKeypair()
    // -----------------------------------------------------------------------
    group('generateKeypair()', () {
      test('returns keys from native layer', () async {
        mockGenerateKeypairResult = {
          'privateKey': 'base64-private-key',
          'publicKey': 'base64-public-key',
        };

        final result = await service.generateKeypair();

        expect(result['privateKey'], 'base64-private-key');
        expect(result['publicKey'], 'base64-public-key');
        expect(methodCalls.any((c) => c.method == 'generateKeypair'), isTrue);
      });

      test('returns empty strings when native returns null', () async {
        mockGenerateKeypairResult = null;

        final result = await service.generateKeypair();

        expect(result['privateKey'], '');
        expect(result['publicKey'], '');
      });

      test('returns empty strings for missing keys', () async {
        mockGenerateKeypairResult = <String, dynamic>{};

        final result = await service.generateKeypair();

        expect(result['privateKey'], '');
        expect(result['publicKey'], '');
      });
    });

    // -----------------------------------------------------------------------
    // getStatus()
    // -----------------------------------------------------------------------
    group('getStatus()', () {
      test('returns current status after refresh', () async {
        mockGetStatusResult = {
          'status': 'connected',
          'clientIp': '10.0.0.2',
          'serverIp': '10.0.0.1',
        };

        final status = await service.getStatus();

        expect(status, VpnStatus.connected);
      });

      test('returns disconnected when native returns null', () async {
        mockGetStatusResult = null;

        final status = await service.getStatus();

        expect(status, VpnStatus.disconnected);
      });

      test('returns error status', () async {
        mockGetStatusResult = {'status': 'error', 'error': 'broken tunnel'};

        final status = await service.getStatus();

        expect(status, VpnStatus.error);
        expect(service.error, 'broken tunnel');
      });
    });

    // -----------------------------------------------------------------------
    // dispose()
    // -----------------------------------------------------------------------
    test('dispose does not throw', () {
      final s = VpnService();
      expect(() => s.dispose(), returnsNormally);
    });
  });

  // ---------------------------------------------------------------------------
  // VpnService on unsupported platform (non-iOS)
  // ---------------------------------------------------------------------------
  group('planUserspaceDirectCandidates', () {
    test('keeps fallback when configured candidates are lan only', () {
      final planned = planUserspaceDirectCandidates(
        configured: [
          {
            'addr': '192.168.1.219',
            'port': 51820,
            'scope': 'lan',
            'priority': 250,
            'source': 'local_interface:en1',
          },
          {
            'addr': '100.65.238.106',
            'port': 51820,
            'scope': 'lan',
            'priority': 250,
            'source': 'local_interface:utun7',
          },
        ],
        fallbackAddr: '14.153.180.50',
        fallbackPort: 51820,
      );

      expect(planned.map((c) => '${c['addr']}:${c['port']}').toList(), [
        '192.168.1.219:51820',
        '100.65.238.106:51820',
        '14.153.180.50:51820',
      ]);
      expect(planned.last['scope'], 'legacy');
    });

    test('does not duplicate configured endpoint when fallback matches', () {
      final planned = planUserspaceDirectCandidates(
        configured: [
          {
            'addr': '14.153.180.50',
            'port': 51820,
            'scope': 'public_observed',
            'priority': 180,
            'source': 'wormhole_observed',
          },
        ],
        fallbackAddr: '14.153.180.50',
        fallbackPort: 51820,
      );

      expect(planned, hasLength(1));
      expect(planned.first['scope'], 'public_observed');
    });
  });

  group('VpnService userspace candidate rotation', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late VpnService service;
    final List<MethodCall> methodCalls = [];
    const channel = MethodChannel('com.blackhole.voyager/vpn');

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      methodCalls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
            methodCalls.add(call);
            if (call.method == 'getStatus') {
              return {'status': 'connecting'};
            }
            return null;
          });
      service = VpnService();
    });

    tearDown(() {
      service.dispose();
      debugDefaultTargetPlatformOverride = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('start sets the first candidate on android', () async {
      await service.start(
        const VpnConfig(
          privateKey: 'pk',
          peerPublicKey: 'ppk',
          serverAddr: '1.2.3.4',
          serverPort: 51820,
          clientIp: '10.13.37.2',
          serverIp: '10.13.37.1',
          directCandidates: [
            {'addr': '192.168.1.5', 'port': 51821, 'priority': 250},
            {'addr': '203.0.113.5', 'port': 51822, 'priority': 100},
          ],
        ),
      );

      final methods = methodCalls.map((c) => c.method).toList();
      expect(methods.first, 'start');
      expect(methods, contains('setActiveCandidate'));
      final candidateCall = methodCalls.firstWhere(
        (call) => call.method == 'setActiveCandidate',
      );
      final args = candidateCall.arguments as Map;
      expect(args['addr'], '192.168.1.5');
      expect(args['port'], 51821);
    });

    test('setActiveCandidate is a no-op on iOS', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      await service.setActiveCandidate(addr: '192.168.1.5', port: 51821);
      expect(
        methodCalls.where((call) => call.method == 'setActiveCandidate'),
        isEmpty,
      );
    });
  });

  group('VpnService on unsupported platform', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    late VpnService service;

    setUp(() {
      debugDefaultTargetPlatformOverride = TargetPlatform.linux;
      service = VpnService();
    });

    tearDown(() {
      service.dispose();
      debugDefaultTargetPlatformOverride = null;
    });

    test('beginNegotiation is no-op on unsupported platform', () {
      int callCount = 0;
      service.addListener(() => callCount++);
      service.beginNegotiation();
      // No listener notification because isSupportedPlatform is false.
      expect(callCount, 0);
      expect(service.status, VpnStatus.disconnected);
    });

    test('failNegotiation is no-op on unsupported platform', () {
      service.failNegotiation('err');
      expect(service.status, VpnStatus.disconnected);
      expect(service.error, isNull);
    });

    test('cancelPendingStart is no-op on unsupported platform', () {
      service.cancelPendingStart();
      expect(service.status, VpnStatus.disconnected);
    });

    test('refreshStatus is no-op on unsupported platform', () async {
      await service.refreshStatus();
      expect(service.status, VpnStatus.disconnected);
    });

    test('start is no-op on unsupported platform', () async {
      const config = VpnConfig(
        privateKey: 'pk',
        peerPublicKey: 'ppk',
        serverAddr: '1.2.3.4',
        serverPort: 51820,
        clientIp: '10.0.0.2',
        serverIp: '10.0.0.1',
      );
      await service.start(config);
      expect(service.status, VpnStatus.disconnected);
    });

    test('stop is no-op on unsupported platform', () async {
      await service.stop();
      expect(service.status, VpnStatus.disconnected);
    });

    test('initialize is no-op on unsupported platform', () {
      // Should not throw or set up subscriptions.
      service.initialize();
      expect(service.status, VpnStatus.disconnected);
    });
  });
}
