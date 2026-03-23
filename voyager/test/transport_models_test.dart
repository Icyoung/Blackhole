import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/transport_models.dart';

void main() {
  // ---------------------------------------------------------------------------
  // TransportKind
  // ---------------------------------------------------------------------------
  group('TransportKind.fromWireName', () {
    test('parses all valid wire names', () {
      expect(TransportKind.fromWireName('lan_direct'), TransportKind.lanDirect);
      expect(
        TransportKind.fromWireName('wormhole_relay'),
        TransportKind.wormholeRelay,
      );
      expect(
        TransportKind.fromWireName('wireguard_direct'),
        TransportKind.wireguardDirect,
      );
      expect(TransportKind.fromWireName('unknown'), TransportKind.unknown);
    });

    test('returns unknown for null', () {
      expect(TransportKind.fromWireName(null), TransportKind.unknown);
    });

    test('returns unknown for unrecognised string', () {
      expect(TransportKind.fromWireName('bluetooth'), TransportKind.unknown);
      expect(TransportKind.fromWireName(''), TransportKind.unknown);
    });
  });

  // ---------------------------------------------------------------------------
  // TransportControlType
  // ---------------------------------------------------------------------------
  group('TransportControlType.fromType', () {
    test('parses all valid type strings', () {
      expect(
        TransportControlType.fromType('transport_probe'),
        TransportControlType.transportProbe,
      );
      expect(
        TransportControlType.fromType('transport_probe_result'),
        TransportControlType.transportProbeResult,
      );
      expect(
        TransportControlType.fromType('transport_switch_prepare'),
        TransportControlType.transportSwitchPrepare,
      );
      expect(
        TransportControlType.fromType('transport_switch_commit'),
        TransportControlType.transportSwitchCommit,
      );
      expect(
        TransportControlType.fromType('transport_switch_abort'),
        TransportControlType.transportSwitchAbort,
      );
      expect(
        TransportControlType.fromType('unknown'),
        TransportControlType.unknown,
      );
    });

    test('returns unknown for null', () {
      expect(TransportControlType.fromType(null), TransportControlType.unknown);
    });

    test('returns unknown for unrecognised string', () {
      expect(TransportControlType.fromType('nope'), TransportControlType.unknown);
      expect(TransportControlType.fromType(''), TransportControlType.unknown);
    });
  });

  // ---------------------------------------------------------------------------
  // TransportMetadata
  // ---------------------------------------------------------------------------
  group('TransportMetadata.toWire', () {
    test('includes only non-null fields', () {
      const meta = TransportMetadata(
        transportId: 'tx-1',
        probeRttMs: 42,
      );
      final wire = meta.toWire();
      expect(wire, {'transportId': 'tx-1', 'probeRttMs': 42});
      expect(wire.containsKey('pathId'), isFalse);
      expect(wire.containsKey('switchReason'), isFalse);
      expect(wire.containsKey('fallbackReason'), isFalse);
    });

    test('returns empty map when all fields are null', () {
      const meta = TransportMetadata();
      expect(meta.toWire(), isEmpty);
    });

    test('includes all fields when all are set', () {
      const meta = TransportMetadata(
        transportId: 'tx-2',
        pathId: 'p-1',
        switchReason: 'faster',
        fallbackReason: 'timeout',
        probeRttMs: 100,
      );
      expect(meta.toWire(), {
        'transportId': 'tx-2',
        'pathId': 'p-1',
        'switchReason': 'faster',
        'fallbackReason': 'timeout',
        'probeRttMs': 100,
      });
    });
  });

  group('TransportMetadata.fromWire', () {
    test('parses all fields', () {
      final meta = TransportMetadata.fromWire({
        'transportId': 'tx-3',
        'pathId': 'p-2',
        'switchReason': 'upgrade',
        'fallbackReason': 'lost',
        'probeRttMs': 55,
      });
      expect(meta.transportId, 'tx-3');
      expect(meta.pathId, 'p-2');
      expect(meta.switchReason, 'upgrade');
      expect(meta.fallbackReason, 'lost');
      expect(meta.probeRttMs, 55);
    });

    test('handles missing fields gracefully', () {
      final meta = TransportMetadata.fromWire(<String, dynamic>{});
      expect(meta.transportId, isNull);
      expect(meta.pathId, isNull);
      expect(meta.switchReason, isNull);
      expect(meta.fallbackReason, isNull);
      expect(meta.probeRttMs, isNull);
    });

    test('converts double RTT to int', () {
      final meta = TransportMetadata.fromWire({'probeRttMs': 12.7});
      expect(meta.probeRttMs, 12);
    });

    test('returns null RTT for non-numeric value', () {
      final meta = TransportMetadata.fromWire({'probeRttMs': 'fast'});
      expect(meta.probeRttMs, isNull);
    });
  });

  group('TransportMetadata round-trip', () {
    test('toWire then fromWire preserves data', () {
      const original = TransportMetadata(
        transportId: 'tx-rt',
        pathId: 'p-rt',
        switchReason: 'perf',
        fallbackReason: 'err',
        probeRttMs: 77,
      );
      final restored = TransportMetadata.fromWire(original.toWire());
      expect(restored.transportId, original.transportId);
      expect(restored.pathId, original.pathId);
      expect(restored.switchReason, original.switchReason);
      expect(restored.fallbackReason, original.fallbackReason);
      expect(restored.probeRttMs, original.probeRttMs);
    });

    test('round-trip with all-null fields stays null', () {
      const original = TransportMetadata();
      final restored = TransportMetadata.fromWire(original.toWire());
      expect(restored.transportId, isNull);
      expect(restored.probeRttMs, isNull);
    });
  });

  // ---------------------------------------------------------------------------
  // TransportCandidate
  // ---------------------------------------------------------------------------
  group('TransportCandidate', () {
    test('constructs with required fields and defaults', () {
      final c = TransportCandidate(
        id: 'c-1',
        kind: TransportKind.lanDirect,
        uri: Uri.parse('ws://10.0.0.1:8080'),
        waitForPairing: false,
      );
      expect(c.id, 'c-1');
      expect(c.kind, TransportKind.lanDirect);
      expect(c.uri.host, '10.0.0.1');
      expect(c.waitForPairing, isFalse);
      expect(c.priority, 0);
      expect(c.probeByConnect, isTrue);
    });

    test('accepts custom priority and probeByConnect', () {
      final c = TransportCandidate(
        id: 'c-2',
        kind: TransportKind.wormholeRelay,
        uri: Uri.parse('wss://relay.example.com'),
        waitForPairing: true,
        priority: 5,
        probeByConnect: false,
      );
      expect(c.priority, 5);
      expect(c.probeByConnect, isFalse);
      expect(c.waitForPairing, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // TransportProbeResult
  // ---------------------------------------------------------------------------
  group('TransportProbeResult', () {
    final candidate = TransportCandidate(
      id: 'pr-1',
      kind: TransportKind.wireguardDirect,
      uri: Uri.parse('udp://10.0.0.2:51820'),
      waitForPairing: false,
    );

    test('constructs a successful probe result', () {
      final result = TransportProbeResult(
        candidate: candidate,
        success: true,
        rtt: const Duration(milliseconds: 23),
      );
      expect(result.success, isTrue);
      expect(result.rtt, const Duration(milliseconds: 23));
      expect(result.error, isNull);
      expect(result.candidate.id, 'pr-1');
    });

    test('constructs a failed probe result with error', () {
      final result = TransportProbeResult(
        candidate: candidate,
        success: false,
        error: 'timeout',
      );
      expect(result.success, isFalse);
      expect(result.rtt, isNull);
      expect(result.error, 'timeout');
    });
  });

  // ---------------------------------------------------------------------------
  // TransportSelection
  // ---------------------------------------------------------------------------
  group('TransportSelection', () {
    final candidate = TransportCandidate(
      id: 'sel-1',
      kind: TransportKind.wormholeRelay,
      uri: Uri.parse('wss://relay.example.com/wg'),
      waitForPairing: true,
    );
    final probeResult = TransportProbeResult(
      candidate: candidate,
      success: true,
      rtt: const Duration(milliseconds: 10),
    );

    test('constructs with required fields only', () {
      final sel = TransportSelection(
        candidate: candidate,
        probeResult: probeResult,
        pathId: 'path-1',
      );
      expect(sel.candidate.id, 'sel-1');
      expect(sel.probeResult.success, isTrue);
      expect(sel.pathId, 'path-1');
      expect(sel.switchReason, isNull);
      expect(sel.fallbackReason, isNull);
      expect(sel.score, isNull);
    });

    test('constructs with all optional fields', () {
      final sel = TransportSelection(
        candidate: candidate,
        probeResult: probeResult,
        pathId: 'path-2',
        switchReason: 'lower-rtt',
        fallbackReason: 'primary-down',
        score: 95,
      );
      expect(sel.switchReason, 'lower-rtt');
      expect(sel.fallbackReason, 'primary-down');
      expect(sel.score, 95);
    });
  });
}
