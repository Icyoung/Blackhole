import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/transport_models.dart';
import 'package:voyager/src/services/transport_telemetry.dart';

void main() {
  group('emit()', () {
    test('adds event with correct structure', () {
      final telemetry = TransportTelemetry(source: 'test_source');
      telemetry.emit(event: 'connection_start');

      final events = telemetry.snapshot();
      expect(events, hasLength(1));

      final e = events.first;
      expect(e['event'], 'connection_start');
      expect(e['source'], 'test_source');
      expect(e['timestamp'], isNotNull);
      // Verify timestamp is valid ISO 8601 UTC
      final ts = DateTime.parse(e['timestamp'] as String);
      expect(ts.isUtc, isTrue);
    });

    test('includes optional fields only when provided', () {
      final telemetry = TransportTelemetry(source: 'src');

      telemetry.emit(event: 'bare_event');
      final bare = telemetry.snapshot().first;
      expect(bare.containsKey('switch_reason'), isFalse);
      expect(bare.containsKey('fallback_reason'), isFalse);
      expect(bare.containsKey('probe_rtt_ms'), isFalse);
      expect(bare.containsKey('connected'), isFalse);
      expect(bare.containsKey('session_id'), isFalse);
      expect(bare.containsKey('error'), isFalse);

      telemetry.emit(
        event: 'full_event',
        switchReason: 'latency',
        fallbackReason: 'timeout',
        probeRttMs: 42,
        connected: true,
        sessionId: 'sess-1',
        error: Exception('boom'),
        extra: {'custom_key': 'custom_value'},
      );
      final full = telemetry.snapshot().last;
      expect(full['switch_reason'], 'latency');
      expect(full['fallback_reason'], 'timeout');
      expect(full['probe_rtt_ms'], 42);
      expect(full['connected'], isTrue);
      expect(full['session_id'], 'sess-1');
      expect(full['error'], contains('boom'));
      expect(full['custom_key'], 'custom_value');
    });

    test('includes transport metadata', () {
      final telemetry = TransportTelemetry(source: 'src');
      telemetry.emit(
        event: 'switch',
        kind: TransportKind.lanDirect,
        transportId: 'tx-123',
        pathId: 'path-456',
      );

      final e = telemetry.snapshot().first;
      expect(e['transport_kind'], 'lan_direct');
      expect(e['transport_id'], 'tx-123');
      expect(e['path_id'], 'path-456');
    });

    test('defaults transport_id and path_id to unknown', () {
      final telemetry = TransportTelemetry(source: 'src');
      telemetry.emit(event: 'ping');

      final e = telemetry.snapshot().first;
      expect(e['transport_id'], 'unknown');
      expect(e['path_id'], 'unknown');
      expect(e['transport_kind'], 'unknown');
    });
  });

  group('buffer maxEvents', () {
    test('evicts oldest events when buffer exceeds maxEvents', () {
      final telemetry = TransportTelemetry(source: 'src', maxEvents: 3);

      for (var i = 0; i < 5; i++) {
        telemetry.emit(event: 'e$i');
      }

      final events = telemetry.snapshot();
      expect(events, hasLength(3));
      expect(events[0]['event'], 'e2');
      expect(events[1]['event'], 'e3');
      expect(events[2]['event'], 'e4');
    });
  });

  group('snapshot()', () {
    test('returns all events', () {
      final telemetry = TransportTelemetry(source: 'src');
      telemetry.emit(event: 'a');
      telemetry.emit(event: 'b');
      telemetry.emit(event: 'c');

      final events = telemetry.snapshot();
      expect(events, hasLength(3));
      expect(events.map((e) => e['event']), ['a', 'b', 'c']);
    });

    test('returns defensive copy', () {
      final telemetry = TransportTelemetry(source: 'src');
      telemetry.emit(event: 'original');

      final snap1 = telemetry.snapshot();
      // Attempting to modify the returned list should throw since it's
      // unmodifiable.
      expect(() => snap1.add(<String, dynamic>{}), throwsUnsupportedError);

      // A second snapshot still reflects the original internal state.
      final snap2 = telemetry.snapshot();
      expect(snap2, hasLength(1));
      expect(snap2.first['event'], 'original');
    });
  });

  group('percentileProbeRtt()', () {
    test('returns null for empty events', () {
      final telemetry = TransportTelemetry(source: 'src');
      expect(telemetry.percentileProbeRtt(50), isNull);
    });

    test('returns null for invalid percentile <= 0', () {
      final telemetry = TransportTelemetry(source: 'src');
      telemetry.emit(event: 'probe_result', probeRttMs: 10);
      expect(telemetry.percentileProbeRtt(0), isNull);
      expect(telemetry.percentileProbeRtt(-1), isNull);
    });

    test('returns null for invalid percentile > 100', () {
      final telemetry = TransportTelemetry(source: 'src');
      telemetry.emit(event: 'probe_result', probeRttMs: 10);
      expect(telemetry.percentileProbeRtt(101), isNull);
    });

    test('calculates correct p50 with known data', () {
      final telemetry = TransportTelemetry(source: 'src');
      // Emit 10 probe_result events with RTTs 10, 20, ..., 100
      for (var i = 1; i <= 10; i++) {
        telemetry.emit(event: 'probe_result', probeRttMs: i * 10);
      }

      // Sorted: [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
      // rank = round((50/100) * 9) = round(4.5) = 5 -> values[5] = 60
      expect(telemetry.percentileProbeRtt(50), 60);
    });

    test('calculates correct p99 with known data', () {
      final telemetry = TransportTelemetry(source: 'src');
      for (var i = 1; i <= 100; i++) {
        telemetry.emit(event: 'probe_result', probeRttMs: i);
      }

      // Sorted: [1, 2, ..., 100]
      // rank = round((99/100) * 99) = round(98.01) = 98 -> values[98] = 99
      expect(telemetry.percentileProbeRtt(99), 99);
    });

    test('only considers probe_result events with rtt', () {
      final telemetry = TransportTelemetry(source: 'src');
      // Non-probe events should be ignored
      telemetry.emit(event: 'connection_start', probeRttMs: 999);
      telemetry.emit(event: 'switch', probeRttMs: 888);
      // probe_result without rtt should be ignored
      telemetry.emit(event: 'probe_result');
      // Only this one counts
      telemetry.emit(event: 'probe_result', probeRttMs: 42);

      expect(telemetry.percentileProbeRtt(50), 42);
    });

    test('single event percentile calculation', () {
      final telemetry = TransportTelemetry(source: 'src');
      telemetry.emit(event: 'probe_result', probeRttMs: 77);

      // Single value: rank = round((p/100) * 0) = 0 for any valid percentile
      expect(telemetry.percentileProbeRtt(1), 77);
      expect(telemetry.percentileProbeRtt(50), 77);
      expect(telemetry.percentileProbeRtt(100), 77);
    });
  });
}
