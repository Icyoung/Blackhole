import 'package:flutter_test/flutter_test.dart';
import 'package:horizon/src/services/transport_telemetry.dart';
import 'package:horizon/src/services/transport_models.dart';

void main() {
  group('TransportTelemetry', () {
    test('constructor sets source and maxEvents', () {
      final t = TransportTelemetry(source: 'horizon', maxEvents: 10);
      expect(t.source, 'horizon');
      expect(t.maxEvents, 10);
    });

    test('default maxEvents is 500', () {
      final t = TransportTelemetry(source: 'test');
      expect(t.maxEvents, 500);
    });

    test('snapshot is empty initially', () {
      final t = TransportTelemetry(source: 'test');
      expect(t.snapshot(), isEmpty);
    });

    test('emit adds event to snapshot', () {
      final t = TransportTelemetry(source: 'test');
      t.emit(event: 'connection_started');

      final events = t.snapshot();
      expect(events, hasLength(1));
      expect(events.first['event'], 'connection_started');
      expect(events.first['source'], 'test');
    });

    test('emit includes required fields', () {
      final t = TransportTelemetry(source: 'my_source');
      t.emit(event: 'probe_result');

      final e = t.snapshot().first;
      expect(e['event'], 'probe_result');
      expect(e['source'], 'my_source');
      expect(e['timestamp'], isNotNull);
      expect(e['transport_kind'], TransportKind.unknown.wireName);
      expect(e['transport_id'], 'unknown');
      expect(e['path_id'], 'unknown');
    });

    test('emit includes optional fields when provided', () {
      final t = TransportTelemetry(source: 'test');
      t.emit(
        event: 'switch',
        kind: TransportKind.lanDirect,
        transportId: 'lan-1',
        pathId: 'path-1',
        switchReason: 'better_rtt',
        fallbackReason: 'timeout',
        probeRttMs: 42,
        connected: true,
        sessionId: 'sess-abc',
        error: Exception('oops'),
        extra: {'custom_key': 'custom_value'},
      );

      final e = t.snapshot().first;
      expect(e['transport_kind'], 'lan_direct');
      expect(e['transport_id'], 'lan-1');
      expect(e['path_id'], 'path-1');
      expect(e['switch_reason'], 'better_rtt');
      expect(e['fallback_reason'], 'timeout');
      expect(e['probe_rtt_ms'], 42);
      expect(e['connected'], true);
      expect(e['session_id'], 'sess-abc');
      expect(e['error'], contains('oops'));
      expect(e['custom_key'], 'custom_value');
    });

    test('emit excludes null optional fields', () {
      final t = TransportTelemetry(source: 'test');
      t.emit(event: 'basic');

      final e = t.snapshot().first;
      expect(e.containsKey('switch_reason'), false);
      expect(e.containsKey('fallback_reason'), false);
      expect(e.containsKey('probe_rtt_ms'), false);
      expect(e.containsKey('connected'), false);
      expect(e.containsKey('session_id'), false);
      expect(e.containsKey('error'), false);
    });

    test('snapshot returns unmodifiable copy', () {
      final t = TransportTelemetry(source: 'test');
      t.emit(event: 'a');

      final snap1 = t.snapshot();
      t.emit(event: 'b');
      final snap2 = t.snapshot();

      // snap1 should not reflect the second emit
      expect(snap1, hasLength(1));
      expect(snap2, hasLength(2));
    });

    test('events are evicted when maxEvents is exceeded', () {
      final t = TransportTelemetry(source: 'test', maxEvents: 3);

      t.emit(event: 'event_1');
      t.emit(event: 'event_2');
      t.emit(event: 'event_3');
      t.emit(event: 'event_4');

      final events = t.snapshot();
      expect(events, hasLength(3));
      // First event should have been evicted
      expect(events.first['event'], 'event_2');
      expect(events.last['event'], 'event_4');
    });

    test('timestamp is ISO 8601 UTC', () {
      final t = TransportTelemetry(source: 'test');
      t.emit(event: 'ts_test');

      final ts = t.snapshot().first['timestamp'] as String;
      // Should end with Z (UTC) and parse successfully
      expect(ts, endsWith('Z'));
      expect(() => DateTime.parse(ts), returnsNormally);
    });

    test('extra map fields are merged into payload', () {
      final t = TransportTelemetry(source: 'test');
      t.emit(
        event: 'custom',
        extra: {'foo': 1, 'bar': 'baz'},
      );

      final e = t.snapshot().first;
      expect(e['foo'], 1);
      expect(e['bar'], 'baz');
    });
  });
}
