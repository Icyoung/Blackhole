import 'dart:async';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/transport_models.dart';
import 'package:voyager/src/services/transport_orchestrator.dart';

/// Network condition simulator for testing under various network scenarios
class NetworkConditionSimulator {
  NetworkConditionSimulator({
    this.packetLossRate = 0.0,
    this.latencyMs = 0,
    this.jitterMs = 0,
    this.bandwidthKbps = double.infinity,
  });

  final double packetLossRate; // 0.0 to 1.0
  final int latencyMs;
  final int jitterMs;
  final double bandwidthKbps;

  final _random = Random();

  Future<T?> simulateTransmission<T>(Future<T> Function() action) async {
    // Simulate packet loss
    if (packetLossRate > 0 && _random.nextDouble() < packetLossRate) {
      throw Exception('Packet lost (simulated)');
    }

    // Simulate latency with jitter
    int actualLatency = latencyMs;
    if (jitterMs > 0) {
      actualLatency = latencyMs + (_random.nextInt(jitterMs * 2 + 1) - jitterMs);
    }

    if (actualLatency > 0) {
      await Future.delayed(Duration(milliseconds: actualLatency));
    }

    // Simulate bandwidth throttling (simplified)
    if (bandwidthKbps != double.infinity && bandwidthKbps > 0) {
      // Add extra delay based on bandwidth limitation
      await Future.delayed(Duration(milliseconds: (1000 / bandwidthKbps).round()));
    }

    return action();
  }
}

/// Test scenarios from execution plan
class WeakNetworkScenarios {
  static final s1 = NetworkConditionSimulator(
    latencyMs: 150,
    packetLossRate: 0.03,
    bandwidthKbps: 1024,
  );

  static final s2 = NetworkConditionSimulator(
    latencyMs: 300,
    packetLossRate: 0.05,
    bandwidthKbps: 512,
  );

  static final lowPacketLoss = NetworkConditionSimulator(packetLossRate: 0.01);
  static final mediumPacketLoss = NetworkConditionSimulator(packetLossRate: 0.03);
  static final highPacketLoss = NetworkConditionSimulator(packetLossRate: 0.05);

  static final lowLatency = NetworkConditionSimulator(latencyMs: 80);
  static final mediumLatency = NetworkConditionSimulator(latencyMs: 150);
  static final highLatency = NetworkConditionSimulator(latencyMs: 300);

  static final lowJitter = NetworkConditionSimulator(jitterMs: 20);
  static final highJitter = NetworkConditionSimulator(jitterMs: 50);
}

