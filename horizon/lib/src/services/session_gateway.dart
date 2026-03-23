import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'transport_models.dart';

enum GatewayIngressSource { lan, wormhole }

class GatewayIngressContext {
  const GatewayIngressContext({
    required this.source,
    required this.transportKind,
    this.socket,
    this.transportId,
    this.pathId,
  });

  final GatewayIngressSource source;
  final TransportKind transportKind;
  final WebSocket? socket;
  final String? transportId;
  final String? pathId;
}

typedef GatewayDecodeIncoming = Map<String, dynamic>? Function(dynamic message);
typedef GatewayOnDecoded =
    Future<void> Function(
      GatewayIngressContext context,
      Map<String, dynamic> decoded,
    );
typedef GatewayOnUnsupported =
    void Function(GatewayIngressContext context, Map<String, dynamic> decoded);

class SessionGateway {
  SessionGateway({
    required GatewayDecodeIncoming decodeIncoming,
    required GatewayOnDecoded onDecoded,
    required GatewayOnUnsupported onUnsupported,
  }) : _decodeIncoming = decodeIncoming,
       _onDecoded = onDecoded,
       _onUnsupported = onUnsupported;

  final GatewayDecodeIncoming _decodeIncoming;
  final GatewayOnDecoded _onDecoded;
  final GatewayOnUnsupported _onUnsupported;

  Future<void> handle(GatewayIngressContext context, dynamic message) async {
    final decoded = _decodeIncoming(message);
    if (decoded == null) {
      return;
    }
    if (decoded['type'] == 'unsupported') {
      _onUnsupported(context, decoded);
      return;
    }

    // Respond to health checks directly so monitors get a 200-equivalent ack.
    if (decoded['type'] == 'health') {
      final socket = context.socket;
      if (socket != null) {
        socket.add(jsonEncode({'type': 'health', 'status': 'ok'}));
      }
      return;
    }

    decoded.putIfAbsent('transportKind', () => context.transportKind.wireName);
    if (context.transportId != null) {
      decoded.putIfAbsent('transportId', () => context.transportId);
    }
    if (context.pathId != null) {
      decoded.putIfAbsent('pathId', () => context.pathId);
    }
    await _onDecoded(context, decoded);
  }
}
