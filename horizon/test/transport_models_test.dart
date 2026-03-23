import 'package:flutter_test/flutter_test.dart';
import 'package:horizon/src/services/transport_models.dart';

void main() {
  group('TransportKind', () {
    test('wireName returns correct string for each kind', () {
      expect(TransportKind.lanDirect.wireName, 'lan_direct');
      expect(TransportKind.wormholeRelay.wireName, 'wormhole_relay');
      expect(TransportKind.wireguardDirect.wireName, 'wireguard_direct');
      expect(TransportKind.unknown.wireName, 'unknown');
    });

    test('fromWireName resolves known kinds', () {
      expect(TransportKind.fromWireName('lan_direct'), TransportKind.lanDirect);
      expect(TransportKind.fromWireName('wormhole_relay'), TransportKind.wormholeRelay);
      expect(TransportKind.fromWireName('wireguard_direct'), TransportKind.wireguardDirect);
    });

    test('fromWireName returns unknown for unrecognized values', () {
      expect(TransportKind.fromWireName('invalid'), TransportKind.unknown);
      expect(TransportKind.fromWireName(''), TransportKind.unknown);
      expect(TransportKind.fromWireName(null), TransportKind.unknown);
    });

    test('wireguard_relay wire name resolves to unknown after removal', () {
      expect(TransportKind.fromWireName('wireguard_relay'), TransportKind.unknown);
    });
  });

  group('TransportControlType', () {
    test('wireName returns correct string for each type', () {
      expect(TransportControlType.transportProbe.wireName, 'transport_probe');
      expect(TransportControlType.transportProbeResult.wireName, 'transport_probe_result');
      expect(TransportControlType.transportSwitchPrepare.wireName, 'transport_switch_prepare');
      expect(TransportControlType.transportSwitchCommit.wireName, 'transport_switch_commit');
      expect(TransportControlType.transportSwitchAbort.wireName, 'transport_switch_abort');
    });

    test('fromType resolves known types', () {
      expect(
        TransportControlType.fromType('transport_probe'),
        TransportControlType.transportProbe,
      );
      expect(
        TransportControlType.fromType('transport_switch_commit'),
        TransportControlType.transportSwitchCommit,
      );
    });

    test('fromType returns unknown for unrecognized values', () {
      expect(TransportControlType.fromType('bogus'), TransportControlType.unknown);
      expect(TransportControlType.fromType(null), TransportControlType.unknown);
    });
  });

  group('TransportMetadata', () {
    test('toWire omits null fields', () {
      const metadata = TransportMetadata();
      final wire = metadata.toWire();
      expect(wire.isEmpty, isTrue);
    });

    test('toWire includes only non-null fields', () {
      const metadata = TransportMetadata(
        transportId: 'txp-1',
        probeRttMs: 42,
      );
      final wire = metadata.toWire();
      expect(wire['transportId'], 'txp-1');
      expect(wire['probeRttMs'], 42);
      expect(wire.containsKey('pathId'), isFalse);
      expect(wire.containsKey('switchReason'), isFalse);
      expect(wire.containsKey('fallbackReason'), isFalse);
    });

    test('toWire includes all fields when set', () {
      const metadata = TransportMetadata(
        transportId: 'txp-1',
        pathId: 'path-1',
        switchReason: 'rtt_improvement',
        fallbackReason: 'timeout',
        probeRttMs: 100,
      );
      final wire = metadata.toWire();
      expect(wire.length, 5);
      expect(wire['transportId'], 'txp-1');
      expect(wire['pathId'], 'path-1');
      expect(wire['switchReason'], 'rtt_improvement');
      expect(wire['fallbackReason'], 'timeout');
      expect(wire['probeRttMs'], 100);
    });

    test('fromWire round-trips correctly', () {
      const original = TransportMetadata(
        transportId: 'txp-abc',
        pathId: 'path-xyz',
        switchReason: 'perf',
        fallbackReason: 'direct_failed',
        probeRttMs: 55,
      );

      final decoded = TransportMetadata.fromWire(original.toWire());
      expect(decoded.transportId, original.transportId);
      expect(decoded.pathId, original.pathId);
      expect(decoded.switchReason, original.switchReason);
      expect(decoded.fallbackReason, original.fallbackReason);
      expect(decoded.probeRttMs, original.probeRttMs);
    });

    test('fromWire handles empty map', () {
      final decoded = TransportMetadata.fromWire({});
      expect(decoded.transportId, isNull);
      expect(decoded.pathId, isNull);
      expect(decoded.switchReason, isNull);
      expect(decoded.fallbackReason, isNull);
      expect(decoded.probeRttMs, isNull);
    });

    test('fromWire parses numeric probeRttMs as int', () {
      final decoded = TransportMetadata.fromWire({
        'probeRttMs': 3.14,
      });
      expect(decoded.probeRttMs, 3);
    });

    test('fromWire parses int probeRttMs directly', () {
      final decoded = TransportMetadata.fromWire({
        'probeRttMs': 42,
      });
      expect(decoded.probeRttMs, 42);
    });

    test('fromWire returns null probeRttMs for non-numeric value', () {
      final decoded = TransportMetadata.fromWire({
        'probeRttMs': 'not_a_number',
      });
      expect(decoded.probeRttMs, isNull);
    });

    test('copyWith overrides specified fields', () {
      const original = TransportMetadata(
        transportId: 'txp-1',
        pathId: 'path-1',
        probeRttMs: 100,
      );

      final copied = original.copyWith(
        pathId: 'path-2',
        switchReason: 'manual',
      );

      expect(copied.transportId, 'txp-1'); // unchanged
      expect(copied.pathId, 'path-2'); // overridden
      expect(copied.switchReason, 'manual'); // new
      expect(copied.probeRttMs, 100); // unchanged
    });

    test('copyWith with no arguments returns equivalent metadata', () {
      const original = TransportMetadata(
        transportId: 'txp-1',
        pathId: 'path-1',
      );

      final copied = original.copyWith();
      expect(copied.transportId, original.transportId);
      expect(copied.pathId, original.pathId);
    });
  });
}
