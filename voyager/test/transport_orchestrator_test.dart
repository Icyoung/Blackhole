import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/transport_models.dart';
import 'package:voyager/src/services/transport_orchestrator.dart';

TransportCandidate _candidate({
  required String id,
  TransportKind kind = TransportKind.lanDirect,
  int priority = 0,
}) {
  return TransportCandidate(
    id: id,
    kind: kind,
    uri: Uri.parse('ws://10.0.0.1:9527/ws'),
    waitForPairing: false,
    priority: priority,
  );
}

TransportProbe _fakeProbe(Map<String, TransportProbeResult> results) {
  return (TransportCandidate candidate) async {
    return results[candidate.id]!;
  };
}

TransportProbeResult _probeResult({
  required TransportCandidate candidate,
  required bool success,
  Duration? rtt,
}) {
  return TransportProbeResult(
    candidate: candidate,
    success: success,
    rtt: rtt,
  );
}

void main() {
  group('TransportOrchestrator', () {
    test('selectBest with empty candidates returns null', () async {
      final orchestrator = TransportOrchestrator();

      final result = await orchestrator.selectBest(
        candidates: [],
        probe: (_) async => throw StateError('should not be called'),
      );

      expect(result, isNull);
    });

    test('selectBest with single successful candidate returns it', () async {
      final orchestrator = TransportOrchestrator();
      final c = _candidate(id: 'a');

      final result = await orchestrator.selectBest(
        candidates: [c],
        probe: _fakeProbe({
          'a': _probeResult(
            candidate: c,
            success: true,
            rtt: const Duration(milliseconds: 50),
          ),
        }),
      );

      expect(result, isNotNull);
      expect(result!.candidate.id, 'a');
      expect(result.pathId, 'lan_direct:a');
    });

    test('selectBest with single failed candidate returns null', () async {
      final orchestrator = TransportOrchestrator();
      final c = _candidate(id: 'a');

      final result = await orchestrator.selectBest(
        candidates: [c],
        probe: _fakeProbe({
          'a': _probeResult(candidate: c, success: false),
        }),
      );

      expect(result, isNull);
    });

    test('successful probes score higher than failed ones', () async {
      final orchestrator = TransportOrchestrator();
      final good = _candidate(id: 'good');
      final bad = _candidate(id: 'bad');

      final result = await orchestrator.selectBest(
        candidates: [bad, good],
        probe: _fakeProbe({
          'good': _probeResult(
            candidate: good,
            success: true,
            rtt: const Duration(milliseconds: 500),
          ),
          'bad': _probeResult(candidate: bad, success: false),
        }),
      );

      expect(result, isNotNull);
      expect(result!.candidate.id, 'good');
    });

    test('higher priority candidates score better', () async {
      final orchestrator = TransportOrchestrator();
      final low = _candidate(id: 'low', priority: 1);
      final high = _candidate(id: 'high', priority: 10);

      final result = await orchestrator.selectBest(
        candidates: [low, high],
        probe: _fakeProbe({
          'low': _probeResult(
            candidate: low,
            success: true,
            rtt: const Duration(milliseconds: 50),
          ),
          'high': _probeResult(
            candidate: high,
            success: true,
            rtt: const Duration(milliseconds: 50),
          ),
        }),
      );

      expect(result, isNotNull);
      expect(result!.candidate.id, 'high');
    });

    test('lower RTT scores better', () async {
      final orchestrator = TransportOrchestrator();
      final fast = _candidate(id: 'fast');
      final slow = _candidate(id: 'slow');

      final result = await orchestrator.selectBest(
        candidates: [slow, fast],
        probe: _fakeProbe({
          'fast': _probeResult(
            candidate: fast,
            success: true,
            rtt: const Duration(milliseconds: 10),
          ),
          'slow': _probeResult(
            candidate: slow,
            success: true,
            rtt: const Duration(milliseconds: 500),
          ),
        }),
      );

      expect(result, isNotNull);
      expect(result!.candidate.id, 'fast');
    });

    test('multiple candidates: best score wins', () async {
      final orchestrator = TransportOrchestrator();
      final a = _candidate(id: 'a', priority: 2);
      final b = _candidate(id: 'b', priority: 5);
      final c = _candidate(id: 'c', priority: 1);

      final result = await orchestrator.selectBest(
        candidates: [a, b, c],
        probe: _fakeProbe({
          'a': _probeResult(
            candidate: a,
            success: true,
            rtt: const Duration(milliseconds: 30),
          ),
          'b': _probeResult(
            candidate: b,
            success: true,
            rtt: const Duration(milliseconds: 40),
          ),
          'c': _probeResult(
            candidate: c,
            success: false,
          ),
        }),
      );

      expect(result, isNotNull);
      expect(result!.candidate.id, 'b');
    });

    test(
      'within hold window, only switch if score delta exceeds threshold',
      () async {
        final orchestrator = TransportOrchestrator(
          switchThresholdScore: 150,
          minHoldWindow: const Duration(seconds: 8),
        );
        final first = _candidate(id: 'first', priority: 5);
        final second = _candidate(id: 'second', priority: 5);

        // First selection establishes the hold window.
        final initial = await orchestrator.selectBest(
          candidates: [first],
          probe: _fakeProbe({
            'first': _probeResult(
              candidate: first,
              success: true,
              rtt: const Duration(milliseconds: 50),
            ),
          }),
        );
        expect(initial, isNotNull);
        expect(initial!.candidate.id, 'first');

        // Second call within the hold window: second candidate is only
        // slightly better (less RTT by 20ms, well under the 150 threshold).
        final suppressed = await orchestrator.selectBest(
          candidates: [first, second],
          probe: _fakeProbe({
            'first': _probeResult(
              candidate: first,
              success: true,
              rtt: const Duration(milliseconds: 50),
            ),
            'second': _probeResult(
              candidate: second,
              success: true,
              rtt: const Duration(milliseconds: 30),
            ),
          }),
        );

        // Should stick with the previous selection due to hysteresis.
        expect(suppressed, isNotNull);
        expect(suppressed!.candidate.id, 'first');
      },
    );

    test(
      'within hold window, switch happens when score delta exceeds threshold',
      () async {
        final orchestrator = TransportOrchestrator(
          switchThresholdScore: 150,
          minHoldWindow: const Duration(seconds: 8),
        );
        final first = _candidate(id: 'first', priority: 1);
        final second = _candidate(id: 'second', priority: 5);

        // Establish hold window with first candidate.
        final initial = await orchestrator.selectBest(
          candidates: [first],
          probe: _fakeProbe({
            'first': _probeResult(
              candidate: first,
              success: true,
              rtt: const Duration(milliseconds: 200),
            ),
          }),
        );
        expect(initial!.candidate.id, 'first');

        // Second candidate is much better: priority 5 vs 1 => +400 bonus,
        // and RTT 10 vs 200 => +190 advantage. Total delta = 590, well
        // above threshold of 150.
        final switched = await orchestrator.selectBest(
          candidates: [first, second],
          probe: _fakeProbe({
            'first': _probeResult(
              candidate: first,
              success: true,
              rtt: const Duration(milliseconds: 200),
            ),
            'second': _probeResult(
              candidate: second,
              success: true,
              rtt: const Duration(milliseconds: 10),
            ),
          }),
        );

        expect(switched, isNotNull);
        expect(switched!.candidate.id, 'second');
        expect(switched.switchReason, 'rtt_better');
      },
    );

    test(
      'after hold window expires, any better candidate can win',
      () async {
        final orchestrator = TransportOrchestrator(
          switchThresholdScore: 150,
          // Use a zero-length hold window so it expires immediately.
          minHoldWindow: Duration.zero,
        );
        final first = _candidate(id: 'first', priority: 5);
        final second = _candidate(id: 'second', priority: 5);

        // Establish selection.
        final initial = await orchestrator.selectBest(
          candidates: [first],
          probe: _fakeProbe({
            'first': _probeResult(
              candidate: first,
              success: true,
              rtt: const Duration(milliseconds: 100),
            ),
          }),
        );
        expect(initial!.candidate.id, 'first');

        // With zero hold window, even a tiny improvement switches.
        final switched = await orchestrator.selectBest(
          candidates: [first, second],
          probe: _fakeProbe({
            'first': _probeResult(
              candidate: first,
              success: true,
              rtt: const Duration(milliseconds: 100),
            ),
            'second': _probeResult(
              candidate: second,
              success: true,
              rtt: const Duration(milliseconds: 80),
            ),
          }),
        );

        expect(switched, isNotNull);
        expect(switched!.candidate.id, 'second');
      },
    );

    test('null RTT uses rttWeight as penalty', () async {
      final orchestrator = TransportOrchestrator(rttWeight: 1000);
      final withRtt = _candidate(id: 'with_rtt');
      final withoutRtt = _candidate(id: 'without_rtt');

      final result = await orchestrator.selectBest(
        candidates: [withRtt, withoutRtt],
        probe: _fakeProbe({
          'with_rtt': _probeResult(
            candidate: withRtt,
            success: true,
            rtt: const Duration(milliseconds: 50),
          ),
          'without_rtt': _probeResult(
            candidate: withoutRtt,
            success: true,
            rtt: null,
          ),
        }),
      );

      // with_rtt penalty=50, without_rtt penalty=1000 (rttWeight default).
      // So with_rtt should win.
      expect(result, isNotNull);
      expect(result!.candidate.id, 'with_rtt');
    });

    test('pathId format includes kind wireName and candidate id', () async {
      final orchestrator = TransportOrchestrator();
      final c = _candidate(
        id: 'relay-1',
        kind: TransportKind.wormholeRelay,
      );

      final result = await orchestrator.selectBest(
        candidates: [c],
        probe: _fakeProbe({
          'relay-1': _probeResult(
            candidate: c,
            success: true,
            rtt: const Duration(milliseconds: 20),
          ),
        }),
      );

      expect(result!.pathId, 'wormhole_relay:relay-1');
    });

    test('switchReason is null when reselecting same candidate', () async {
      final orchestrator = TransportOrchestrator(
        minHoldWindow: Duration.zero,
      );
      final c = _candidate(id: 'stable');

      final first = await orchestrator.selectBest(
        candidates: [c],
        probe: _fakeProbe({
          'stable': _probeResult(
            candidate: c,
            success: true,
            rtt: const Duration(milliseconds: 20),
          ),
        }),
      );
      expect(first!.switchReason, isNull);

      final second = await orchestrator.selectBest(
        candidates: [c],
        probe: _fakeProbe({
          'stable': _probeResult(
            candidate: c,
            success: true,
            rtt: const Duration(milliseconds: 25),
          ),
        }),
      );
      expect(second!.switchReason, isNull);
    });

    test('all candidates failing returns null', () async {
      final orchestrator = TransportOrchestrator();
      final a = _candidate(id: 'a');
      final b = _candidate(id: 'b');

      final result = await orchestrator.selectBest(
        candidates: [a, b],
        probe: _fakeProbe({
          'a': _probeResult(candidate: a, success: false),
          'b': _probeResult(candidate: b, success: false),
        }),
      );

      expect(result, isNull);
    });

    test(
      'hold window retains previous selection even when previous candidate '
      'is absent from new round',
      () async {
        final orchestrator = TransportOrchestrator(
          switchThresholdScore: 150,
          minHoldWindow: const Duration(seconds: 8),
        );
        final first = _candidate(id: 'first', priority: 5);
        final second = _candidate(id: 'second', priority: 5);

        // Establish selection with first.
        await orchestrator.selectBest(
          candidates: [first],
          probe: _fakeProbe({
            'first': _probeResult(
              candidate: first,
              success: true,
              rtt: const Duration(milliseconds: 50),
            ),
          }),
        );

        // Second round only has 'second', which is marginally better.
        // Previous candidate 'first' is absent, so its score falls back to
        // the stored score. Delta should be small => stick with previous.
        final result = await orchestrator.selectBest(
          candidates: [second],
          probe: _fakeProbe({
            'second': _probeResult(
              candidate: second,
              success: true,
              rtt: const Duration(milliseconds: 40),
            ),
          }),
        );

        expect(result, isNotNull);
        expect(result!.candidate.id, 'first');
      },
    );
  });
}
