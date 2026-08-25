import 'dart:convert';
import 'dart:io';

import 'package:voyager/src/services/transport_models.dart';
import 'package:voyager/src/services/vpn_transport_handoff.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    _runBuiltInScenarios();
    return;
  }

  if (args.length == 2 && args.first == '--file') {
    await _runScenarioFile(args[1]);
    return;
  }

  stderr.writeln(
    'Usage:\n'
    '  dart run tool/vpn_handoff_replay.dart\n'
    '  dart run tool/vpn_handoff_replay.dart --file tool/scenario.json',
  );
  exitCode = 64;
}

void _runBuiltInScenarios() {
  final scenarios = <_Scenario>[
    _Scenario('restore in-tunnel endpoint from native status', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final restored = coordinator.restoreEndpointFromNativeStatus(
        currentEndpoint: null,
        snapshot: const VpnTunnelSnapshot(
          isActive: true,
          isConnected: true,
          mode: VpnTunnelMode.direct,
          serverIp: kVpnAppWebsocketHost,
        ),
        defaultLanPort: kVpnAppWebsocketPort,
      );
      _expect(restored != null, 'expected endpoint to be restored');
      _expect(
        restored!.serverIp == kVpnAppWebsocketHost,
        'expected URI host $kVpnAppWebsocketHost',
      );
      _expect(
        restored.lanPort == kVpnAppWebsocketPort,
        'expected default lanPort $kVpnAppWebsocketPort',
      );
    }),
    _Scenario('switch to 10.13.37.1 as unknown after handshake dwell', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);
      coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: true,
          isConnected: true,
          mode: VpnTunnelMode.direct,
          serverIp: kVpnAppWebsocketHost,
          lanPort: kVpnAppWebsocketPort,
        ),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: const VpnTransportEndpoint(
          serverIp: kVpnAppWebsocketHost,
          lanPort: kVpnAppWebsocketPort,
        ),
        now: connectedAt,
      );
      final decision = coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: true,
          isConnected: true,
          mode: VpnTunnelMode.direct,
          serverIp: kVpnAppWebsocketHost,
          lanPort: kVpnAppWebsocketPort,
          timeSinceLastHandshakeSecs: 1,
          directSessionReady: true,
        ),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: const VpnTransportEndpoint(
          serverIp: kVpnAppWebsocketHost,
          lanPort: kVpnAppWebsocketPort,
        ),
        now: connectedAt.add(const Duration(seconds: 3)),
      );
      _expect(decision.shouldSwitch, 'expected handoff switch decision');
      _expect(
        decision.transportKind == TransportKind.unknown,
        'expected in-tunnel WS to open as unknown',
      );
      _expect(
        decision.endpoint?.websocketUri.host == kVpnAppWebsocketHost,
        'expected URI host $kVpnAppWebsocketHost',
      );
      _expect(
        decision.endpoint?.websocketUri.toString() ==
            'ws://$kVpnAppWebsocketHost:$kVpnAppWebsocketPort/ws',
        'expected in-tunnel websocket target',
      );
    }),
    _Scenario('delay switch until primary websocket is connected', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final initial = coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: true,
          isConnected: true,
          mode: VpnTunnelMode.direct,
          serverIp: kVpnAppWebsocketHost,
          lanPort: kVpnAppWebsocketPort,
          timeSinceLastHandshakeSecs: 1,
        ),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.unknown,
        endpoint: const VpnTransportEndpoint(
          serverIp: kVpnAppWebsocketHost,
          lanPort: kVpnAppWebsocketPort,
        ),
        now: DateTime.utc(2026, 1, 1, 0, 0, 0),
      );
      _expect(
        !initial.shouldSwitch,
        'expected no switch before primary connection',
      );
      _expect(
        coordinator.pendingSwitch,
        'expected pending switch to remain armed',
      );

      final resumed = coordinator.onPrimaryConnectionOpened(
        vpnConnected: true,
        vpnMode: VpnTunnelMode.direct,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: const VpnTransportEndpoint(
          serverIp: kVpnAppWebsocketHost,
          lanPort: kVpnAppWebsocketPort,
        ),
        now: DateTime.utc(2026, 1, 1, 0, 0, 3),
      );
      _expect(resumed.shouldSwitch, 'expected switch after primary connection');
      _expect(
        resumed.endpoint?.websocketUri.host == kVpnAppWebsocketHost,
        'expected URI host $kVpnAppWebsocketHost',
      );
    }),
    _Scenario('fallback after vpn disconnects', () {
      final coordinator = VpnTransportHandoffCoordinator();
      final connectedAt = DateTime.utc(2026, 1, 1, 0, 0, 0);
      coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: true,
          isConnected: true,
          mode: VpnTunnelMode.direct,
          serverIp: kVpnAppWebsocketHost,
          lanPort: kVpnAppWebsocketPort,
          timeSinceLastHandshakeSecs: 1,
        ),
        primaryConnectionConnected: true,
        activeTransportKind: TransportKind.wormholeRelay,
        endpoint: const VpnTransportEndpoint(
          serverIp: kVpnAppWebsocketHost,
          lanPort: kVpnAppWebsocketPort,
        ),
        now: connectedAt,
      );
      coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: false,
          isConnected: false,
          mode: VpnTunnelMode.direct,
          serverIp: kVpnAppWebsocketHost,
          lanPort: kVpnAppWebsocketPort,
        ),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.unknown,
        endpoint: const VpnTransportEndpoint(
          serverIp: kVpnAppWebsocketHost,
          lanPort: kVpnAppWebsocketPort,
        ),
        now: connectedAt.add(const Duration(seconds: 1)),
      );
      final fallback = coordinator.onVpnStatusChanged(
        snapshot: const VpnTunnelSnapshot(
          isActive: false,
          isConnected: false,
          mode: VpnTunnelMode.direct,
          serverIp: kVpnAppWebsocketHost,
          lanPort: kVpnAppWebsocketPort,
        ),
        primaryConnectionConnected: false,
        activeTransportKind: TransportKind.unknown,
        endpoint: const VpnTransportEndpoint(
          serverIp: kVpnAppWebsocketHost,
          lanPort: kVpnAppWebsocketPort,
        ),
        now: connectedAt.add(const Duration(seconds: 6)),
      );
      _expect(
        fallback.shouldFallback,
        'expected fallback to primary transport',
      );
    }),
    _Scenario('vpnPeer true on 10.13.37.1 marks Direct', () {
      _expect(
        VpnTransportHandoffCoordinator.hostInfoAction(
              socketHost: kVpnAppWebsocketHost,
              vpnPeer: true,
            ) ==
            VpnHostInfoAction.markDirect,
        'expected vpnPeer=true on $kVpnAppWebsocketHost to mark Direct',
      );
    }),
    _Scenario('control-plane host_info does not clear Direct', () {
      _expect(
        VpnTransportHandoffCoordinator.hostInfoAction(
              socketHost: 'wormhole.blackhole-ai.com',
              vpnPeer: false,
            ) ==
            VpnHostInfoAction.ignore,
        'expected control-plane host_info to be ignored',
      );
    }),
  ];

  var failures = 0;
  for (final scenario in scenarios) {
    try {
      scenario.run();
      stdout.writeln('PASS ${scenario.name}');
    } catch (error) {
      failures += 1;
      stdout.writeln('FAIL ${scenario.name}: $error');
    }
  }

  if (failures > 0) {
    stderr.writeln('vpn_handoff_replay: $failures scenario(s) failed');
    exitCode = 1;
    return;
  }

  stdout.writeln('vpn_handoff_replay: all scenarios passed');
}

