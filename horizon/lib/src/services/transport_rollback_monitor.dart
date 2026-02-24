import 'dart:async';

import 'transport_models.dart';
import 'transport_rollout.dart';
import 'transport_telemetry.dart';

/// Automatic rollback thresholds configuration
class RollbackThresholds {
  const RollbackThresholds({
    this.maxSessionLossRate = 0.05, // 5%
    this.maxConnectionFailureRate = 0.10, // 10%
    this.maxRttP95Ms = 500, // 500ms
    this.maxSwitchRatePerMinute = 20,
    this.evaluationWindowMinutes = 30,
    this.consecutiveBreachesRequired = 2,
  });

  final double maxSessionLossRate;
  final double maxConnectionFailureRate;
  final int maxRttP95Ms;
  final int maxSwitchRatePerMinute;
  final int evaluationWindowMinutes;
  final int consecutiveBreachesRequired;
}

/// Monitor that tracks transport metrics and triggers automatic rollback
class TransportRollbackMonitor {
  TransportRollbackMonitor({
    required this.telemetry,
    this.thresholds = const RollbackThresholds(),
    this.onRollbackTriggered,
  }) {
    _startMonitoring();
  }

  final TransportTelemetry telemetry;
  final RollbackThresholds thresholds;
  final void Function(String reason)? onRollbackTriggered;

  Timer? _monitorTimer;
  final Map<String, int> _breachCounts = {};
  bool _isRolledBack = false;

  // Metrics tracking
  int _sessionCount = 0;
  int _sessionLossCount = 0;
  int _connectionAttempts = 0;
  int _connectionFailures = 0;
  final List<int> _rttMeasurements = [];
  final List<DateTime> _switchTimestamps = [];

  void _startMonitoring() {
    _monitorTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      _evaluateMetrics();
    });
  }

  void recordSessionStart() {
    _sessionCount++;
  }

  void recordSessionLoss() {
    _sessionLossCount++;
  }

  void recordConnectionAttempt() {
    _connectionAttempts++;
  }

  void recordConnectionFailure() {
    _connectionFailures++;
  }

  void recordRttMeasurement(int rttMs) {
    _rttMeasurements.add(rttMs);
    // Keep only recent measurements (last 30 minutes)
    final cutoff = DateTime.now().subtract(Duration(minutes: thresholds.evaluationWindowMinutes));
    _rttMeasurements.removeWhere((rtt) {
      // For simplicity, keep last 1000 measurements
      return _rttMeasurements.length > 1000;
    });
  }

  void recordTransportSwitch() {
    _switchTimestamps.add(DateTime.now());
    // Clean up old timestamps
    final cutoff = DateTime.now().subtract(Duration(minutes: thresholds.evaluationWindowMinutes));
    _switchTimestamps.removeWhere((ts) => ts.isBefore(cutoff));
  }

  void _evaluateMetrics() {
    if (_isRolledBack) {
      return; // Already rolled back, stop evaluating
    }

    final breaches = <String>[];

    // Check session loss rate
    if (_sessionCount > 0) {
      final sessionLossRate = _sessionLossCount / _sessionCount;
      if (sessionLossRate > thresholds.maxSessionLossRate) {
        breaches.add('Session loss rate: ${(sessionLossRate * 100).toStringAsFixed(1)}% > ${(thresholds.maxSessionLossRate * 100).toStringAsFixed(1)}%');
      }
    }

    // Check connection failure rate
    if (_connectionAttempts > 0) {
      final failureRate = _connectionFailures / _connectionAttempts;
      if (failureRate > thresholds.maxConnectionFailureRate) {
        breaches.add('Connection failure rate: ${(failureRate * 100).toStringAsFixed(1)}% > ${(thresholds.maxConnectionFailureRate * 100).toStringAsFixed(1)}%');
      }
    }

    // Check RTT P95
    if (_rttMeasurements.isNotEmpty) {
      final sortedRtt = List<int>.from(_rttMeasurements)..sort();
      final p95Index = (sortedRtt.length * 0.95).floor();
      final rttP95 = sortedRtt[p95Index];
      if (rttP95 > thresholds.maxRttP95Ms) {
        breaches.add('RTT P95: ${rttP95}ms > ${thresholds.maxRttP95Ms}ms');
      }
    }

    // Check switch rate
    final recentSwitches = _switchTimestamps.where((ts) {
      return ts.isAfter(DateTime.now().subtract(const Duration(minutes: 1)));
    }).length;
    if (recentSwitches > thresholds.maxSwitchRatePerMinute) {
      breaches.add('Switch rate: $recentSwitches/min > ${thresholds.maxSwitchRatePerMinute}/min');
    }

    // Process breaches
    if (breaches.isNotEmpty) {
      final breachKey = breaches.join(';');
      _breachCounts[breachKey] = (_breachCounts[breachKey] ?? 0) + 1;

      if (_breachCounts[breachKey]! >= thresholds.consecutiveBreachesRequired) {
        _triggerRollback(breaches.join(', '));
      }
    } else {
      // Clear breach counts if metrics are healthy
      _breachCounts.clear();
    }

    // Reset counters for next window (sliding window approach)
    _resetCountersIfNeeded();
  }

  void _triggerRollback(String reason) {
    _isRolledBack = true;

    // Log critical event
    telemetry.emit(
      event: 'automatic_rollback_triggered',
      fallbackReason: reason,
      extra: {
        'session_loss_rate': _sessionCount > 0 ? _sessionLossCount / _sessionCount : 0,
        'connection_failure_rate': _connectionAttempts > 0 ? _connectionFailures / _connectionAttempts : 0,
        'switch_count': _switchTimestamps.length,
      },
    );

    // Execute rollback
    _forceWormholeOnly();

    // Notify callback
    onRollbackTriggered?.call(reason);
  }

  void _forceWormholeOnly() {
    // In a real implementation, this would set the environment variables
    // or update configuration to force Wormhole-only mode
    // For now, we'll emit a telemetry event
    telemetry.emit(
      event: 'force_wormhole_enabled',
      extra: {'automatic': true},
    );
  }

  void _resetCountersIfNeeded() {
    // Reset counters every evaluation window
    // In production, this would use a sliding window approach
    if (_sessionCount > 1000) {
      // Simple reset after 1000 sessions
      _sessionCount = (_sessionCount * 0.1).round(); // Keep 10% for continuity
      _sessionLossCount = (_sessionLossCount * 0.1).round();
      _connectionAttempts = (_connectionAttempts * 0.1).round();
      _connectionFailures = (_connectionFailures * 0.1).round();
    }
  }

  /// Manual rollback trigger
  void manualRollback(String reason) {
    if (!_isRolledBack) {
      _triggerRollback('Manual: $reason');
    }
  }

  /// Check if system is currently rolled back
  bool get isRolledBack => _isRolledBack;

  /// Reset rollback state (for testing or after fixes)
  void resetRollback() {
    _isRolledBack = false;
    _breachCounts.clear();
    telemetry.emit(
      event: 'rollback_reset',
      extra: {'manual': true},
    );
  }

  /// Get current metrics snapshot
  Map<String, dynamic> getMetricsSnapshot() {
    final sessionLossRate = _sessionCount > 0 ? _sessionLossCount / _sessionCount : 0.0;
    final connectionFailureRate = _connectionAttempts > 0 ? _connectionFailures / _connectionAttempts : 0.0;

    int? rttP95;
    if (_rttMeasurements.isNotEmpty) {
      final sortedRtt = List<int>.from(_rttMeasurements)..sort();
      final p95Index = (sortedRtt.length * 0.95).floor();
      rttP95 = sortedRtt[p95Index];
    }

    final recentSwitchRate = _switchTimestamps.where((ts) {
      return ts.isAfter(DateTime.now().subtract(const Duration(minutes: 1)));
    }).length;

    return {
      'session_loss_rate': sessionLossRate,
      'connection_failure_rate': connectionFailureRate,
      'rtt_p95_ms': rttP95,
      'switch_rate_per_minute': recentSwitchRate,
      'is_rolled_back': _isRolledBack,
      'breach_counts': Map<String, int>.from(_breachCounts),
      'thresholds': {
        'max_session_loss_rate': thresholds.maxSessionLossRate,
        'max_connection_failure_rate': thresholds.maxConnectionFailureRate,
        'max_rtt_p95_ms': thresholds.maxRttP95Ms,
        'max_switch_rate_per_minute': thresholds.maxSwitchRatePerMinute,
      },
    };
  }

  void dispose() {
    _monitorTimer?.cancel();
  }
}

