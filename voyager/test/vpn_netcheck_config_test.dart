import 'package:flutter_test/flutter_test.dart';
import 'package:voyager/src/services/vpn_netcheck_config.dart';

void main() {
  group('deriveVpnNetcheckConfig', () {
    test('uses signaling port 6666', () {
      final (host, port) = deriveVpnNetcheckConfig(
        signalingHost: 'wormhole.blackhole-ai.com',
        signalingPort: 6666,
        wormholeUrl: 'wss://wormhole.blackhole-ai.com/ws',
      );
      expect(host, 'wormhole.blackhole-ai.com');
      expect(port, 6666);
    });

    test('allows unprivileged STUN ports such as 3478', () {
      final (host, port) = deriveVpnNetcheckConfig(
        signalingHost: 'stun.example.com',
        signalingPort: 3478,
        wormholeUrl: 'wss://wormhole.blackhole-ai.com/ws',
      );
      expect(host, 'stun.example.com');
      expect(port, 3478);
    });

    test('never uses 443 even when signaling advertises it', () {
      final (host, port) = deriveVpnNetcheckConfig(
        signalingHost: 'wormhole.blackhole-ai.com',
        signalingPort: 443,
        wormholeUrl: 'wss://wormhole.blackhole-ai.com/ws',
      );
      expect(host, 'wormhole.blackhole-ai.com');
      expect(port, 6666);
    });

    test('never copies the WSS URI port', () {
      final (host, port) = deriveVpnNetcheckConfig(
        signalingHost: null,
        signalingPort: null,
        wormholeUrl: 'wss://wormhole.blackhole-ai.com:443/ws',
      );
      expect(host, 'wormhole.blackhole-ai.com');
      expect(port, 6666);
    });

    test('defaults missing port to 6666 and keeps signaling host', () {
      final (host, port) = deriveVpnNetcheckConfig(
        signalingHost: '38.60.162.209',
        signalingPort: null,
        wormholeUrl: 'wss://wormhole.blackhole-ai.com/ws',
      );
      expect(host, '38.60.162.209');
      expect(port, 6666);
    });

    test('rejects privileged ports other than 6666', () {
      final (host, port) = deriveVpnNetcheckConfig(
        signalingHost: 'wormhole.blackhole-ai.com',
        signalingPort: 80,
        wormholeUrl: 'wss://wormhole.blackhole-ai.com/ws',
      );
      expect(host, 'wormhole.blackhole-ai.com');
      expect(port, 6666);
    });
  });
}
