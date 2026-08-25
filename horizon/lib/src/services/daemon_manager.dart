import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:cryptography/cryptography.dart';

class DaemonStatus {
  DaemonStatus({
    required this.configId,
    required this.hostName,
    required this.lanBind,
    required this.lanPort,
    required this.lanClients,
    required this.wormholeUrl,
    required this.wormholeConnected,
    required this.wormholeSessionId,
    required this.wormholeRequestedSession,
    required this.wormholeHasToken,
    required this.vpnRunning,
    required this.sessionCount,
  });

  final String? configId;
  final String? hostName;
  final String? lanBind;
  final int? lanPort;
  final int lanClients;
  final String? wormholeUrl;
  final bool wormholeConnected;
  final String? wormholeSessionId;
  final String? wormholeRequestedSession;
  final bool wormholeHasToken;
  final bool vpnRunning;
  final int sessionCount;
}

class DaemonManager {
  Process? _process;
  String? _lastConfigKey;
  static const String _defaultVpnWebsocketBind = '10.13.37.1';
  IOSink? _daemonLogSink;

  static String? _normalizeNullable(String? value) {
    final v = value?.trim();
    if (v == null || v.isEmpty) {
      return null;
    }
    return v;
  }

  static Future<String> _computeConfigId({
    required String bindHost,
    required int port,
    required String hostName,
    required bool devMode,
    required bool vpnRequired,
    required String? wormholeUrl,
    required String? wormholeToken,
    required String? wormholeSession,
  }) async {
    final canonical =
        'bind=$bindHost;port=$port;host=${hostName.trim()};devMode=$devMode;vpn=$vpnRequired;vpnWsBind=${vpnRequired ? _defaultVpnWebsocketBind : ""};wormholeUrl=${wormholeUrl ?? ""};wormholeSession=${wormholeSession ?? ""};wormholeToken=${wormholeToken ?? ""}';
    final digest = await Sha256().hash(utf8.encode(canonical));
    final hex =
        digest.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    // Keep it short; this is only for local mismatch detection.
    return 'v1:$hex';
  }

  static File _pidFile() {
    final home = Platform.environment['HOME'] ?? '';
    final base = home.isNotEmpty ? home : Directory.systemTemp.path;
    return File('$base/.blackhole/horizon/daemon.pid');
  }

  static File _daemonLogFile() {
    final home = Platform.environment['HOME'] ?? '';
    final base = home.isNotEmpty ? home : Directory.systemTemp.path;
    return File('$base/.blackhole/horizon/daemon.log');
  }

  static Future<void> _killDaemonByPid() async {
    try {
      final text = await _pidFile().readAsString();
      final pid = int.tryParse(text.trim());
      if (pid == null || pid <= 0) {
        return;
      }
      try {
        Process.killPid(pid, ProcessSignal.sigterm);
      } catch (_) {
        // Windows/macOS might not support sigterm in some contexts; best-effort.
        try {
          Process.killPid(pid);
        } catch (_) {}
      }

      final deadline = DateTime.now().add(const Duration(seconds: 2));
      while (DateTime.now().isBefore(deadline)) {
        if (!await _pidFile().exists()) {
          break;
        }
        await Future.delayed(const Duration(milliseconds: 120));
      }
    } catch (_) {
      // Ignore - pid file may not exist.
    }
  }

