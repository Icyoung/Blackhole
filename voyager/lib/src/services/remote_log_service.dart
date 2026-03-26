import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

/// Intercepts debugPrint output and forwards log lines to Horizon
/// via the existing wormhole WebSocket as `{"type":"remote_log",...}` messages.
///
/// Horizon daemon writes these to `~/.blackhole/horizon/voyager-remote.log`.
///
/// Usage:
///   RemoteLogService.instance.start();          // in main()
///   RemoteLogService.instance.attach(channel);  // when WS connects
///
/// Monitor on Mac:
///   tail -f ~/.blackhole/horizon/voyager-remote.log
class RemoteLogService {
  RemoteLogService._();
  static final instance = RemoteLogService._();

  bool _started = false;
  WebSocketChannel? _channel;
  DebugPrintCallback? _originalDebugPrint;

  /// Ring buffer for lines sent before WS is attached.
  final List<String> _pending = [];
  static const int _maxPending = 200;

  void start() {
    if (_started) return;
    _started = true;
    _originalDebugPrint = debugPrint;
    debugPrint = _interceptedDebugPrint;
  }

  /// Attach a live wormhole WebSocket. Flushes pending buffer.
  void attach(WebSocketChannel channel) {
    _channel = channel;
    // Flush buffered lines.
    for (final line in _pending) {
      _send(line);
    }
    _pending.clear();
  }

  /// Detach when WebSocket disconnects.
  void detach() {
    _channel = null;
  }

  void _interceptedDebugPrint(String? message, {int? wrapWidth}) {
    _originalDebugPrint?.call(message, wrapWidth: wrapWidth);
    if (message == null) return;
    if (_channel != null) {
      _send(message);
    } else {
      _pending.add(message);
      if (_pending.length > _maxPending) _pending.removeAt(0);
    }
  }

  void _send(String line) {
    try {
      _channel?.sink.add(jsonEncode({
        'v': 1,
        'type': 'remote_log',
        'line': line,
      }));
    } catch (_) {}
  }

  /// Send a line that didn't go through debugPrint.
  void send(String line) {
    _interceptedDebugPrint(line);
  }

  void stop() {
    if (!_started) return;
    debugPrint = _originalDebugPrint ?? debugPrintThrottled;
    _channel = null;
    _started = false;
  }
}
