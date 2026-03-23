import 'package:flutter_test/flutter_test.dart';
import 'package:horizon/src/services/session_gateway.dart';
import 'package:horizon/src/services/transport_models.dart';

void main() {
  group('SessionGateway', () {
    GatewayIngressContext makeContext({
      GatewayIngressSource source = GatewayIngressSource.wormhole,
      TransportKind transportKind = TransportKind.wormholeRelay,
      String? transportId,
      String? pathId,
    }) {
      return GatewayIngressContext(
        source: source,
        transportKind: transportKind,
        socket: null,
        transportId: transportId,
        pathId: pathId,
      );
    }

    test('handle ignores null decoded message', () async {
      var decodedCalled = false;
      var unsupportedCalled = false;

      final gateway = SessionGateway(
        decodeIncoming: (_) => null,
        onDecoded: (ctx, decoded) async {
          decodedCalled = true;
        },
        onUnsupported: (ctx, decoded) {
          unsupportedCalled = true;
        },
      );

      await gateway.handle(makeContext(), 'raw message');

      expect(decodedCalled, isFalse);
      expect(unsupportedCalled, isFalse);
    });

    test('handle routes unsupported type to onUnsupported', () async {
      var unsupportedCalled = false;
      Map<String, dynamic>? receivedDecoded;

      final gateway = SessionGateway(
        decodeIncoming: (_) => {'type': 'unsupported', 'data': 'test'},
        onDecoded: (ctx, decoded) async {},
        onUnsupported: (ctx, decoded) {
          unsupportedCalled = true;
          receivedDecoded = decoded;
        },
      );

      await gateway.handle(makeContext(), 'raw');

      expect(unsupportedCalled, isTrue);
      expect(receivedDecoded?['type'], 'unsupported');
      expect(receivedDecoded?['data'], 'test');
    });

    test('handle enriches decoded message with transport metadata', () async {
      Map<String, dynamic>? receivedDecoded;

      final gateway = SessionGateway(
        decodeIncoming: (_) => {'type': 'terminal_data', 'data': 'ls'},
        onDecoded: (ctx, decoded) async {
          receivedDecoded = decoded;
        },
        onUnsupported: (ctx, decoded) {},
      );

      final context = makeContext(
        transportKind: TransportKind.lanDirect,
        transportId: 'txp-123',
        pathId: 'path-456',
      );

      await gateway.handle(context, 'raw');

      expect(receivedDecoded?['type'], 'terminal_data');
      expect(receivedDecoded?['transportKind'], 'lan_direct');
      expect(receivedDecoded?['transportId'], 'txp-123');
      expect(receivedDecoded?['pathId'], 'path-456');
    });

    test('handle does not add transportId when context has null transportId', () async {
      Map<String, dynamic>? receivedDecoded;

      final gateway = SessionGateway(
        decodeIncoming: (_) => {'type': 'data'},
        onDecoded: (ctx, decoded) async {
          receivedDecoded = decoded;
        },
        onUnsupported: (ctx, decoded) {},
      );

      await gateway.handle(makeContext(transportId: null, pathId: null), 'raw');

      expect(receivedDecoded?.containsKey('transportKind'), isTrue);
      expect(receivedDecoded?.containsKey('transportId'), isFalse);
      expect(receivedDecoded?.containsKey('pathId'), isFalse);
    });

    test('putIfAbsent does not override existing transportKind', () async {
      Map<String, dynamic>? receivedDecoded;

      final gateway = SessionGateway(
        decodeIncoming: (_) => {
          'type': 'data',
          'transportKind': 'wireguard_direct', // already set
        },
        onDecoded: (ctx, decoded) async {
          receivedDecoded = decoded;
        },
        onUnsupported: (ctx, decoded) {},
      );

      final context = makeContext(
        transportKind: TransportKind.wormholeRelay,
        transportId: 'txp-1',
      );

      await gateway.handle(context, 'raw');

      // Should keep the original value, not override with context
      expect(receivedDecoded?['transportKind'], 'wireguard_direct');
    });

    test('putIfAbsent does not override existing transportId', () async {
      Map<String, dynamic>? receivedDecoded;

      final gateway = SessionGateway(
        decodeIncoming: (_) => {
          'type': 'data',
          'transportId': 'original-txp',
        },
        onDecoded: (ctx, decoded) async {
          receivedDecoded = decoded;
        },
        onUnsupported: (ctx, decoded) {},
      );

      final context = makeContext(
        transportId: 'context-txp',
        pathId: 'context-path',
      );

      await gateway.handle(context, 'raw');

      expect(receivedDecoded?['transportId'], 'original-txp');
      expect(receivedDecoded?['pathId'], 'context-path'); // new, so added
    });

    test('handle passes correct context to onDecoded', () async {
      GatewayIngressContext? receivedContext;

      final gateway = SessionGateway(
        decodeIncoming: (_) => {'type': 'data'},
        onDecoded: (ctx, decoded) async {
          receivedContext = ctx;
        },
        onUnsupported: (ctx, decoded) {},
      );

      final context = makeContext(
        source: GatewayIngressSource.lan,
        transportKind: TransportKind.lanDirect,
      );

      await gateway.handle(context, 'raw');

      expect(receivedContext?.source, GatewayIngressSource.lan);
      expect(receivedContext?.transportKind, TransportKind.lanDirect);
    });

    test('handle responds to health check without calling onDecoded', () async {
      var decodedCalled = false;
      var unsupportedCalled = false;

      final gateway = SessionGateway(
        decodeIncoming: (_) => {'type': 'health'},
        onDecoded: (ctx, decoded) async {
          decodedCalled = true;
        },
        onUnsupported: (ctx, decoded) {
          unsupportedCalled = true;
        },
      );

      await gateway.handle(makeContext(), 'raw');

      expect(decodedCalled, isFalse);
      expect(unsupportedCalled, isFalse);
    });

    test('handle passes raw message to decodeIncoming', () async {
      dynamic receivedRaw;

      final gateway = SessionGateway(
        decodeIncoming: (msg) {
          receivedRaw = msg;
          return null;
        },
        onDecoded: (ctx, decoded) async {},
        onUnsupported: (ctx, decoded) {},
      );

      await gateway.handle(makeContext(), 'the raw payload');

      expect(receivedRaw, 'the raw payload');
    });
  });

  group('GatewayIngressContext', () {
    test('stores all fields correctly', () {
      final context = GatewayIngressContext(
        source: GatewayIngressSource.lan,
        transportKind: TransportKind.lanDirect,
        socket: null,
        transportId: 'txp-1',
        pathId: 'path-1',
      );

      expect(context.source, GatewayIngressSource.lan);
      expect(context.transportKind, TransportKind.lanDirect);
      expect(context.socket, isNull);
      expect(context.transportId, 'txp-1');
      expect(context.pathId, 'path-1');
    });
  });

  group('GatewayIngressSource', () {
    test('has expected values', () {
      expect(GatewayIngressSource.values.length, 2);
      expect(GatewayIngressSource.values, contains(GatewayIngressSource.lan));
      expect(GatewayIngressSource.values, contains(GatewayIngressSource.wormhole));
    });
  });
}