/// Factory for creating rollback monitor with proper configuration
class RollbackMonitorFactory {
  static TransportRollbackMonitor create({
    required TransportTelemetry telemetry,
    void Function(String reason)? onRollbackTriggered,
  }) {
    // Check if automatic rollback is enabled
    const enableAutoRollback = bool.fromEnvironment(
      'BH_ENABLE_AUTO_ROLLBACK',
      defaultValue: true,
    );

    if (!enableAutoRollback) {
      // Return a no-op monitor if disabled
      return TransportRollbackMonitor(
        telemetry: telemetry,
        thresholds: const RollbackThresholds(
          maxSessionLossRate: 1.0, // Never trigger
          maxConnectionFailureRate: 1.0,
          maxRttP95Ms: 999999,
          maxSwitchRatePerMinute: 999999,
        ),
      );
    }

    // Load thresholds from environment or use defaults
    final thresholds = RollbackThresholds(
      maxSessionLossRate: double.tryParse(
            const String.fromEnvironment('BH_MAX_SESSION_LOSS_RATE', defaultValue: '0.05'),
          ) ?? 0.05,
      maxConnectionFailureRate: double.tryParse(
            const String.fromEnvironment('BH_MAX_CONNECTION_FAILURE_RATE', defaultValue: '0.10'),
          ) ?? 0.10,
      maxRttP95Ms: int.tryParse(
            const String.fromEnvironment('BH_MAX_RTT_P95_MS', defaultValue: '500'),
          ) ?? 500,
      maxSwitchRatePerMinute: int.tryParse(
            const String.fromEnvironment('BH_MAX_SWITCH_RATE_PER_MINUTE', defaultValue: '20'),
          ) ?? 20,
      evaluationWindowMinutes: int.tryParse(
            const String.fromEnvironment('BH_EVALUATION_WINDOW_MINUTES', defaultValue: '30'),
          ) ?? 30,
      consecutiveBreachesRequired: int.tryParse(
            const String.fromEnvironment('BH_CONSECUTIVE_BREACHES_REQUIRED', defaultValue: '2'),
          ) ?? 2,
    );

    return TransportRollbackMonitor(
      telemetry: telemetry,
      thresholds: thresholds,
      onRollbackTriggered: onRollbackTriggered,
    );
  }
}