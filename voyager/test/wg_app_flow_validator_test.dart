import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/wg_app_flow_validator.dart';

void main() {
  group('WgAppFlowValidator', () {
    test('accepts a full direct app-flow run', () {
      const horizonLog = '''
2026-03-22T00:00:00Z INFO horizon_daemon::wg_server: added WireGuard peer peer_public_key="peer-key-1" client_ip=10.13.37.7
2026-03-22T00:00:00Z INFO horizon_daemon: vpn_config sent: client_ip=10.13.37.7 server_ip=10.13.37.1 wg_port=Some(51820)
2026-03-22T00:00:00Z INFO horizon_daemon::wg_server: sent direct handshake probe to candidate peer=192.168.1.219:51820 peer_public_key="peer-key-1"
2026-03-22T00:00:03Z INFO horizon_daemon::wg_server: accepted direct WireGuard traffic; ending direct probe window peer_public_key="peer-key-1" peer=192.168.1.219:51820
2026-03-22T00:00:04Z INFO horizon_daemon: websocket accepted remote_addr=10.13.37.7:54012 vpn_peer=true
2026-03-22T00:00:04Z INFO horizon_daemon: initial session bootstrap sent on websocket remote_addr=10.13.37.7:54012 vpn_peer=true
2026-03-22T00:00:05Z INFO horizon_daemon: received terminal stdin over websocket remote_addr=10.13.37.7:54012 session_id=ABC123 payload_len=5
2026-03-22T00:00:05Z INFO horizon_daemon: sent terminal stdout over websocket remote_addr=10.13.37.7:54012 session_id=ABC123 payload_len=7
''';

      final result = WgAppFlowValidator.validate(
        horizonLog: horizonLog,
        vpnStatusJson: <String, dynamic>{
          'status': 'connected',
          'connectionMode': 'direct',
          'clientIp': '10.13.37.7',
          'serverIp': '10.13.37.1',
          'lanPort': 9527,
          'udpPacketsIn': 8,
          'tunPacketsIn': 3,
          'wgRxBytes': 1024,
          'directSessionReady': true,
          'timeSinceLastHandshakeSecs': 2,
        },
      );

      expect(result.isSuccess, isTrue);
      expect(result.failures, isEmpty);
      expect(result.directAcceptedPeer, '192.168.1.219:51820');
    });

    test('fails when the direct readiness gate is not satisfied', () {
      const horizonLog = '''
2026-03-22T00:00:00Z INFO horizon_daemon::wg_server: added WireGuard peer peer_public_key="peer-key-1" client_ip=10.13.37.7
2026-03-22T00:00:00Z INFO horizon_daemon: vpn_config sent: client_ip=10.13.37.7 server_ip=10.13.37.1 wg_port=Some(51820)
''';

      final result = WgAppFlowValidator.validate(
        horizonLog: horizonLog,
        vpnStatusJson: <String, dynamic>{
          'status': 'connected',
          'connectionMode': 'direct',
          'clientIp': '10.13.37.7',
          'serverIp': '10.13.37.1',
          'lanPort': 9527,
          'udpPacketsIn': 12,
          'tunPacketsIn': 12,
          'wgRxBytes': 2048,
          'directSessionReady': false,
        },
      );

      expect(result.isSuccess, isFalse);
      expect(
        result.failures,
        contains(
          'direct readiness gate is not satisfied: need host 10.13.37.1, native connected, and handshake (timeSinceLastHandshakeSecs>=0 or directSessionReady)',
        ),
      );
    });

    test('fails when serverIp is not the in-tunnel app WS host', () {
      final result = WgAppFlowValidator.validate(
        horizonLog: '',
        vpnStatusJson: <String, dynamic>{
          'status': 'connected',
          'connectionMode': 'direct',
          'clientIp': '10.13.37.7',
          'serverIp': '192.168.1.20',
          'lanPort': 9527,
          'directSessionReady': true,
          'timeSinceLastHandshakeSecs': 1,
        },
      );

      expect(result.isSuccess, isFalse);
      expect(
        result.failures,
        contains('vpn_status serverIp must be 10.13.37.1 for in-tunnel app WS'),
      );
    });
  });
}
