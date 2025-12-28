import 'dart:async';
import 'dart:io';

class WsServer {
  WsServer({required this.port, Duration? pingInterval})
      : _pingInterval = pingInterval;

  final int port;
  final Set<WebSocket> _clients = {};
  HttpServer? _server;
  final Duration? _pingInterval;
  void Function(int count)? onClientCount;
  void Function(WebSocket socket)? onClientConnected;

  Future<void> start({
    required Future<void> Function(WebSocket socket, dynamic message) onMessage,
  }) async {
    if (_server != null) {
      return;
    }
    _server = await HttpServer.bind(InternetAddress.anyIPv4, port);
    _server!.transform(WebSocketTransformer()).listen((socket) {
      if (_pingInterval != null) {
        socket.pingInterval = _pingInterval;
      }
      _clients.add(socket);
      _notifyClientCount();
      onClientConnected?.call(socket);
      socket.listen(
        (data) => onMessage(socket, data),
        onDone: () {
          _clients.remove(socket);
          _notifyClientCount();
        },
        onError: (_) {
          _clients.remove(socket);
          _notifyClientCount();
        },
      );
    });
  }

  void sendTo(WebSocket socket, Object message) {
    if (!_clients.contains(socket)) {
      return;
    }
    try {
      socket.add(message);
    } catch (_) {
      _clients.remove(socket);
      _notifyClientCount();
    }
  }

  void broadcast(Object message) {
    for (final client in _clients.toList()) {
      try {
        client.add(message);
      } catch (_) {
        _clients.remove(client);
      }
    }
    _notifyClientCount();
  }

  int get clientCount => _clients.length;

  Future<void> stop() async {
    for (final client in _clients) {
      try {
        await client.close();
      } catch (_) {}
    }
    _clients.clear();
    await _server?.close(force: true);
    _server = null;
    _notifyClientCount();
  }

  void _notifyClientCount() {
    onClientCount?.call(_clients.length);
  }
}
