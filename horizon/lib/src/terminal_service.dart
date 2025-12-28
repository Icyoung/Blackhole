import 'dart:typed_data';

import 'package:flutter/services.dart';

class TerminalOutput {
  TerminalOutput({required this.sessionId, required this.data});

  final String sessionId;
  final Uint8List data;
}

class TerminalPlugin {
  static const MethodChannel _channel = MethodChannel('com.blackhole/pty');
  static const EventChannel _outputChannel =
      EventChannel('com.blackhole/pty/output');

  Stream<TerminalOutput> get outputStream {
    return _outputChannel.receiveBroadcastStream().map((event) {
      final map = Map<String, dynamic>.from(event as Map);
      final sessionId = map['sessionId'] as String? ?? '';
      final data = map['data'] as Uint8List? ?? Uint8List(0);
      return TerminalOutput(sessionId: sessionId, data: data);
    });
  }

  Future<String> startShell({
    required int rows,
    required int cols,
    String? shellPath,
  }) async {
    final sessionId = await _channel.invokeMethod<String>('startShell', {
      'rows': rows,
      'cols': cols,
      if (shellPath != null) 'shellPath': shellPath,
    });
    if (sessionId == null || sessionId.isEmpty) {
      throw StateError('Failed to start shell session');
    }
    return sessionId;
  }

  Future<void> writeStdin(String sessionId, Uint8List data) async {
    await _channel.invokeMethod<void>('writeStdin', {
      'sessionId': sessionId,
      'data': data,
    });
  }

  Future<void> resize(String sessionId, int rows, int cols) async {
    await _channel.invokeMethod<void>('resize', {
      'sessionId': sessionId,
      'rows': rows,
      'cols': cols,
    });
  }

  Future<void> kill(String sessionId) async {
    await _channel.invokeMethod<void>('kill', {
      'sessionId': sessionId,
    });
  }
}
