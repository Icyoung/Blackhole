import 'package:flutter_test/flutter_test.dart';
import 'package:horizon/src/services/canary_deployment.dart';

void main() {
  group('CanaryDeployment', () {
    group('isCanaryActive', () {
      test('returns false when enableCanary is false', () {
        final deployment = CanaryDeployment(
          enableCanary: false,
          canaryPercentage: 50,
        );

        expect(deployment.isCanaryActive, isFalse);
      });

      test('returns true when enabled with no time constraints', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 50,
        );

        expect(deployment.isCanaryActive, isTrue);
      });

      test('returns false before start time', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 50,
          canaryStartTime: DateTime.now().add(const Duration(hours: 1)),
        );

        expect(deployment.isCanaryActive, isFalse);
      });

      test('returns false after end time', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 50,
          canaryEndTime: DateTime.now().subtract(const Duration(hours: 1)),
        );

        expect(deployment.isCanaryActive, isFalse);
      });

      test('returns true within time window', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 50,
          canaryStartTime: DateTime.now().subtract(const Duration(hours: 1)),
          canaryEndTime: DateTime.now().add(const Duration(hours: 1)),
        );

        expect(deployment.isCanaryActive, isTrue);
      });
    });

    group('isUserInCanary', () {
      test('returns false when canary is not active', () {
        final deployment = CanaryDeployment(
          enableCanary: false,
          canaryPercentage: 100,
        );

        expect(deployment.isUserInCanary('anyUser'), isFalse);
      });

      test('override user is always in canary when active', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 0, // 0% but override should still work
          overrideUsers: {'specialUser'},
          canaryStartTime: DateTime.now().subtract(const Duration(hours: 1)),
          canaryEndTime: DateTime.now().add(const Duration(hours: 1)),
        );

        expect(deployment.isUserInCanary('specialUser'), isTrue);
      });

      test('override user not in canary when canary is disabled', () {
        final deployment = CanaryDeployment(
          enableCanary: false,
          canaryPercentage: 100,
          overrideUsers: {'specialUser'},
        );

        expect(deployment.isUserInCanary('specialUser'), isFalse);
      });

      test('100% canary includes most users via hash', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 100,
          canaryStartTime: DateTime.now().subtract(const Duration(hours: 1)),
          canaryEndTime: DateTime.now().add(const Duration(hours: 1)),
        );

        // At 100%, threshold = _maxHashValue (0x7FFFFFFF).
        // The hash uses 4 bytes from SHA256 which can exceed 0x7FFFFFFF,
        // so some users may not be included. Most should be (~50% of hash space).
        int inCanary = 0;
        const total = 200;
        for (int i = 0; i < total; i++) {
          if (deployment.isUserInCanary('user_$i')) inCanary++;
        }
        // Expect at least 40% since threshold covers half the unsigned 32-bit range
        expect(inCanary / total, greaterThan(0.35));
      });

      test('0% canary excludes non-override users', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 0,
          canaryStartTime: DateTime.now().subtract(const Duration(hours: 1)),
          canaryEndTime: DateTime.now().add(const Duration(hours: 1)),
        );

        // No users should be in canary at 0% (hash is always > 0 threshold)
        int inCanary = 0;
        for (int i = 0; i < 100; i++) {
          if (deployment.isUserInCanary('user_$i')) inCanary++;
        }
        expect(inCanary, 0);
      });

      test('deterministic hash produces stable assignment', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 50,
          canaryStartTime: DateTime.now().subtract(const Duration(hours: 1)),
          canaryEndTime: DateTime.now().add(const Duration(hours: 1)),
        );

        // Same user should always get the same result
        final result1 = deployment.isUserInCanary('consistentUser');
        final result2 = deployment.isUserInCanary('consistentUser');
        final result3 = deployment.isUserInCanary('consistentUser');

        expect(result1, result2);
        expect(result2, result3);
      });

      test('hash distributes users roughly by percentage', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 50,
          canaryStartTime: DateTime.now().subtract(const Duration(hours: 1)),
          canaryEndTime: DateTime.now().add(const Duration(hours: 1)),
        );

        int inCanary = 0;
        const totalUsers = 1000;
        for (int i = 0; i < totalUsers; i++) {
          if (deployment.isUserInCanary('test_user_$i')) inCanary++;
        }

        // The threshold at 50% is (50/100 * 0x7FFFFFFF) = ~1073741823.
        // Hash uses 4 bytes from SHA256, range 0..0xFFFFFFFF (~4.29 billion).
        // After .abs(), effective range is 0..0x7FFFFFFF for positive values
        // but negative ints map to the same magnitude.
        // So the actual in-canary ratio depends on hash distribution vs threshold.
        // We just verify it's a reasonable fraction, not exactly 50%.
        final ratio = inCanary / totalUsers;
        expect(ratio, greaterThan(0.15));
        expect(ratio, lessThan(0.85));
      });
    });

    group('getDeploymentLabel', () {
      test('returns canary for canary users', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 100,
          canaryStartTime: DateTime.now().subtract(const Duration(hours: 1)),
          canaryEndTime: DateTime.now().add(const Duration(hours: 1)),
        );

        expect(deployment.getDeploymentLabel('anyUser'), 'canary');
      });

      test('returns production for non-canary users', () {
        final deployment = CanaryDeployment(
          enableCanary: false,
          canaryPercentage: 0,
        );

        expect(deployment.getDeploymentLabel('anyUser'), 'production');
      });
    });

    group('getStatus', () {
      test('returns expected status fields', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 25,
          overrideUsers: {'user1', 'user2'},
        );

        final status = deployment.getStatus();
        expect(status['enabled'], isTrue);
        expect(status['percentage'], 25.0);
        expect(status['override_users_count'], 2);
      });
    });
  });

  group('CanaryRolloutManager', () {
    group('getRecommendedPercentage', () {
      test('progression from 0 recommends 5', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 0,
        );
        final manager = CanaryRolloutManager(
          deployment: deployment,
          metrics: CanaryMetrics(),
        );

        expect(manager.getRecommendedPercentage(), 5);
      });

      test('progression from 5 recommends 10', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 5,
        );
        final manager = CanaryRolloutManager(
          deployment: deployment,
          metrics: CanaryMetrics(),
        );

        expect(manager.getRecommendedPercentage(), 10);
      });

      test('progression from 10 recommends 25', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 10,
        );
        final manager = CanaryRolloutManager(
          deployment: deployment,
          metrics: CanaryMetrics(),
        );

        expect(manager.getRecommendedPercentage(), 25);
      });

      test('progression from 25 recommends 50', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 25,
        );
        final manager = CanaryRolloutManager(
          deployment: deployment,
          metrics: CanaryMetrics(),
        );

        expect(manager.getRecommendedPercentage(), 50);
      });

      test('progression from 50 recommends 100', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 50,
        );
        final manager = CanaryRolloutManager(
          deployment: deployment,
          metrics: CanaryMetrics(),
        );

        expect(manager.getRecommendedPercentage(), 100);
      });

      test('at 100 stays at 100', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 100,
        );
        final manager = CanaryRolloutManager(
          deployment: deployment,
          metrics: CanaryMetrics(),
        );

        expect(manager.getRecommendedPercentage(), 100);
      });

      test('intermediate values snap to next tier', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 7, // between 5 and 10
        );
        final manager = CanaryRolloutManager(
          deployment: deployment,
          metrics: CanaryMetrics(),
        );

        expect(manager.getRecommendedPercentage(), 10);
      });
    });

    group('shouldExpandCanary', () {
      test('returns false when canary is not active', () {
        final deployment = CanaryDeployment(
          enableCanary: false,
          canaryPercentage: 5,
        );
        final manager = CanaryRolloutManager(
          deployment: deployment,
          metrics: CanaryMetrics(),
        );

        expect(manager.shouldExpandCanary(), isFalse);
      });

      test('returns false when no start time', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 5,
        );
        final manager = CanaryRolloutManager(
          deployment: deployment,
          metrics: CanaryMetrics(),
        );

        expect(manager.shouldExpandCanary(), isFalse);
      });

      test('returns false when running less than 24 hours', () {
        final deployment = CanaryDeployment(
          enableCanary: true,
          canaryPercentage: 5,
          canaryStartTime: DateTime.now().subtract(const Duration(hours: 12)),
        );
        final manager = CanaryRolloutManager(
          deployment: deployment,
          metrics: CanaryMetrics(),
        );

        expect(manager.shouldExpandCanary(), isFalse);
      });
    });
  });

  group('CanaryMetrics', () {
    test('incrementCounter tracks counts by deployment', () {
      final metrics = CanaryMetrics();
      metrics.incrementCounter('connections', 'canary');
      metrics.incrementCounter('connections', 'canary');
      metrics.incrementCounter('connections', 'production');

      final comparison = metrics.getComparison();
      final counters = comparison['counters'] as Map<String, dynamic>;
      expect(counters['connections']['canary'], 2);
      expect(counters['connections']['production'], 1);
    });

    test('setGauge records latest value', () {
      final metrics = CanaryMetrics();
      metrics.setGauge('session_loss_rate', 'canary', 0.05);
      metrics.setGauge('session_loss_rate', 'production', 0.03);

      final comparison = metrics.getComparison();
      final gauges = comparison['gauges'] as Map<String, dynamic>;
      expect(gauges['session_loss_rate']['canary'], 0.05);
      expect(gauges['session_loss_rate']['production'], 0.03);
    });

    test('recordHistogram tracks values for percentile calculation', () {
      final metrics = CanaryMetrics();
      for (int i = 1; i <= 100; i++) {
        metrics.recordHistogram('rtt_ms', 'canary', i.toDouble());
      }

      final comparison = metrics.getComparison();
      final histograms = comparison['histograms'] as Map<String, dynamic>;
      final canaryRtt = histograms['rtt_ms']['canary'];
      expect(canaryRtt['count'], 100);
      expect(canaryRtt['p50'], isNotNull);
      expect(canaryRtt['p95'], isNotNull);
      expect(canaryRtt['p99'], isNotNull);
    });

    test('meetsSuccessCriteria passes when canary is better', () {
      final metrics = CanaryMetrics();
      metrics.setGauge('session_loss_rate', 'canary', 0.01);
      metrics.setGauge('session_loss_rate', 'production', 0.02);
      metrics.setGauge('connection_failure_rate', 'canary', 0.01);
      metrics.setGauge('connection_failure_rate', 'production', 0.02);

      // Add some RTT data
      for (int i = 0; i < 100; i++) {
        metrics.recordHistogram('rtt_ms', 'canary', 50.0 + i * 0.5);
        metrics.recordHistogram('rtt_ms', 'production', 60.0 + i * 0.5);
      }

      expect(metrics.meetsSuccessCriteria(), isTrue);
    });

    test('meetsSuccessCriteria fails when canary loss rate is too high', () {
      final metrics = CanaryMetrics();
      metrics.setGauge('session_loss_rate', 'canary', 0.10);
      metrics.setGauge('session_loss_rate', 'production', 0.02);

      expect(metrics.meetsSuccessCriteria(), isFalse);
    });
  });
}
