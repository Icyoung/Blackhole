import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

const int _version = 1;
const int _typeStdin = 1;
const int _typeStdout = 2;

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln('Usage: dart test/voyager_lan_e2e.dart <ws://host:port>');
    exitCode = 2;
    return;
  }

  final uri = Uri.parse(args.first);
  final command = args.length > 1 ? args.sublist(1).join(' ') : 'echo VOYAGER_E2E_OK';
  final expected = 'VOYAGER_E2E_OK';

  final timeout = Duration(seconds: 12);
  final stdoutBuffer = StringBuffer();
  final sessionIdCompleter = Completer<String>();

  late final WebSocket socket;
  try {
    socket = await WebSocket.connect(uri.toString());
  } catch (error) {
    stderr.writeln('Failed to connect: $error');
    exitCode = 1;
    return;
  }

  Timer? watchdog;
  void fail(String message) {
    stderr.writeln(message);
    watchdog?.cancel();
    socket.close();
    exitCode = 1;
  }

  watchdog = Timer(timeout, () {
    fail('Timed out waiting for response from Horizon.');
  });

  socket.listen(
    (data) async {
      if (data is String) {
        final decoded = _decodeJson(data);
        if (decoded == null) {
          return;
        }
        final type = decoded['type'];
        if (type == 'session_list') {
          final sessions = decoded['sessions'];
          if (sessions is List && sessions.isNotEmpty) {
            final first = sessions.first;
            if (first is String && !sessionIdCompleter.isCompleted) {
              sessionIdCompleter.complete(first);
              _sendStdin(socket, first, '$command\n');
            }
          } else {
            socket.add(jsonEncode({'v': _version, 'type': 'create'}));
          }
        } else if (type == 'session_created') {
          final sessionId = decoded['sessionId'];
          if (sessionId is String && !sessionIdCompleter.isCompleted) {
            sessionIdCompleter.complete(sessionId);
            _sendStdin(socket, sessionId, '$command\n');
          }
        } else if (type == 'error') {
          fail('Server error: ${decoded['message']}');
        }
        return;
      }

      final decoded = _decodeBinary(data);
      if (decoded == null) {
        return;
      }
      if (decoded.type != _typeStdout) {
        return;
      }
      final text = utf8.decode(decoded.payload, allowMalformed: true);
      stdoutBuffer.write(text);
      if (stdoutBuffer.toString().contains(expected)) {
        watchdog?.cancel();
        stdout.writeln('E2E OK: received "$expected"');
        await socket.close();
      }
    },
    onError: (error) => fail('WebSocket error: $error'),
    onDone: () {
      if (!stdoutBuffer.toString().contains(expected)) {
        fail('Socket closed before expected output.');
      }
    },
  );

  socket.add(jsonEncode({'v': _version, 'type': 'list'}));
}

Map<String, dynamic>? _decodeJson(String data) {
  try {
    final decoded = jsonDecode(data);
    if (decoded is! Map) {
      return null;
    }
    return Map<String, dynamic>.from(decoded);
  } catch (_) {
    return null;
  }
}

void _sendStdin(WebSocket socket, String sessionId, String data) {
  final payload = _encodeBinary(_typeStdin, sessionId, utf8.encode(data));
  socket.add(payload);
}

Uint8List _encodeBinary(int type, String sessionId, List<int> data) {
  final sessionBytes = utf8.encode(sessionId);
  final buffer = BytesBuilder(copy: false)
    ..add([_version, type])
    ..add([
      (sessionBytes.length >> 8) & 0xFF,
      sessionBytes.length & 0xFF,
    ])
    ..add(sessionBytes)
    ..add(data);
  return buffer.toBytes();
}

_BinaryMessage? _decodeBinary(dynamic data) {
  if (data is! List<int>) {
    return null;
  }
  final bytes = Uint8List.fromList(data);
  if (bytes.length < 4 || bytes[0] != _version) {
    return null;
  }
  final type = bytes[1];
  final sessionLen = (bytes[2] << 8) | bytes[3];
  if (bytes.length < 4 + sessionLen) {
    return null;
  }
  final payload = bytes.sublist(4 + sessionLen);
  return _BinaryMessage(type, payload);
}

class _BinaryMessage {
  const _BinaryMessage(this.type, this.payload);

  final int type;
  final Uint8List payload;
}
