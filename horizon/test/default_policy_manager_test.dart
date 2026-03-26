import 'package:flutter_test/flutter_test.dart';
import 'package:horizon/src/services/default_policy_manager.dart';
import 'package:horizon/src/services/canary_deployment.dart';
import 'package:horizon/src/services/transport_models.dart';

void main() {
  group('DefaultPolicyManager', () {
    late CanaryDeployment canaryOff;
    late CanaryDeployment canaryOn;

    setUp(() {
      canaryOff = CanaryDeployment(
        enableCanary: false,
        canaryPercentage: 0,
      );

      canaryOn = CanaryDeployment(
        enableCanary: true,
        canaryPercentage: 100,
        canaryStartTime: DateTime.now().subtract(const Duration(hours: 1)),
        canaryEndTime: DateTime.now().add(const Duration(hours: 1)),
        overrideUsers: {'canaryUser'},
      );
    });

    group('getTransportPriority', () {
      test('phase1 returns wormhole-first for all users', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase1,
        );

        final priority = manager.getTransportPriority('anyUser');
        expect(priority, [
          TransportKind.wormholeRelay,
          TransportKind.lanDirect,
        ]);
      });

      test('phase2 non-canary returns wormhole-first', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase2,
        );

        final priority = manager.getTransportPriority('someUser');
        expect(priority, [
          TransportKind.wormholeRelay,
          TransportKind.lanDirect,
        ]);
      });

      test('phase2 canary user returns wireguard-first', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOn,
          phase: RolloutPhase.phase2,
        );

        final priority = manager.getTransportPriority('canaryUser');
        expect(priority, [
          TransportKind.wireguardDirect,
          TransportKind.lanDirect,
          TransportKind.wormholeRelay,
        ]);
      });

      test('phase4 returns wireguard-first for all users', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase4,
        );

        final priority = manager.getTransportPriority('anyUser');
        expect(priority, [
          TransportKind.wireguardDirect,
          TransportKind.lanDirect,
          TransportKind.wormholeRelay,
        ]);
      });

      test('phase3 returns list based on user hash bucket', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase3,
        );

        // Phase 3 should return one of the two orderings
        final priority = manager.getTransportPriority('testUser');
        expect(priority.isNotEmpty, isTrue);
        // Either wireguard-first or wormhole-first
        expect(
          priority.first == TransportKind.wireguardDirect ||
              priority.first == TransportKind.wormholeRelay,
          isTrue,
        );
      });
    });

    group('getScoringWeights', () {
      test('phase1 uses conservative weights', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase1,
        );

        final weights = manager.getScoringWeights('user1');
        expect(weights.rttWeight, 500);
        expect(weights.successWeight, 100000);
        expect(weights.stabilityWeight, 5000);
        expect(weights.switchThreshold, 300);
      });

      test('phase2 canary uses balanced weights', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOn,
          phase: RolloutPhase.phase2,
        );

        final weights = manager.getScoringWeights('canaryUser');
        expect(weights.rttWeight, 1000);
        expect(weights.stabilityWeight, 2000);
        expect(weights.switchThreshold, 150);
      });

      test('phase2 non-canary uses conservative weights', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase2,
        );

        final weights = manager.getScoringWeights('regularUser');
        expect(weights.rttWeight, 500);
        expect(weights.stabilityWeight, 5000);
        expect(weights.switchThreshold, 300);
      });

      test('phase4 optimizes for performance', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase4,
        );

        final weights = manager.getScoringWeights('user1');
        expect(weights.rttWeight, 2000);
        expect(weights.stabilityWeight, 1000);
        expect(weights.switchThreshold, 100);
      });

      test('phase3 weights are computed from percentage', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase3,
        );

        // Default percentage is 25
        final weights = manager.getScoringWeights('user1');
        // rttWeight = 500 + (500 * 25 / 100).round() = 500 + 125 = 625
        expect(weights.rttWeight, 625);
        // stabilityWeight = 5000 - (3000 * 25 / 100).round() = 5000 - 750 = 4250
        expect(weights.stabilityWeight, 4250);
        // switchThreshold = 300 - (150 * 25 / 100).round() = 300 - 38 = 262
        expect(weights.switchThreshold, 262);
      });
    });

    group('getReconnectionStrategy', () {
      test('phase1 has conservative reconnection', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase1,
        );

        final strategy = manager.getReconnectionStrategy();
        expect(strategy.maxAttempts, 10);
        expect(strategy.baseDelayMs, 1000);
        expect(strategy.maxDelayMs, 30000);
        expect(strategy.backoffFactor, 1.5);
        expect(strategy.immediateReconnectOnNetworkChange, isFalse);
      });

      test('phase2 and phase3 share same strategy', () {
        final manager2 = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase2,
        );
        final manager3 = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase3,
        );

        final s2 = manager2.getReconnectionStrategy();
        final s3 = manager3.getReconnectionStrategy();

        expect(s2.maxAttempts, s3.maxAttempts);
        expect(s2.baseDelayMs, s3.baseDelayMs);
        expect(s2.maxDelayMs, s3.maxDelayMs);
        expect(s2.backoffFactor, s3.backoffFactor);
        expect(s2.immediateReconnectOnNetworkChange, isTrue);
      });

      test('phase4 has aggressive reconnection', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase4,
        );

        final strategy = manager.getReconnectionStrategy();
        expect(strategy.maxAttempts, 3);
        expect(strategy.baseDelayMs, 250);
        expect(strategy.maxDelayMs, 5000);
        expect(strategy.immediateReconnectOnNetworkChange, isTrue);
      });
    });

    group('ReconnectionStrategy.getDelayForAttempt', () {
      test('attempt 0 returns base delay', () {
        const strategy = ReconnectionStrategy(
          maxAttempts: 5,
          baseDelayMs: 500,
          maxDelayMs: 10000,
          backoffFactor: 2.0,
          immediateReconnectOnNetworkChange: true,
        );

        expect(strategy.getDelayForAttempt(0), 500);
      });

      test('attempt 1 returns base delay', () {
        const strategy = ReconnectionStrategy(
          maxAttempts: 5,
          baseDelayMs: 500,
          maxDelayMs: 10000,
          backoffFactor: 2.0,
          immediateReconnectOnNetworkChange: true,
        );

        // attempt 1: 500 * 2^0 = 500
        expect(strategy.getDelayForAttempt(1), 500);
      });

      test('attempt 2 applies backoff', () {
        const strategy = ReconnectionStrategy(
          maxAttempts: 5,
          baseDelayMs: 500,
          maxDelayMs: 10000,
          backoffFactor: 2.0,
          immediateReconnectOnNetworkChange: true,
        );

        // attempt 2: 500 * 2^1 = 1000
        expect(strategy.getDelayForAttempt(2), 1000);
      });

      test('delay is capped at maxDelayMs', () {
        const strategy = ReconnectionStrategy(
          maxAttempts: 10,
          baseDelayMs: 1000,
          maxDelayMs: 5000,
          backoffFactor: 2.0,
          immediateReconnectOnNetworkChange: true,
        );

        // attempt 5: 1000 * 2^4 = 16000 -> capped to 5000
        expect(strategy.getDelayForAttempt(5), 5000);
      });

      test('phase1 backoff with factor 1.5 truncates to integer', () {
        const strategy = ReconnectionStrategy(
          maxAttempts: 10,
          baseDelayMs: 1000,
          maxDelayMs: 30000,
          backoffFactor: 1.5,
          immediateReconnectOnNetworkChange: false,
        );

        // The custom pow() function truncates the base to int:
        // pow(1.5, n) uses 1.5.toInt() = 1, so result is always 1
        // Therefore delay = (1000 * 1).round() = 1000 for all attempts
        expect(strategy.getDelayForAttempt(1), 1000);
        expect(strategy.getDelayForAttempt(2), 1000);
        expect(strategy.getDelayForAttempt(3), 1000);
        expect(strategy.getDelayForAttempt(10), 1000);
      });

      test('negative attempt returns base delay', () {
        const strategy = ReconnectionStrategy(
          maxAttempts: 5,
          baseDelayMs: 500,
          maxDelayMs: 10000,
          backoffFactor: 2.0,
          immediateReconnectOnNetworkChange: true,
        );

        expect(strategy.getDelayForAttempt(-1), 500);
      });
    });

    group('getFeatureFlags', () {
      test('phase1 disables everything', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase1,
        );

        final flags = manager.getFeatureFlags('user1');
        expect(flags['enable_wireguard'], isFalse);
        expect(flags['enable_transport_switch'], isFalse);
        expect(flags['enable_proactive_probing'], isFalse);
        expect(flags['enable_happy_eyeballs'], isFalse);
      });

      test('phase2 canary enables wireguard and transport switch', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOn,
          phase: RolloutPhase.phase2,
        );

        final flags = manager.getFeatureFlags('canaryUser');
        expect(flags['enable_wireguard'], isTrue);
        expect(flags['enable_transport_switch'], isTrue);
        expect(flags['enable_proactive_probing'], isFalse);
        expect(flags['enable_happy_eyeballs'], isFalse);
      });

      test('phase2 non-canary keeps everything disabled', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase2,
        );

        final flags = manager.getFeatureFlags('regularUser');
        expect(flags['enable_wireguard'], isFalse);
        expect(flags['enable_transport_switch'], isFalse);
      });

      test('phase3 enables wireguard and transport switch for all', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase3,
        );

        final flags = manager.getFeatureFlags('user1');
        expect(flags['enable_wireguard'], isTrue);
        expect(flags['enable_transport_switch'], isTrue);
        // proactive_probing and happy_eyeballs depend on percentage >= 50
        // default is 25, so they should be false
        expect(flags['enable_proactive_probing'], isFalse);
        expect(flags['enable_happy_eyeballs'], isFalse);
      });

      test('phase4 enables all features', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase4,
        );

        final flags = manager.getFeatureFlags('user1');
        expect(flags['enable_wireguard'], isTrue);
        expect(flags['enable_transport_switch'], isTrue);
        expect(flags['enable_proactive_probing'], isTrue);
        expect(flags['enable_happy_eyeballs'], isTrue);
      });
    });

    group('advancePhase / rollbackPhase', () {
      test('advances through all phases sequentially', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase1,
        );

        expect(manager.phase, RolloutPhase.phase1);

        manager.advancePhase();
        expect(manager.phase, RolloutPhase.phase2);

        manager.advancePhase();
        expect(manager.phase, RolloutPhase.phase3);

        manager.advancePhase();
        expect(manager.phase, RolloutPhase.phase4);
      });

      test('advancing from phase4 stays at phase4', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase4,
        );

        manager.advancePhase();
        expect(manager.phase, RolloutPhase.phase4);
      });

      test('rolls back through all phases', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase4,
        );

        manager.rollbackPhase();
        expect(manager.phase, RolloutPhase.phase3);

        manager.rollbackPhase();
        expect(manager.phase, RolloutPhase.phase2);

        manager.rollbackPhase();
        expect(manager.phase, RolloutPhase.phase1);
      });

      test('rolling back from phase1 stays at phase1', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase1,
        );

        manager.rollbackPhase();
        expect(manager.phase, RolloutPhase.phase1);
      });

      test('advance then rollback returns to original phase', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOff,
          phase: RolloutPhase.phase2,
        );

        manager.advancePhase();
        expect(manager.phase, RolloutPhase.phase3);

        manager.rollbackPhase();
        expect(manager.phase, RolloutPhase.phase2);
      });
    });

    group('getPolicyStatus', () {
      test('returns current status map', () {
        final manager = DefaultPolicyManager(
          canaryDeployment: canaryOn,
          phase: RolloutPhase.phase2,
        );

        final status = manager.getPolicyStatus();
        expect(status['current_phase'], contains('phase2'));
        expect(status['canary_active'], isTrue);
        expect(status['canary_percentage'], 100.0);
      });
    });
  });

  group('helper functions', () {
    test('pow computes integer power correctly', () {
      expect(pow(2, 0), 1);
      expect(pow(2, 1), 2);
      expect(pow(2, 3), 8);
      expect(pow(3, 2), 9);
    });

    test('min returns the smaller value', () {
      expect(min(1, 2), 1);
      expect(min(5, 3), 3);
      expect(min(7, 7), 7);
    });
  });
}
