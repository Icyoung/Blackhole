class LaunchAutoConnectDecision {
  const LaunchAutoConnectDecision({
    required this.shouldConnect,
    required this.reason,
  });

  final bool shouldConnect;
  final String reason;
}

LaunchAutoConnectDecision evaluateAutoConnectOnLaunch({
  required bool autoReconnect,
  required bool alreadyConnected,
  required bool useWormhole,
  required String sessionId,
  required String lanAddress,
  required String wormholeAddress,
}) {
  if (!autoReconnect) {
    return const LaunchAutoConnectDecision(
      shouldConnect: false,
      reason: 'auto_reconnect_disabled',
    );
  }

  if (alreadyConnected) {
    return const LaunchAutoConnectDecision(
      shouldConnect: false,
      reason: 'already_connected',
    );
  }

  if (useWormhole) {
    if (sessionId.trim().isEmpty) {
      return const LaunchAutoConnectDecision(
        shouldConnect: false,
        reason: 'wormhole_session_missing',
      );
    }
    if (wormholeAddress.trim().isEmpty) {
      return const LaunchAutoConnectDecision(
        shouldConnect: false,
        reason: 'wormhole_address_missing',
      );
    }
    return const LaunchAutoConnectDecision(
      shouldConnect: true,
      reason: 'wormhole_ready',
    );
  }

  if (lanAddress.trim().isEmpty) {
    return const LaunchAutoConnectDecision(
      shouldConnect: false,
      reason: 'lan_address_missing',
    );
  }

  return const LaunchAutoConnectDecision(
    shouldConnect: true,
    reason: 'lan_ready',
  );
}

bool shouldAutoConnectOnLaunch({
  required bool autoReconnect,
  required bool alreadyConnected,
  required bool useWormhole,
  required String sessionId,
  required String lanAddress,
  required String wormholeAddress,
}) {
  return evaluateAutoConnectOnLaunch(
    autoReconnect: autoReconnect,
    alreadyConnected: alreadyConnected,
    useWormhole: useWormhole,
    sessionId: sessionId,
    lanAddress: lanAddress,
    wormholeAddress: wormholeAddress,
  ).shouldConnect;
}
