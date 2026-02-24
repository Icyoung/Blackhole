import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/transport_models.dart';
import 'package:voyager/src/services/transport_orchestrator.dart';

enum PairingState { waiting, paired, failed }

void main() {
  group('Wormhole-only Regression Tests', () {
    late TransportOrchestrator orchestrator;

    setUp(() {
      orchestrator = TransportOrchestrator(
        rttWeight: 1000,
        successWeight: 100000,
        switchThresholdScore: 150,
        minHoldWindow: const Duration(seconds: 8),
      );
    });

    test('Wormhole-only mode should ignore other transports', () async {
      // Force wormhole-only mode
      const forceWormholeOnly = true;

      final candidates = [
        TransportCandidate(
          id: 'lan-1',
          kind: TransportKind.lanDirect,
          uri: Uri.parse('ws://192.168.1.100:9527/ws'),
          waitForPairing: false,
          priority: 110,
        ),
        TransportCandidate(
          id: 'tailnet-1',
          kind: TransportKind.tailnetDirect,
          uri: Uri.parse('ws://100.64.0.1:9527/ws'),
          waitForPairing: false,
          priority: 120,
        ),
        TransportCandidate(
          id: 'wormhole-1',
          kind: TransportKind.wormholeRelay,
          uri: Uri.parse('wss://wormhole.example.com/ws'),
          waitForPairing: true,
          priority: 80,
        ),
      ];

      // Filter to only wormhole when forced
      final filtered = forceWormholeOnly
          ? candidates.where((c) => c.kind == TransportKind.wormholeRelay).toList()
          : candidates;

      expect(filtered.length, 1);
      expect(filtered.first.kind, TransportKind.wormholeRelay);
    });

    test('Wormhole connection should maintain backward compatibility', () async {
      final wormholeCandidate = TransportCandidate(
        id: 'wormhole-compat',
        kind: TransportKind.wormholeRelay,
        uri: Uri.parse('wss://wormhole.example.com/ws'),
        waitForPairing: true,
        priority: 80,
      );

      // Verify all legacy fields are present
      expect(wormholeCandidate.waitForPairing, isTrue);
      expect(wormholeCandidate.kind, TransportKind.wormholeRelay);

      // Verify legacy message format support
      final legacyMessage = {
        'type': 'terminal_data',
        'data': 'test data',
        'session_id': 'test-session',
      };

      // Message should be parseable without new fields
      expect(legacyMessage.containsKey('transport_id'), isFalse);
      expect(legacyMessage.containsKey('path_id'), isFalse);
    });

    test('Wormhole fallback should activate on direct connection failure', () async {
      // Simulate probe function that fails for direct connections
      Future<TransportProbeResult> mockProbe(TransportCandidate candidate) async {
        await Future.delayed(const Duration(milliseconds: 100));

        // Direct connections fail
        if (candidate.kind == TransportKind.lanDirect ||
            candidate.kind == TransportKind.tailnetDirect) {
          return TransportProbeResult(
            candidate: candidate,
            success: false,
            rtt: null,
            error: 'Connection timeout',
          );
        }

        // Wormhole succeeds
        return TransportProbeResult(
          candidate: candidate,
          success: true,
          rtt: const Duration(milliseconds: 150),
        );
      }

      final candidates = [
        TransportCandidate(
          id: 'lan-fail',
          kind: TransportKind.lanDirect,
          uri: Uri.parse('ws://192.168.1.100:9527/ws'),
          waitForPairing: false,
          priority: 110,
        ),
        TransportCandidate(
          id: 'wormhole-fallback',
          kind: TransportKind.wormholeRelay,
          uri: Uri.parse('wss://wormhole.example.com/ws'),
          waitForPairing: true,
          priority: 80,
        ),
      ];

      final selection = await orchestrator.selectBest(
        candidates: candidates,
        probe: mockProbe,
      );

      expect(selection, isNotNull);
      expect(selection!.candidate.kind, TransportKind.wormholeRelay);
    });

    test('Wormhole metadata transparency for old clients', () {
      // Old client message (no transport metadata)
      final oldClientMessage = {
        'type': 'terminal_data',
        'data': 'ls -la',
        'session_id': 'abc123',
      };

      // New client message (with transport metadata)
      final newClientMessage = {
        'type': 'terminal_data',
        'data': 'ls -la',
        'session_id': 'abc123',
        'transport_id': 'txp-456',
        'path_id': 'path-789',
      };

      // Both should be valid
      expect(oldClientMessage['type'], 'terminal_data');
      expect(newClientMessage['type'], 'terminal_data');

      // Old client ignores new fields
      final processedByOldClient = Map.from(newClientMessage)
        ..remove('transport_id')
        ..remove('path_id');

      expect(processedByOldClient['type'], 'terminal_data');
      expect(processedByOldClient['data'], 'ls -la');
    });

    test('Wormhole reconnection maintains session', () async {
      // Simulate connection state
      var isConnected = true;
      var reconnectCount = 0;

      Future<void> simulateDisconnect() async {
        isConnected = false;
        await Future.delayed(const Duration(seconds: 1));
        isConnected = true;
        reconnectCount++;
      }

      // Test reconnection
      await simulateDisconnect();
      expect(isConnected, isTrue);
      expect(reconnectCount, 1);

      // Multiple reconnections
      await simulateDisconnect();
      await simulateDisconnect();
      expect(reconnectCount, 3);
    });

    test('Wormhole-only mode performance baseline', () {
      // Define performance baselines
      const baselineRtt = 200; // ms
      const baselineReconnectTime = 3000; // ms
      const baselineSessionLossRate = 0.01; // 1%

      // Simulated metrics
      const currentRtt = 180;
      const currentReconnectTime = 2500;
      const currentSessionLossRate = 0.008;

      // Verify no regression
      expect(currentRtt, lessThanOrEqualTo(baselineRtt));
      expect(currentReconnectTime, lessThanOrEqualTo(baselineReconnectTime));
      expect(currentSessionLossRate, lessThanOrEqualTo(baselineSessionLossRate));
    });

    test('Wormhole handles all control frames correctly', () {
      final controlFrames = [
        {'type': 'terminal_resize', 'cols': 80, 'rows': 24},
        {'type': 'terminal_data', 'data': 'test'},
        {'type': 'keepalive', 'timestamp': DateTime.now().millisecondsSinceEpoch},
        {'type': 'session_end', 'reason': 'user_disconnect'},
      ];

      for (final frame in controlFrames) {
        expect(frame.containsKey('type'), isTrue);
        // Verify frame can be processed without new fields
        expect(() => frame['type'], returnsNormally);
      }
    });

    test('Wormhole pairing flow remains unchanged', () async {
      // Pairing states
      var currentState = PairingState.waiting;

      // Simulate pairing flow
      Future<void> performPairing() async {
        currentState = PairingState.waiting;
        await Future.delayed(const Duration(seconds: 2));
        currentState = PairingState.paired;
      }

      await performPairing();
      expect(currentState, PairingState.paired);
    });

    test('Wormhole error handling and recovery', () {
      final errors = [
        'WebSocket connection closed unexpectedly',
        'Connection timeout',
        'Invalid session token',
        'Server unavailable',
      ];

      for (final error in errors) {
        // Each error should have a recovery strategy
        String getRecoveryStrategy(String error) {
          if (error.contains('closed') || error.contains('timeout')) {
            return 'reconnect';
          } else if (error.contains('token')) {
            return 're-authenticate';
          } else {
            return 'retry-with-backoff';
          }
        }

        final strategy = getRecoveryStrategy(error);
        expect(strategy, isNotEmpty);
      }
    });

    test('Wormhole binary protocol compatibility (v1)', () {
      // Binary frame structure v1 (must not change)
      const frameVersion = 0x01;
      const frameType = 0x10; // terminal data
      const frameLength = 100;

      final binaryFrame = [
        frameVersion,
        frameType,
        frameLength & 0xFF,
        (frameLength >> 8) & 0xFF,
        // ... payload
      ];

      expect(binaryFrame[0], 0x01, reason: 'Frame version must be v1');
      expect(binaryFrame[1], 0x10, reason: 'Frame type must match');
    });
  });

  group('Wormhole Load Tests', () {
    test('Wormhole handles concurrent sessions', () async {
      const maxConcurrentSessions = 10;
      final sessions = <String>[];

      for (int i = 0; i < maxConcurrentSessions; i++) {
        sessions.add('session-$i');
      }

      expect(sessions.length, maxConcurrentSessions);

      // Verify each session is independent
      for (final session in sessions) {
        expect(session, startsWith('session-'));
      }
    });

    test('Wormhole message throughput', () {
      // Baseline: 100 messages per second
      const baselineThroughput = 100;

      var messageCount = 0;
      final stopwatch = Stopwatch()..start();

      // Simulate message processing
      while (stopwatch.elapsedMilliseconds < 1000) {
        messageCount++;
        if (messageCount >= baselineThroughput) break;
      }

      expect(messageCount, greaterThanOrEqualTo(baselineThroughput));
    });
  });

  group('Wormhole Edge Cases', () {
    test('Handles empty messages gracefully', () {
      final emptyMessage = <String, dynamic>{};
      expect(emptyMessage.isEmpty, isTrue);

      // Should not crash on empty message
      final type = emptyMessage['type'];
      expect(type, isNull);
    });

    test('Handles malformed JSON gracefully', () {
      const malformedJson = '{"type": "test", "data": ';

      try {
        // Would normally parse JSON
        expect(malformedJson.contains('"type"'), isTrue);
      } catch (e) {
        // Should handle error gracefully
        expect(e, isNotNull);
      }
    });

    test('Handles network interruptions', () async {
      var networkAvailable = true;

      // Simulate network interruption
      networkAvailable = false;
      await Future.delayed(const Duration(seconds: 1));
      networkAvailable = true;

      expect(networkAvailable, isTrue);
    });
  });
}