Future<void> _runScenarioFile(String path) async {
  final file = File(path);
  final decoded = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
  final coordinator = VpnTransportHandoffCoordinator();
  final defaultLanPort =
      (decoded['defaultLanPort'] as num?)?.toInt() ?? kVpnAppWebsocketPort;
  VpnTransportEndpoint? endpoint;

  final events = (decoded['events'] as List<dynamic>? ?? const []);
  for (var i = 0; i < events.length; i += 1) {
    final event = events[i] as Map<String, dynamic>;
    final type = event['type'] as String? ?? 'vpn';
    switch (type) {
      case 'restore':
        endpoint = coordinator.restoreEndpointFromNativeStatus(
          currentEndpoint: endpoint,
          snapshot: _snapshotFromMap(event),
          defaultLanPort: defaultLanPort,
        );
        stdout.writeln('[$i] restore => $endpoint');
        break;
      case 'primary_connected':
        final decision = coordinator.onPrimaryConnectionOpened(
          vpnConnected: event['vpnConnected'] as bool? ?? false,
          vpnMode: VpnTunnelMode.fromName(event['mode'] as String?),
          activeTransportKind: TransportKind.fromWireName(
            event['activeTransportKind'] as String?,
          ),
          endpoint: endpoint,
        );
        stdout.writeln(
          '[$i] primary_connected => ${_formatDecision(decision)}',
        );
        break;
      case 'vpn':
      default:
        if (event['serverIp'] is String && event['lanPort'] is num) {
          endpoint = VpnTransportEndpoint(
            serverIp: event['serverIp'] as String,
            lanPort: (event['lanPort'] as num).toInt(),
          );
        }
        final decision = coordinator.onVpnStatusChanged(
          snapshot: _snapshotFromMap(event),
          primaryConnectionConnected:
              event['primaryConnectionConnected'] as bool? ?? false,
          activeTransportKind: TransportKind.fromWireName(
            event['activeTransportKind'] as String?,
          ),
          endpoint: endpoint,
        );
        stdout.writeln('[$i] vpn => ${_formatDecision(decision)}');
        break;
    }
  }
}

VpnTunnelSnapshot _snapshotFromMap(Map<String, dynamic> map) {
  return VpnTunnelSnapshot.fromJson(map);
}

String _formatDecision(VpnTransportDecision decision) {
  return switch (decision.type) {
    VpnTransportDecisionType.none => 'none',
    VpnTransportDecisionType.switchTransport =>
      'switch uri=${decision.endpoint?.websocketUri} kind=${decision.transportKind?.wireName} reason=${decision.reason}',
    VpnTransportDecisionType.fallbackToPrimary =>
      'fallback reason=${decision.reason}',
  };
}

void _expect(bool condition, String message) {
  if (!condition) {
    throw StateError(message);
  }
}

class _Scenario {
  const _Scenario(this.name, this.run);

  final String name;
  final void Function() run;
}
