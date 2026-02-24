import 'dart:convert';
import 'dart:math';
import 'package:crypto/crypto.dart';

/// Canary deployment configuration and user selection logic
class CanaryDeployment {
  CanaryDeployment({
    this.canaryPercentage = 5.0,
    this.enableCanary = false,
    this.canaryStartTime,
    this.canaryEndTime,
    this.overrideUsers = const {},
  });

  final double canaryPercentage;
  final bool enableCanary;
  final DateTime? canaryStartTime;
  final DateTime? canaryEndTime;
  final Set<String> overrideUsers;

  // Salt for consistent hashing across restarts
  static const String _hashSalt = 'blackhole-transport-canary-2026-02';

  /// Check if canary is currently active
  bool get isCanaryActive {
    if (!enableCanary) return false;

    final now = DateTime.now();
    if (canaryStartTime != null && now.isBefore(canaryStartTime!)) {
      return false;
    }
    if (canaryEndTime != null && now.isAfter(canaryEndTime!)) {
      return false;
    }

    return true;
  }

  /// Determine if a user is in the canary group
  bool isUserInCanary(String userId) {
    if (!isCanaryActive) return false;

    // Check override list first (for testing/debugging)
    if (overrideUsers.contains(userId)) {
      return true;
    }

    // Use consistent hashing for stable assignment
    final hash = _hashUserId(userId);
    final threshold = (canaryPercentage / 100.0 * _maxHashValue).floor();

    return hash <= threshold;
  }

  /// Get canary deployment label for metrics
  String getDeploymentLabel(String userId) {
    return isUserInCanary(userId) ? 'canary' : 'production';
  }

  /// Hash user ID to a stable integer for canary selection
  int _hashUserId(String userId) {
    final bytes = utf8.encode('$_hashSalt:$userId');
    final digest = sha256.convert(bytes);

    // Convert first 4 bytes of hash to integer
    final hashBytes = digest.bytes.take(4).toList();
    int hash = 0;
    for (int i = 0; i < 4; i++) {
      hash = (hash << 8) | hashBytes[i];
    }

    return hash.abs();
  }

  static const int _maxHashValue = 0x7FFFFFFF; // Max positive 32-bit integer

  /// Create from environment configuration
  factory CanaryDeployment.fromEnvironment() {
    final percentage = double.tryParse(
      const String.fromEnvironment('BH_CANARY_PERCENTAGE', defaultValue: '0'),
    ) ?? 0.0;

    final enableCanary = const bool.fromEnvironment(
      'BH_ENABLE_CANARY',
      defaultValue: false,
    );

    final startTimeStr = const String.fromEnvironment('BH_CANARY_START_TIME');
    final endTimeStr = const String.fromEnvironment('BH_CANARY_END_TIME');

    DateTime? startTime;
    DateTime? endTime;

    if (startTimeStr.isNotEmpty) {
      startTime = DateTime.tryParse(startTimeStr);
    }
    if (endTimeStr.isNotEmpty) {
      endTime = DateTime.tryParse(endTimeStr);
    }

    // Parse override users from comma-separated list
    final overrideUsersStr = const String.fromEnvironment('BH_CANARY_OVERRIDE_USERS');
    final overrideUsers = overrideUsersStr.isNotEmpty
        ? overrideUsersStr.split(',').map((s) => s.trim()).toSet()
        : <String>{};

    return CanaryDeployment(
      canaryPercentage: percentage,
      enableCanary: enableCanary,
      canaryStartTime: startTime,
      canaryEndTime: endTime,
      overrideUsers: overrideUsers,
    );
  }

  /// Get current canary status as a map
  Map<String, dynamic> getStatus() {
    return {
      'enabled': enableCanary,
      'active': isCanaryActive,
      'percentage': canaryPercentage,
      'start_time': canaryStartTime?.toIso8601String(),
      'end_time': canaryEndTime?.toIso8601String(),
      'override_users_count': overrideUsers.length,
    };
  }
}

/// Manages canary-specific feature flags
class CanaryFeatureFlags {
  CanaryFeatureFlags({
    required this.canaryDeployment,
    required this.userId,
  });

  final CanaryDeployment canaryDeployment;
  final String userId;

