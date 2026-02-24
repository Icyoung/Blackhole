import 'dart:async';

import 'transport_models.dart';
import 'canary_deployment.dart';

/// Manages the default transport policy based on rollout phase
class DefaultPolicyManager {
  DefaultPolicyManager({
    required this.canaryDeployment,
    this.phase = RolloutPhase.phase1,
  });

  final CanaryDeployment canaryDeployment;
  RolloutPhase phase;

  /// Get transport priority based on current phase and user group
  List<TransportKind> getTransportPriority(String userId) {
    final isCanary = canaryDeployment.isUserInCanary(userId);

    // Check if forced to Wormhole-only
    if (isForceWormholeOnly) {
      return [TransportKind.wormholeRelay];
    }

    switch (phase) {
      case RolloutPhase.phase1:
        // Phase 1: Wormhole default for everyone
        return [
          TransportKind.wormholeRelay,
          TransportKind.lanDirect,
          TransportKind.tailnetDirect,
        ];

      case RolloutPhase.phase2:
        // Phase 2: Canary users get direct preference
        if (isCanary) {
          return [
            TransportKind.tailnetDirect,
            TransportKind.lanDirect,
            TransportKind.wormholeRelay,
          ];
        } else {
          return [
            TransportKind.wormholeRelay,
            TransportKind.lanDirect,
            TransportKind.tailnetDirect,
          ];
        }

      case RolloutPhase.phase3:
        // Phase 3: Progressive direct preference based on percentage
        final useDirectFirst = _shouldUseDirectFirst(userId);
        if (useDirectFirst) {
          return [
            TransportKind.tailnetDirect,
            TransportKind.lanDirect,
            TransportKind.wormholeRelay,
          ];
        } else {
          return [
            TransportKind.wormholeRelay,
            TransportKind.lanDirect,
            TransportKind.tailnetDirect,
          ];
        }

      case RolloutPhase.phase4:
        // Phase 4: Direct first for everyone (final state)
        return [
          TransportKind.tailnetDirect,
          TransportKind.lanDirect,
          TransportKind.wormholeRelay,
        ];
    }
  }

  /// Get scoring weights based on phase
  ScoringWeights getScoringWeights(String userId) {
    final isCanary = canaryDeployment.isUserInCanary(userId);

    switch (phase) {
      case RolloutPhase.phase1:
        // Conservative: heavily favor stability
        return const ScoringWeights(
          rttWeight: 500,
          successWeight: 100000,
          stabilityWeight: 5000,
          switchThreshold: 300, // High threshold, avoid switching
        );

      case RolloutPhase.phase2:
        // Canary: balanced for testing
        if (isCanary) {
          return const ScoringWeights(
            rttWeight: 1000,
            successWeight: 100000,
            stabilityWeight: 2000,
            switchThreshold: 150,
          );
        } else {
          // Production: still conservative
          return const ScoringWeights(
            rttWeight: 500,
            successWeight: 100000,
            stabilityWeight: 5000,
            switchThreshold: 300,
          );
        }

      case RolloutPhase.phase3:
        // Progressive: gradually favor performance
        final directPercentage = getPhase3DirectPercentage();
        final rttWeight = 500 + (500 * directPercentage / 100).round();
        final stabilityWeight = 5000 - (3000 * directPercentage / 100).round();
        final switchThreshold = 300 - (150 * directPercentage / 100).round();

        return ScoringWeights(
          rttWeight: rttWeight,
          successWeight: 100000,
          stabilityWeight: stabilityWeight,
          switchThreshold: switchThreshold,
        );

      case RolloutPhase.phase4:
        // Final: optimize for performance
        return const ScoringWeights(
          rttWeight: 2000,
          successWeight: 100000,
          stabilityWeight: 1000,
          switchThreshold: 100,
        );
    }
  }

  /// Check if forced to Wormhole-only mode
  bool get isForceWormholeOnly {
    return const bool.fromEnvironment(
      'BH_FORCE_WORMHOLE_RELAY',
      defaultValue: false,
    );
  }

  /// Get current phase 3 direct percentage
  double getPhase3DirectPercentage() {
    return double.tryParse(
      const String.fromEnvironment(
        'BH_PHASE3_DIRECT_PERCENTAGE',
        defaultValue: '25',
      ),
    ) ?? 25.0;
  }

  /// Determine if user should use direct-first in Phase 3
  bool _shouldUseDirectFirst(String userId) {
    final percentage = getPhase3DirectPercentage();

    // Use same hashing as canary for consistency
    final hash = userId.hashCode.abs();
    final threshold = (percentage / 100.0 * 0x7FFFFFFF).floor();

    return hash <= threshold;
  }

  /// Get reconnection strategy based on phase
  ReconnectionStrategy getReconnectionStrategy() {
    switch (phase) {
      case RolloutPhase.phase1:
        return const ReconnectionStrategy(
          maxAttempts: 10,
          baseDelayMs: 1000,
          maxDelayMs: 30000,
          backoffFactor: 1.5,
          immediateReconnectOnNetworkChange: false,
        );

      case RolloutPhase.phase2:
      case RolloutPhase.phase3:
        return const ReconnectionStrategy(
          maxAttempts: 5,
          baseDelayMs: 500,
          maxDelayMs: 10000,
          backoffFactor: 2.0,
          immediateReconnectOnNetworkChange: true,
        );

      case RolloutPhase.phase4:
        return const ReconnectionStrategy(
          maxAttempts: 3,
          baseDelayMs: 250,
          maxDelayMs: 5000,
          backoffFactor: 2.0,
          immediateReconnectOnNetworkChange: true,
        );
    }
  }

