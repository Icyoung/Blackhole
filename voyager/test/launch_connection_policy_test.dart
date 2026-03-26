import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/launch_connection_policy.dart';

void main() {
  group('evaluateAutoConnectOnLaunch', () {
    test('reports why wormhole auto-connect is allowed', () {
      final decision = evaluateAutoConnectOnLaunch(
        autoReconnect: true,
        alreadyConnected: false,
        useWormhole: true,
        sessionId: 'ICY123',
        lanAddress: 'ws://127.0.0.1:9529/ws',
        wormholeAddress: 'wss://wormhole.blackhole-ai.com/ws',
      );

      expect(decision.shouldConnect, isTrue);
      expect(decision.reason, 'wormhole_ready');
    });

    test('reports why wormhole auto-connect is blocked', () {
      final decision = evaluateAutoConnectOnLaunch(
        autoReconnect: true,
        alreadyConnected: false,
        useWormhole: true,
        sessionId: ' ',
        lanAddress: 'ws://127.0.0.1:9529/ws',
        wormholeAddress: 'wss://wormhole.blackhole-ai.com/ws',
      );

      expect(decision.shouldConnect, isFalse);
      expect(decision.reason, 'wormhole_session_missing');
    });
  });

  group('shouldAutoConnectOnLaunch', () {
    test('requires autoReconnect to be enabled', () {
      final result = shouldAutoConnectOnLaunch(
        autoReconnect: false,
        alreadyConnected: false,
        useWormhole: true,
        sessionId: 'ICY123',
        lanAddress: 'ws://127.0.0.1:9529/ws',
        wormholeAddress: 'wss://wormhole.blackhole-ai.com/ws',
      );

      expect(result, isFalse);
    });

    test('requires a wormhole session when wormhole is enabled', () {
      final result = shouldAutoConnectOnLaunch(
        autoReconnect: true,
        alreadyConnected: false,
        useWormhole: true,
        sessionId: '   ',
        lanAddress: 'ws://127.0.0.1:9529/ws',
        wormholeAddress: 'wss://wormhole.blackhole-ai.com/ws',
      );

      expect(result, isFalse);
    });

    test('allows wormhole auto-connect when persisted config is complete', () {
      final result = shouldAutoConnectOnLaunch(
        autoReconnect: true,
        alreadyConnected: false,
        useWormhole: true,
        sessionId: 'ICY123',
        lanAddress: 'ws://127.0.0.1:9529/ws',
        wormholeAddress: 'wss://wormhole.blackhole-ai.com/ws',
      );

      expect(result, isTrue);
    });

    test('allows lan auto-connect without a wormhole session', () {
      final result = shouldAutoConnectOnLaunch(
        autoReconnect: true,
        alreadyConnected: false,
        useWormhole: false,
        sessionId: '',
        lanAddress: 'ws://127.0.0.1:9527/ws',
        wormholeAddress: '',
      );

      expect(result, isTrue);
    });
  });
}