  Future<bool> shutdown(Uri wsUri) async {
    final uri = _httpUriFromWs(wsUri, '/shutdown');
    final client =
        HttpClient()..connectionTimeout = const Duration(milliseconds: 800);
    try {
      final req = await client.postUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 1));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<String?> tryGetPendingPairingDeviceName(Uri wsUri) async {
    final uri = _httpUriFromWs(wsUri, '/pairing/pending');
    final client =
        HttpClient()..connectionTimeout = const Duration(milliseconds: 600);
    try {
      final req = await client.getUrl(uri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(milliseconds: 800));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return null;
      }
      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      if (json is! Map) {
        return null;
      }
      final pending = json['pending'];
      if (pending is Map) {
        final map = Map<String, dynamic>.from(pending);
        final name = map['deviceName'];
        if (name is String && name.trim().isNotEmpty) {
          return name;
        }
        return 'Unknown Device';
      }
      return null;
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> approvePairing(Uri wsUri, {required bool remember}) async {
    final uri = _httpUriFromWs(wsUri, '/pairing/approve');
    final client =
        HttpClient()..connectionTimeout = const Duration(milliseconds: 800);
    try {
      final req = await client.postUrl(uri);
      req.headers.contentType = ContentType.json;
      req.add(utf8.encode(jsonEncode({'remember': remember})));
      final res = await req.close().timeout(const Duration(seconds: 1));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> rejectPairing(Uri wsUri) async {
    final uri = _httpUriFromWs(wsUri, '/pairing/reject');
    final client =
        HttpClient()..connectionTimeout = const Duration(milliseconds: 800);
    try {
      final req = await client.postUrl(uri);
      final res = await req.close().timeout(const Duration(seconds: 1));
      return res.statusCode >= 200 && res.statusCode < 300;
    } catch (_) {
      return false;
    } finally {
      client.close(force: true);
    }
  }

  Future<DaemonStatus?> tryGetStatus(Uri wsUri) async {
    final statusUri = _httpUriFromWs(wsUri, '/status');
    final client =
        HttpClient()..connectionTimeout = const Duration(milliseconds: 600);
    try {
      final req = await client.getUrl(statusUri);
      req.headers.set(HttpHeaders.acceptHeader, 'application/json');
      final res = await req.close().timeout(const Duration(milliseconds: 800));
      if (res.statusCode < 200 || res.statusCode >= 300) {
        return null;
      }
      final body = await res.transform(utf8.decoder).join();
      final json = jsonDecode(body);
      if (json is! Map) {
        return null;
      }
      final map = Map<String, dynamic>.from(json);
      final lan =
          map['lan'] is Map
              ? Map<String, dynamic>.from(map['lan'] as Map)
              : const {};
      final wormhole =
          map['wormhole'] is Map
              ? Map<String, dynamic>.from(map['wormhole'] as Map)
              : const {};
      final vpn =
          map['vpn'] is Map
              ? Map<String, dynamic>.from(map['vpn'] as Map)
              : const {};

      return DaemonStatus(
        configId: map['configId'] as String?,
        hostName: map['hostName'] as String?,
        lanBind: lan['bind'] as String?,
        lanPort: lan['port'] as int?,
        lanClients: lan['clients'] as int? ?? 0,
        wormholeUrl: wormhole['url'] as String?,
        wormholeConnected: wormhole['connected'] as bool? ?? false,
        wormholeSessionId: wormhole['sessionId'] as String?,
        wormholeRequestedSession: wormhole['requestedSession'] as String?,
        wormholeHasToken: wormhole['hasToken'] as bool? ?? false,
        vpnRunning: vpn['running'] as bool? ?? false,
        sessionCount: map['sessions'] as int? ?? 0,
      );
    } catch (_) {
      return null;
    } finally {
      client.close(force: true);
    }
  }

  Future<bool> isRunning(Uri wsUri) async {
    final status = await tryGetStatus(wsUri);
    return status != null;
  }

  Future<bool> ensureRunning({
    required Uri wsUri,
    required String hostName,
    required bool devMode,
    bool vpnRequired = false,
    String? wormholeUrl,
    String? wormholeToken,
    String? wormholeSession,
    String? bindHost,
  }) async {
    if (!isLocalWs(wsUri)) {
      return false;
    }
    final desiredWormholeUrl = _normalizeNullable(wormholeUrl);
    final desiredWormholeToken = _normalizeNullable(wormholeToken);
    final desiredWormholeSession = _normalizeNullable(wormholeSession);
    final desiredHostName = hostName.trim();
    var desiredBindHost = _resolveBindHost(bindHost ?? wsUri.host);
    final desiredPort = wsUri.hasPort ? wsUri.port : 9527;
    final desiredConfigId = await _computeConfigId(
      bindHost: desiredBindHost,
      port: desiredPort,
      hostName: desiredHostName,
      devMode: devMode,
      vpnRequired: vpnRequired,
      wormholeUrl: desiredWormholeUrl,
      wormholeToken: desiredWormholeToken,
      wormholeSession: desiredWormholeSession,
    );

    final status = await tryGetStatus(wsUri);
    if (status != null) {
      final statusConfigId = _normalizeNullable(status.configId);
      final configMismatch =
          statusConfigId == null || statusConfigId != desiredConfigId;
      final hostMismatch =
          _normalizeNullable(status.hostName) != desiredHostName;
      final bindMismatch =
          _normalizeNullable(status.lanBind) !=
          _normalizeNullable(desiredBindHost);
      final tokenPresenceMismatch =
          status.wormholeHasToken != (desiredWormholeToken != null);
      final requestedSessionMismatch =
          _normalizeNullable(status.wormholeRequestedSession) !=
          _normalizeNullable(desiredWormholeSession);
      final urlMismatch =
          _normalizeNullable(status.wormholeUrl) !=
          _normalizeNullable(desiredWormholeUrl);
      final vpnMismatch = status.vpnRunning != vpnRequired;

      if (configMismatch ||
          hostMismatch ||
          bindMismatch ||
          tokenPresenceMismatch ||
          requestedSessionMismatch ||
          urlMismatch ||
          vpnMismatch) {
        debugPrint('[Daemon] Config changed. Restarting daemon.');
        await shutdown(wsUri);
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (DateTime.now().isBefore(deadline)) {
          if (await tryGetStatus(wsUri) == null) {
            break;
          }
          await Future.delayed(const Duration(milliseconds: 120));
        }
      } else {
        _lastConfigKey ??= desiredConfigId;
        return true;
      }
    } else {
      // Port/bind changes make the current daemon unreachable at the desired wsUri.
      // If a daemon is already running (pid file exists), stop it so we can start
      // a new instance with the updated config.
      if (await _pidFile().exists()) {
        await _killDaemonByPid();
      }
    }

    final bin = _resolveDaemonPath();
    if (bin == null) {
      debugPrint(
        '[Daemon] Cannot locate horizon-daemon binary. Set HORIZON_DAEMON_PATH.',
      );
      return false;
    }

    final port = desiredPort;

    final args = <String>[
      '--bind',
      desiredBindHost,
      '--port',
      '$port',
      '--host-name',
      hostName,
      if (vpnRequired) '--vpn',
      if (devMode) '--dev-mode',
      '--config-id',
      desiredConfigId,
      if (desiredWormholeSession != null) ...[
        '--wormhole-session',
        desiredWormholeSession,
      ],
    ];

    final env = <String, String>{};
    if (desiredWormholeUrl != null) {
      env['WORMHOLE_URL'] = desiredWormholeUrl;
      env['WORMHOLE_NETCHECK_PORT'] = '6666';
      final netcheckHost = Uri.tryParse(desiredWormholeUrl)?.host;
      if (netcheckHost != null && netcheckHost.isNotEmpty) {
        env['WORMHOLE_NETCHECK_HOST'] = netcheckHost;
      }
    }
    if (desiredWormholeToken != null) {
      env['WORMHOLE_TOKEN'] = desiredWormholeToken;
    }

    debugPrint('[Daemon] Starting: $bin ${args.join(" ")}');
    try {
      final logFile = _daemonLogFile();
      await logFile.parent.create(recursive: true);
      _daemonLogSink?.close();
      _daemonLogSink = logFile.openWrite(mode: FileMode.append);
      _daemonLogSink!.writeln(
        '===== ${DateTime.now().toUtc().toIso8601String()} starting: $bin ${args.join(" ")} =====',
      );
      _process = await Process.start(
        bin,
        args,
        environment: env.isEmpty ? null : env,
        mode: ProcessStartMode.detachedWithStdio,
      );
      _process!.stdout.transform(utf8.decoder).listen((chunk) {
        _daemonLogSink?.write(chunk);
        debugPrint('[Daemon] $chunk');
      });
      _process!.stderr.transform(utf8.decoder).listen((chunk) {
        _daemonLogSink?.write(chunk);
        debugPrint('[Daemon][err] $chunk');
      });
    } catch (e) {
      debugPrint('[Daemon] Failed to start daemon: $e');
      _daemonLogSink?.writeln(
        '===== ${DateTime.now().toUtc().toIso8601String()} failed to start daemon: $e =====',
      );
      return false;
    }

    // Wait briefly for the daemon to become reachable.
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (DateTime.now().isBefore(deadline)) {
      if (await isRunning(wsUri)) {
        _lastConfigKey = desiredConfigId;
        return true;
      }
      await Future.delayed(const Duration(milliseconds: 120));
    }
    final ok = await isRunning(wsUri);
    if (ok) {
      _lastConfigKey = desiredConfigId;
    }
    return ok;
  }

  Future<void> stop() async {
    final proc = _process;
    _process = null;
    if (proc == null) {
      return;
    }
    try {
      proc.kill(ProcessSignal.sigterm);
    } catch (_) {}
    await _daemonLogSink?.flush();
    await _daemonLogSink?.close();
    _daemonLogSink = null;
  }

  static bool isLocalWs(Uri wsUri) {
    final host = wsUri.host.toLowerCase().trim();
    return host == 'localhost' || host == '127.0.0.1' || host == '::1';
  }

  static Uri _httpUriFromWs(Uri wsUri, String path) {
    final scheme = switch (wsUri.scheme) {
      'wss' => 'https',
      'ws' || '' => 'http',
      _ => 'http',
    };
    return Uri(
      scheme: scheme,
      host: wsUri.host.isEmpty ? '127.0.0.1' : wsUri.host,
      port: wsUri.hasPort ? wsUri.port : 9527,
      path: path,
    );
  }

  static String _resolveBindHost(String host) {
    final h = host.toLowerCase().trim();
    if (h == 'localhost') {
      return '127.0.0.1';
    }
    if (h == '::1') {
      return '127.0.0.1';
    }
    return host;
  }

  static String? _resolveDaemonPath() {
    final override = Platform.environment['HORIZON_DAEMON_PATH'];
    if (override != null && override.trim().isNotEmpty) {
      return override.trim();
    }

    // Release packaging should bundle the daemon binary next to the Flutter executable.
    final exeDir = File(Platform.resolvedExecutable).parent;
    final candidates = <String>[];

    if (Platform.isWindows) {
      candidates.add(File('${exeDir.path}\\horizon-daemon.exe').path);
      candidates.add(File('${exeDir.path}\\horizon-daemon').path);
    } else if (Platform.isMacOS) {
      // .../Horizon.app/Contents/MacOS/Horizon
      final macosDir = exeDir;
      final contentsDir = macosDir.parent;
      candidates.add(File('${macosDir.path}/horizon-daemon').path);
      candidates.add(File('${contentsDir.path}/Resources/horizon-daemon').path);
    } else {
      candidates.add(File('${exeDir.path}/horizon-daemon').path);
    }

    for (final path in candidates) {
      if (File(path).existsSync()) {
        return path;
      }
    }

    // Development mode: look for daemon in project's daemon/target directory
    final devCandidates = _findDevDaemonPaths();
    for (final path in devCandidates) {
      if (File(path).existsSync()) {
        debugPrint('[Daemon] Found development daemon at: $path');
        return path;
      }
    }

    return null;
  }

  static List<String> _findDevDaemonPaths() {
    final candidates = <String>[];
    final binaryName =
        Platform.isWindows ? 'horizon-daemon.exe' : 'horizon-daemon';

    // Try to find the project root by looking for pubspec.yaml
    Directory? current = Directory.current;
    for (var i = 0; i < 10 && current != null; i++) {
      final pubspec = File('${current.path}/pubspec.yaml');
      if (pubspec.existsSync()) {
        // Found project root, check for daemon directory
        final daemonDir = Directory('${current.path}/daemon');
        if (daemonDir.existsSync()) {
          candidates.add('${daemonDir.path}/target/release/$binaryName');
          candidates.add('${daemonDir.path}/target/debug/$binaryName');
        }
        break;
      }
      current = current.parent;
    }

    // Also check relative to current working directory
    candidates.add('daemon/target/release/$binaryName');
    candidates.add('daemon/target/debug/$binaryName');

    return candidates;
  }
}
