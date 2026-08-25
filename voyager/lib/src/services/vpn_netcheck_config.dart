const int defaultVpnNetcheckPort = 6666;

(String?, int?) deriveVpnNetcheckConfig({
  String? signalingHost,
  int? signalingPort,
  String? wormholeUrl,
}) {
  final explicitHost = signalingHost?.trim();
  final host = (explicitHost != null && explicitHost.isNotEmpty)
      ? explicitHost
      : _wormholeHostname(wormholeUrl);
  if (host == null) {
    return (null, null);
  }
  return (host, usableVpnNetcheckPort(signalingPort));
}

int usableVpnNetcheckPort(int? signalingPort) {
  if (signalingPort == null || signalingPort == 443) {
    return defaultVpnNetcheckPort;
  }
  if (signalingPort == 6666 || signalingPort >= 1024) {
    return signalingPort;
  }
  return defaultVpnNetcheckPort;
}

String? _wormholeHostname(String? wormholeUrl) {
  final raw = wormholeUrl?.trim();
  if (raw == null || raw.isEmpty) {
    return null;
  }
  final uri = Uri.tryParse(raw);
  if (uri == null || uri.host.isEmpty) {
    return null;
  }
  return uri.host;
}
