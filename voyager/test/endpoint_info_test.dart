import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/connection_manager.dart';

void main() {
  group('EndpointInfo.mergeWith', () {
    test(
      'retains prior explicit IP netcheck when later config regresses to domain',
      () {
        const previous = EndpointInfo(
          netcheckHost: '38.60.162.209',
          netcheckPort: 6666,
          wgRelayUrl: 'wss://wormhole.blackhole-ai.com/ws',
        );
        const current = EndpointInfo(
          netcheckHost: 'wormhole.blackhole-ai.com',
          netcheckPort: 6666,
          wgRelayUrl: 'wss://wormhole.blackhole-ai.com/ws',
        );

        final merged = current.mergeWith(previous);

        expect(merged.netcheckHost, '38.60.162.209');
        expect(merged.netcheckPort, 6666);
      },
    );

    test(
      'accepts newer explicit IP netcheck when previous value was absent',
      () {
        const previous = EndpointInfo(
          wgRelayUrl: 'wss://wormhole.blackhole-ai.com/ws',
        );
        const current = EndpointInfo(
          netcheckHost: '38.60.162.209',
          netcheckPort: 6666,
        );

        final merged = current.mergeWith(previous);

        expect(merged.netcheckHost, '38.60.162.209');
        expect(merged.netcheckPort, 6666);
      },
    );

    test('accepts newer explicit IP netcheck over previous explicit IP', () {
      const previous = EndpointInfo(
        netcheckHost: '38.60.162.209',
        netcheckPort: 6666,
      );
      const current = EndpointInfo(
        netcheckHost: '203.0.113.10',
        netcheckPort: 7777,
      );

      final merged = current.mergeWith(previous);

      expect(merged.netcheckHost, '203.0.113.10');
      expect(merged.netcheckPort, 7777);
    });

    test(
      'preserves prior public observed horizon candidate when later config regresses',
      () {
        const previous = EndpointInfo(
          horizonCandidates: <DirectCandidate>[
            DirectCandidate(
              addr: '14.153.180.50',
              port: 51820,
              scope: 'public_observed',
              priority: 180,
              source: 'wormhole_observed',
            ),
          ],
        );
        const current = EndpointInfo(
          horizonCandidates: <DirectCandidate>[
            DirectCandidate(
              addr: '192.168.1.219',
              port: 51820,
              scope: 'lan',
              priority: 250,
              source: 'local_interface:en0',
            ),
          ],
        );

        final merged = current.mergeWith(previous);

        expect(merged.horizonCandidates, isNotNull);
        expect(merged.horizonCandidates, hasLength(2));
        expect(merged.horizonCandidates!.first.addr, '192.168.1.219');
        expect(
          merged.horizonCandidates!.any(
            (candidate) =>
                candidate.addr == '14.153.180.50' &&
                candidate.port == 51820 &&
                candidate.scope == 'public_observed',
          ),
          isTrue,
        );
      },
    );
  });
}