  /// Get feature flags based on phase
  Map<String, bool> getFeatureFlags(String userId) {
    final isCanary = canaryDeployment.isUserInCanary(userId);

    switch (phase) {
      case RolloutPhase.phase1:
        return {
          'enable_tailnet': false,
          'enable_transport_switch': false,
          'enable_proactive_probing': false,
          'enable_happy_eyeballs': false,
        };

      case RolloutPhase.phase2:
        if (isCanary) {
          return {
            'enable_tailnet': true,
            'enable_transport_switch': true,
            'enable_proactive_probing': false,
            'enable_happy_eyeballs': false,
          };
        } else {
          return {
            'enable_tailnet': false,
            'enable_transport_switch': false,
            'enable_proactive_probing': false,
            'enable_happy_eyeballs': false,
          };
        }

      case RolloutPhase.phase3:
        final directPercentage = getPhase3DirectPercentage();
        final enableAdvanced = directPercentage >= 50;

        return {
          'enable_tailnet': true,
          'enable_transport_switch': true,
          'enable_proactive_probing': enableAdvanced,
          'enable_happy_eyeballs': enableAdvanced,
        };

      case RolloutPhase.phase4:
        return {
          'enable_tailnet': true,
          'enable_transport_switch': true,
          'enable_proactive_probing': true,
          'enable_happy_eyeballs': true,
        };
    }
  }

  /// Advance to next phase (called after gate approval)
  void advancePhase() {
    switch (phase) {
      case RolloutPhase.phase1:
        phase = RolloutPhase.phase2;
        break;
      case RolloutPhase.phase2:
        phase = RolloutPhase.phase3;
        break;
      case RolloutPhase.phase3:
        phase = RolloutPhase.phase4;
        break;
      case RolloutPhase.phase4:
        // Already at final phase
        break;
    }
  }

  /// Rollback to previous phase (on issues)
  void rollbackPhase() {
    switch (phase) {
      case RolloutPhase.phase1:
        // Can't rollback from phase 1
        break;
      case RolloutPhase.phase2:
        phase = RolloutPhase.phase1;
        break;
      case RolloutPhase.phase3:
        phase = RolloutPhase.phase2;
        break;
      case RolloutPhase.phase4:
        phase = RolloutPhase.phase3;
        break;
    }
  }

  /// Get current policy status
  Map<String, dynamic> getPolicyStatus() {
    return {
      'current_phase': phase.toString(),
      'force_wormhole': isForceWormholeOnly,
      'phase3_direct_percentage': getPhase3DirectPercentage(),
      'canary_active': canaryDeployment.isCanaryActive,
      'canary_percentage': canaryDeployment.canaryPercentage,
    };
  }
}

/// Rollout phases
enum RolloutPhase {
  phase1, // Basic capability, Wormhole default
  phase2, // Canary validation
  phase3, // Progressive rollout
  phase4, // Final state, direct preferred
}

/// Scoring weights configuration
class ScoringWeights {
  const ScoringWeights({
    required this.rttWeight,
    required this.successWeight,
    required this.stabilityWeight,
    required this.switchThreshold,
  });

  final int rttWeight;
  final int successWeight;
  final int stabilityWeight;
  final int switchThreshold;
}

/// Reconnection strategy configuration
class ReconnectionStrategy {
  const ReconnectionStrategy({
    required this.maxAttempts,
    required this.baseDelayMs,
    required this.maxDelayMs,
    required this.backoffFactor,
    required this.immediateReconnectOnNetworkChange,
  });

  final int maxAttempts;
  final int baseDelayMs;
  final int maxDelayMs;
  final double backoffFactor;
  final bool immediateReconnectOnNetworkChange;

  /// Calculate delay for attempt number
  int getDelayForAttempt(int attemptNumber) {
    if (attemptNumber <= 0) return baseDelayMs;

    final delay = (baseDelayMs * pow(backoffFactor, attemptNumber - 1)).round();
    return min(delay, maxDelayMs);
  }
}

/// Factory for creating policy manager
class DefaultPolicyFactory {
  static DefaultPolicyManager create() {
    // Determine current phase from environment
    final phaseStr = const String.fromEnvironment(
      'BH_ROLLOUT_PHASE',
      defaultValue: 'phase1',
    );

    RolloutPhase phase;
    switch (phaseStr) {
      case 'phase1':
        phase = RolloutPhase.phase1;
        break;
      case 'phase2':
        phase = RolloutPhase.phase2;
        break;
      case 'phase3':
        phase = RolloutPhase.phase3;
        break;
      case 'phase4':
        phase = RolloutPhase.phase4;
        break;
      default:
        phase = RolloutPhase.phase1;
    }

    final canaryDeployment = CanaryDeployment.fromEnvironment();

    return DefaultPolicyManager(
      canaryDeployment: canaryDeployment,
      phase: phase,
    );
  }
}

// Helper imports
int pow(num x, num y) {
  if (y == 0) return 1;
  if (y == 1) return x.toInt();

  int result = x.toInt();
  for (int i = 1; i < y; i++) {
    result *= x.toInt();
  }
  return result;
}

int min(int a, int b) => a < b ? a : b;