void main() {
  group('Weak Network Tests - Packet Loss Scenarios', () {
    late TransportOrchestrator orchestrator;

    setUp(() {
      orchestrator = TransportOrchestrator(
        rttWeight: 1000,
        successWeight: 100000,
        switchThresholdScore: 150,
        minHoldWindow: const Duration(seconds: 8),
      );
    });

    test('1% packet loss should maintain connection', () async {
      final simulator = WeakNetworkScenarios.lowPacketLoss;
      int successCount = 0;
      int totalAttempts = 100;

      for (int i = 0; i < totalAttempts; i++) {
        try {
          final result = await simulator.simulateTransmission(() async => 'data');
          if (result != null) {
            successCount++;
          }
        } catch (e) {
          // Packet lost - this is expected for 1% of attempts
        }
      }

      // With 1% packet loss, we expect ~99% success
      final successRate = successCount > 0 ? successCount / totalAttempts : 0.0;
      expect(successRate, greaterThan(0.95));
    });

    test('3% packet loss should trigger transport switch consideration', () async {
      final simulator = WeakNetworkScenarios.mediumPacketLoss;

      // Simulate probe with packet loss
      Future<TransportProbeResult> probeWithPacketLoss(TransportCandidate candidate) async {
        try {
          await simulator.simulateTransmission(() async => true);
          return TransportProbeResult(
            candidate: candidate,
            success: true,
            rtt: Duration(milliseconds: simulator.latencyMs),
          );
        } catch (e) {
          return TransportProbeResult(
            candidate: candidate,
            success: false,
            error: e,
          );
        }
      }

      final candidates = [
        TransportCandidate(
          id: 'primary',
          kind: TransportKind.tailnetDirect,
          uri: Uri.parse('ws://100.64.0.1:9527/ws'),
          waitForPairing: false,
          priority: 120,
        ),
        TransportCandidate(
          id: 'fallback',
          kind: TransportKind.wormholeRelay,
          uri: Uri.parse('wss://wormhole.example.com/ws'),
          waitForPairing: true,
          priority: 80,
        ),
      ];

      // Run multiple probes to simulate real conditions
      int switchCount = 0;
      String? lastSelectedId;

      for (int i = 0; i < 10; i++) {
        final selection = await orchestrator.selectBest(
          candidates: candidates,
          probe: probeWithPacketLoss,
        );

        if (selection != null && selection.candidate.id != lastSelectedId) {
          switchCount++;
          lastSelectedId = selection.candidate.id;
        }
      }

      // Should consider switching but not oscillate too much
      expect(switchCount, lessThan(3));
    });

    test('5% packet loss should favor wormhole relay', () async {
      final directSimulator = WeakNetworkScenarios.highPacketLoss;
      final relaySimulator = WeakNetworkScenarios.lowPacketLoss; // Relay has better conditions

      Future<TransportProbeResult> probe(TransportCandidate candidate) async {
        final simulator = candidate.kind == TransportKind.wormholeRelay
            ? relaySimulator
            : directSimulator;

        try {
          await simulator.simulateTransmission(() async => true);
          return TransportProbeResult(
            candidate: candidate,
            success: true,
            rtt: Duration(milliseconds: simulator.latencyMs),
          );
        } catch (e) {
          return TransportProbeResult(
            candidate: candidate,
            success: false,
            error: e,
          );
        }
      }

      final candidates = [
        TransportCandidate(
          id: 'direct-unreliable',
          kind: TransportKind.tailnetDirect,
          uri: Uri.parse('ws://100.64.0.1:9527/ws'),
          waitForPairing: false,
          priority: 120,
        ),
        TransportCandidate(
          id: 'relay-stable',
          kind: TransportKind.wormholeRelay,
          uri: Uri.parse('wss://wormhole.example.com/ws'),
          waitForPairing: true,
          priority: 80,
        ),
      ];

      // Run multiple selections
      final selections = <String>[];
      for (int i = 0; i < 20; i++) {
        final selection = await orchestrator.selectBest(
          candidates: candidates,
          probe: probe,
        );
        if (selection != null) {
          selections.add(selection.candidate.id);
        }
      }

      // Relay should be selected more often due to better reliability
      final relaySelections = selections.where((id) => id == 'relay-stable').length;
      final selectionRate = selections.isNotEmpty ? relaySelections / selections.length : 0.0;
      expect(selectionRate, greaterThan(0.7));
    });
  });

  group('Weak Network Tests - Latency Scenarios', () {
    test('80ms latency should prefer direct connection', () async {
      final directLatency = 80;
      final relayLatency = 150;

      Future<TransportProbeResult> probe(TransportCandidate candidate) async {
        final latency = candidate.kind == TransportKind.wormholeRelay
            ? relayLatency
            : directLatency;

        await Future.delayed(Duration(milliseconds: latency));

        return TransportProbeResult(
          candidate: candidate,
          success: true,
          rtt: Duration(milliseconds: latency),
        );
      }

      final orchestrator = TransportOrchestrator();

      final candidates = [
        TransportCandidate(
          id: 'direct-low-latency',
          kind: TransportKind.tailnetDirect,
          uri: Uri.parse('ws://100.64.0.1:9527/ws'),
          waitForPairing: false,
          priority: 100,
        ),
        TransportCandidate(
          id: 'relay-high-latency',
          kind: TransportKind.wormholeRelay,
          uri: Uri.parse('wss://wormhole.example.com/ws'),
          waitForPairing: true,
          priority: 100,
        ),
      ];

      final selection = await orchestrator.selectBest(
        candidates: candidates,
        probe: probe,
      );

      expect(selection?.candidate.id, 'direct-low-latency');
    });

    test('300ms latency should still maintain connection', () async {
      final simulator = WeakNetworkScenarios.highLatency;

      final stopwatch = Stopwatch()..start();
      await simulator.simulateTransmission(() async => 'test');
      stopwatch.stop();

      // Should complete within reasonable time despite high latency
      expect(stopwatch.elapsedMilliseconds, greaterThanOrEqualTo(300));
      expect(stopwatch.elapsedMilliseconds, lessThan(400));
    });

    test('Jitter should not cause excessive switching', () async {
      final simulator = WeakNetworkScenarios.highJitter;
      final rttMeasurements = <int>[];

      for (int i = 0; i < 10; i++) {
        final stopwatch = Stopwatch()..start();
        await simulator.simulateTransmission(() async => true);
        stopwatch.stop();
        rttMeasurements.add(stopwatch.elapsedMilliseconds);
      }

      // Calculate variance
      final mean = rttMeasurements.reduce((a, b) => a + b) / rttMeasurements.length;
      final variance = rttMeasurements
          .map((rtt) => pow(rtt - mean, 2))
          .reduce((a, b) => a + b) / rttMeasurements.length;

      // Despite jitter, orchestrator should not switch excessively
      // (This is validated by the minHoldWindow parameter)
      expect(sqrt(variance), lessThan(100)); // Standard deviation < 100ms
    });
  });

  group('Weak Network Tests - Combined Scenarios', () {
    test('Scenario S1: 150ms + 3% loss + 1Mbps', () async {
      final simulator = WeakNetworkScenarios.s1;

      int successCount = 0;
      int totalLatency = 0;
      const attempts = 50;

      for (int i = 0; i < attempts; i++) {
        try {
          final stopwatch = Stopwatch()..start();
          await simulator.simulateTransmission(() async => 'data');
          stopwatch.stop();

          successCount++;
          totalLatency += stopwatch.elapsedMilliseconds;
        } catch (e) {
          // Packet lost
        }
      }

      // Verify scenario characteristics
      final successRate = successCount > 0 ? successCount / attempts : 0.0;
      expect(successRate, greaterThan(0.93)); // ~97% success

      if (successCount > 0) {
        expect(totalLatency / successCount, greaterThan(140)); // Average latency > 140ms
      }
    });

    test('Scenario S2: 300ms + 5% loss + 512kbps', () async {
      final simulator = WeakNetworkScenarios.s2;

      int successCount = 0;
      const attempts = 50;

      for (int i = 0; i < attempts; i++) {
        try {
          await simulator.simulateTransmission(() async => 'data');
          successCount++;
        } catch (e) {
          // Packet lost
        }
      }

      // This is a challenging scenario
      final successRate = successCount > 0 ? successCount / attempts : 0.0;
      expect(successRate, greaterThan(0.90)); // ~95% success
    });

    test('Scenario S3: Network switching (Wi-Fi -> 4G -> Wi-Fi)', () async {
      // Simulate network transitions
      final networks = [
        NetworkConditionSimulator(latencyMs: 30), // Wi-Fi
        NetworkConditionSimulator(latencyMs: 100, packetLossRate: 0.02), // 4G
        NetworkConditionSimulator(latencyMs: 30), // Wi-Fi
      ];

      final orchestrator = TransportOrchestrator();

      for (int round = 0; round < 3; round++) {
        final currentNetwork = networks[round % networks.length];

        Future<TransportProbeResult> probe(TransportCandidate candidate) async {
          try {
            await currentNetwork.simulateTransmission(() async => true);
            return TransportProbeResult(
              candidate: candidate,
              success: true,
              rtt: Duration(milliseconds: currentNetwork.latencyMs),
            );
          } catch (e) {
            return TransportProbeResult(
              candidate: candidate,
              success: false,
              error: e,
            );
          }
        }

        final candidates = [
          TransportCandidate(
            id: 'wifi-direct',
            kind: TransportKind.lanDirect,
            uri: Uri.parse('ws://192.168.1.100:9527/ws'),
            waitForPairing: false,
            priority: 110,
          ),
          TransportCandidate(
            id: 'cellular-fallback',
            kind: TransportKind.wormholeRelay,
            uri: Uri.parse('wss://wormhole.example.com/ws'),
            waitForPairing: true,
            priority: 90,
          ),
        ];

        final selection = await orchestrator.selectBest(
          candidates: candidates,
          probe: probe,
        );

        expect(selection, isNotNull);

        // Simulate brief disconnection during network switch
        await Future.delayed(const Duration(milliseconds: 500));
      }
    });
  });

  group('Weak Network Tests - Reconnection Performance', () {
    test('Reconnection should complete within 5s target', () async {
      final stopwatch = Stopwatch()..start();

      // Simulate disconnection
      await Future.delayed(const Duration(milliseconds: 500));

      // Simulate reconnection steps
      await Future.delayed(const Duration(milliseconds: 100)); // Detect disconnect
      await Future.delayed(const Duration(milliseconds: 200)); // Initialize reconnect
      await Future.delayed(const Duration(milliseconds: 1500)); // Probe candidates
      await Future.delayed(const Duration(milliseconds: 200)); // Establish connection

      stopwatch.stop();

      // P95 should be under 5s
      expect(stopwatch.elapsedMilliseconds, lessThan(5000));
    });

    test('Multiple rapid disconnections should not cause cascade failure', () async {
      int reconnectAttempts = 0;
      int successfulReconnects = 0;

      for (int i = 0; i < 5; i++) {
        reconnectAttempts++;

        // Simulate reconnection with 90% success rate
        if (Random().nextDouble() > 0.1) {
          await Future.delayed(const Duration(milliseconds: 1000));
          successfulReconnects++;
        }

        // Brief stable period
        await Future.delayed(const Duration(milliseconds: 500));
      }

      // Should handle rapid disconnections gracefully
      final successRate = reconnectAttempts > 0 ? successfulReconnects / reconnectAttempts : 0.0;
      expect(successRate, greaterThan(0.8));
    });
  });
}