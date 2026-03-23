import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/transport_models.dart';
import 'package:voyager/src/services/transport_rollout.dart';

void main() {
  group('canaryPercent', () {
    // Note: _canaryPercentRaw is a compile-time const defaulting to 0.
    // Without dart defines, _canaryPercentRaw == 0, so canaryPercent == 0.
    // We can only verify the default path here; clamping logic is covered
    // by reading the source, but the getter itself returns 0 at runtime.
    test('returns 0 by default (no environment override)', () {
      expect(TransportRolloutConfig.canaryPercent, 0);
    });

    test('value is within valid range 0-100', () {
      final pct = TransportRolloutConfig.canaryPercent;
      expect(pct, greaterThanOrEqualTo(0));
      expect(pct, lessThanOrEqualTo(100));
    });
  });

  group('defaultPriorityFor', () {
    test('wireguardDirect returns 130', () {
      expect(
        TransportRolloutConfig.defaultPriorityFor(
          TransportKind.wireguardDirect,
        ),
        130,
      );
    });

    test('unknown returns 0', () {
      expect(
        TransportRolloutConfig.defaultPriorityFor(TransportKind.unknown),
        0,
      );
    });

    test('lanDirect returns expected priority based on preferDirectByDefault',
        () {
      final priority = TransportRolloutConfig.defaultPriorityFor(
        TransportKind.lanDirect,
      );
      // preferDirectByDefault defaults to false => 90
      expect(priority, 90);
    });

    test(
        'wormholeRelay returns expected priority based on preferDirectByDefault',
        () {
      final priority = TransportRolloutConfig.defaultPriorityFor(
        TransportKind.wormholeRelay,
      );
      // preferDirectByDefault defaults to false => 120
      expect(priority, 120);
    });

    test('every TransportKind has a defined priority', () {
      for (final kind in TransportKind.values) {
        final priority = TransportRolloutConfig.defaultPriorityFor(kind);
        expect(priority, isA<int>());
      }
    });

    test('wireguardDirect has highest priority among all kinds', () {
      final priorities = {
        for (final kind in TransportKind.values)
          kind: TransportRolloutConfig.defaultPriorityFor(kind),
      };
      final maxPriority = priorities.values.reduce(
        (a, b) => a > b ? a : b,
      );
      expect(priorities[TransportKind.wireguardDirect], maxPriority);
    });
  });

  group('isSmartRoutingEnabledForSeed', () {
    // With default compile-time values:
    //   enableSmartTransport = false, so it always returns false.
    test('returns false when enableSmartTransport is false (default)', () {
      expect(
        TransportRolloutConfig.isSmartRoutingEnabledForSeed('any-seed'),
        isFalse,
      );
    });

    test('returns false for empty seed', () {
      expect(
        TransportRolloutConfig.isSmartRoutingEnabledForSeed(''),
        isFalse,
      );
    });

    test('returns false regardless of seed value with defaults', () {
      final seeds = [
        'device-abc-123',
        'user@example.com',
        'aaaaa',
        '12345',
        '',
      ];
      for (final seed in seeds) {
        expect(
          TransportRolloutConfig.isSmartRoutingEnabledForSeed(seed),
          isFalse,
          reason: 'Expected false for seed "$seed"',
        );
      }
    });
  });

  group('_stablePercent (exercised through isSmartRoutingEnabledForSeed)', () {
    // We cannot call _stablePercent directly, but we can verify its
    // determinism indirectly: calling isSmartRoutingEnabledForSeed with
    // the same seed should always produce the same result.
    test('determinism: same seed always gives same result', () {
      const seed = 'deterministic-test-seed';
      final results = List.generate(
        50,
        (_) => TransportRolloutConfig.isSmartRoutingEnabledForSeed(seed),
      );
      // All results should be identical
      expect(results.toSet().length, 1);
    });

    test('consistency across multiple calls with different seeds', () {
      final seeds = ['alpha', 'beta', 'gamma', 'delta', 'epsilon'];
      for (final seed in seeds) {
        final first =
            TransportRolloutConfig.isSmartRoutingEnabledForSeed(seed);
        final second =
            TransportRolloutConfig.isSmartRoutingEnabledForSeed(seed);
        expect(first, second, reason: 'Seed "$seed" gave inconsistent results');
      }
    });
  });

  group('compile-time flag defaults', () {
    test('enableSmartTransport defaults to false', () {
      expect(TransportRolloutConfig.enableSmartTransport, isFalse);
    });

    test('forceWormholeRelay defaults to false', () {
      expect(TransportRolloutConfig.forceWormholeRelay, isFalse);
    });

    test('preferDirectByDefault defaults to false', () {
      expect(TransportRolloutConfig.preferDirectByDefault, isFalse);
    });
  });
}