  bool get isInCanary => canaryDeployment.isUserInCanary(userId);

  /// Enable Tailnet ingress for canary users
  bool get enableTailnetIngress {
    if (!isInCanary) {
      return const bool.fromEnvironment(
        'BH_ENABLE_TAILNET_INGRESS',
        defaultValue: false,
      );
    }

    // Canary users get the feature unless explicitly disabled
    return const bool.fromEnvironment(
      'BH_CANARY_ENABLE_TAILNET_INGRESS',
      defaultValue: true,
    );
  }

  /// Enable transport switching for canary users
  bool get enableTransportSwitch {
    if (!isInCanary) {
      return const bool.fromEnvironment(
        'BH_ENABLE_TRANSPORT_SWITCH',
        defaultValue: false,
      );
    }

    // Canary users get the feature unless explicitly disabled
    return const bool.fromEnvironment(
      'BH_CANARY_ENABLE_TRANSPORT_SWITCH',
      defaultValue: true,
    );
  }

  /// Get RTT weight for scoring (can be tuned for canary)
  int get rttWeight {
    if (!isInCanary) {
      return int.tryParse(
        const String.fromEnvironment('BH_RTT_WEIGHT', defaultValue: '1000'),
      ) ?? 1000;
    }

    return int.tryParse(
      const String.fromEnvironment('BH_CANARY_RTT_WEIGHT', defaultValue: '1000'),
    ) ?? 1000;
  }

  /// Get switch threshold score (can be tuned for canary)
  int get switchThresholdScore {
    if (!isInCanary) {
      return int.tryParse(
        const String.fromEnvironment('BH_SWITCH_THRESHOLD_SCORE', defaultValue: '150'),
      ) ?? 150;
    }

    return int.tryParse(
      const String.fromEnvironment('BH_CANARY_SWITCH_THRESHOLD_SCORE', defaultValue: '150'),
    ) ?? 150;
  }

  /// Get minimum hold window for transport switching
  Duration get minHoldWindow {
    final seconds = isInCanary
        ? int.tryParse(
            const String.fromEnvironment('BH_CANARY_MIN_HOLD_WINDOW_SECONDS', defaultValue: '8'),
          ) ?? 8
        : int.tryParse(
            const String.fromEnvironment('BH_MIN_HOLD_WINDOW_SECONDS', defaultValue: '8'),
          ) ?? 8;

    return Duration(seconds: seconds);
  }

  /// Get all flags as a map for telemetry
  Map<String, dynamic> toTelemetryMap() {
    return {
      'deployment': canaryDeployment.getDeploymentLabel(userId),
      'is_canary': isInCanary,
      'enable_tailnet_ingress': enableTailnetIngress,
      'enable_transport_switch': enableTransportSwitch,
      'rtt_weight': rttWeight,
      'switch_threshold_score': switchThresholdScore,
      'min_hold_window_seconds': minHoldWindow.inSeconds,
    };
  }
}

/// Tracks canary metrics separately from production
class CanaryMetrics {
  final Map<String, int> _counters = {};
  final Map<String, List<double>> _histograms = {};
  final Map<String, double> _gauges = {};

  void incrementCounter(String name, String deployment) {
    final key = '${deployment}_$name';
    _counters[key] = (_counters[key] ?? 0) + 1;
  }

  void recordHistogram(String name, String deployment, double value) {
    final key = '${deployment}_$name';
    _histograms[key] ??= [];
    _histograms[key]!.add(value);
  }

  void setGauge(String name, String deployment, double value) {
    final key = '${deployment}_$name';
    _gauges[key] = value;
  }

  /// Get comparison between canary and production
  Map<String, dynamic> getComparison() {
    final comparison = <String, dynamic>{};

    // Compare counters
    final counterComparison = <String, dynamic>{};
    for (final entry in _counters.entries) {
      final parts = entry.key.split('_');
      if (parts.isEmpty) continue;

      final deployment = parts[0];
      final metric = parts.sublist(1).join('_');

      counterComparison[metric] ??= {};
      counterComparison[metric][deployment] = entry.value;
    }
    comparison['counters'] = counterComparison;

    // Compare histograms (calculate percentiles)
    final histogramComparison = <String, dynamic>{};
    for (final entry in _histograms.entries) {
      final parts = entry.key.split('_');
      if (parts.isEmpty) continue;

      final deployment = parts[0];
      final metric = parts.sublist(1).join('_');

      histogramComparison[metric] ??= {};

      final values = List<double>.from(entry.value)..sort();
      if (values.isNotEmpty) {
        histogramComparison[metric][deployment] = {
          'p50': _percentile(values, 0.50),
          'p95': _percentile(values, 0.95),
          'p99': _percentile(values, 0.99),
          'count': values.length,
        };
      }
    }
    comparison['histograms'] = histogramComparison;

    // Compare gauges
    final gaugeComparison = <String, dynamic>{};
    for (final entry in _gauges.entries) {
      final parts = entry.key.split('_');
      if (parts.isEmpty) continue;

      final deployment = parts[0];
      final metric = parts.sublist(1).join('_');

      gaugeComparison[metric] ??= {};
      gaugeComparison[metric][deployment] = entry.value;
    }
    comparison['gauges'] = gaugeComparison;

    return comparison;
  }

  double _percentile(List<double> sortedValues, double percentile) {
    if (sortedValues.isEmpty) return 0;

    final index = (sortedValues.length * percentile).floor();
    return sortedValues[min(index, sortedValues.length - 1)];
  }

  /// Check if canary meets success criteria
  bool meetsSuccessCriteria() {
    final comparison = getComparison();

    // Check session loss rate
    final sessionLoss = comparison['gauges']?['session_loss_rate'] ?? {};
    final canaryLoss = (sessionLoss['canary'] ?? 0.0) as double;
    final prodLoss = (sessionLoss['production'] ?? 0.0) as double;

    if (canaryLoss > prodLoss * 1.1) {
      // Canary has >10% higher loss rate than production
      return false;
    }

    // Check RTT P95
    final rtt = comparison['histograms']?['rtt_ms'] ?? {};
    final canaryRttP95 = rtt['canary']?['p95'] ?? double.infinity;
    final prodRttP95 = rtt['production']?['p95'] ?? double.infinity;

    // Canary should show improvement or be within 10% of production
    if (canaryRttP95 > prodRttP95 * 1.1) {
      return false;
    }

    // Check connection failure rate
    final connFailure = comparison['gauges']?['connection_failure_rate'] ?? {};
    final canaryFailure = (connFailure['canary'] ?? 0.0) as double;
    final prodFailure = (connFailure['production'] ?? 0.0) as double;

    if (canaryFailure > prodFailure * 1.1) {
      return false;
    }

    return true;
  }
}

/// Canary rollout manager
class CanaryRolloutManager {
  CanaryRolloutManager({
    required this.deployment,
    required this.metrics,
  });

  final CanaryDeployment deployment;
  final CanaryMetrics metrics;

  /// Check if we should expand canary percentage
  bool shouldExpandCanary() {
    if (!deployment.isCanaryActive) return false;

    // Check if canary has been running for at least 24 hours
    final startTime = deployment.canaryStartTime;
    if (startTime == null) return false;

    final runningDuration = DateTime.now().difference(startTime);
    if (runningDuration.inHours < 24) {
      return false; // Too early to expand
    }

    // Check if metrics meet success criteria
    return metrics.meetsSuccessCriteria();
  }

  /// Get recommended next canary percentage
  double getRecommendedPercentage() {
    final current = deployment.canaryPercentage;

    // Standard progression: 5% -> 10% -> 25% -> 50% -> 100%
    if (current < 5) return 5;
    if (current < 10) return 10;
    if (current < 25) return 25;
    if (current < 50) return 50;
    if (current < 100) return 100;

    return current; // Already at 100%
  }

  /// Generate canary status report
  Map<String, dynamic> generateReport() {
    return {
      'deployment_status': deployment.getStatus(),
      'metrics_comparison': metrics.getComparison(),
      'meets_success_criteria': metrics.meetsSuccessCriteria(),
      'should_expand': shouldExpandCanary(),
      'recommended_percentage': getRecommendedPercentage(),
      'timestamp': DateTime.now().toIso8601String(),
    };
  }
}