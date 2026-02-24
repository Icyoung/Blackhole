enum TransportKind {
  lanDirect('lan_direct'),
  tailnetDirect('tailnet_direct'),
  wormholeRelay('wormhole_relay'),
  unknown('unknown');

  const TransportKind(this.wireName);

  final String wireName;

  static TransportKind fromWireName(String? value) {
    for (final kind in values) {
      if (kind.wireName == value) {
        return kind;
      }
    }
    return TransportKind.unknown;
  }
}

enum TransportControlType {
  transportProbe('transport_probe'),
  transportProbeResult('transport_probe_result'),
  transportSwitchPrepare('transport_switch_prepare'),
  transportSwitchCommit('transport_switch_commit'),
  transportSwitchAbort('transport_switch_abort'),
  unknown('unknown');

  const TransportControlType(this.wireName);

  final String wireName;

  static TransportControlType fromType(String? value) {
    for (final type in values) {
      if (type.wireName == value) {
        return type;
      }
    }
    return TransportControlType.unknown;
  }
}

class TransportMetadata {
  const TransportMetadata({
    this.transportId,
    this.pathId,
    this.switchReason,
    this.fallbackReason,
    this.probeRttMs,
  });

  final String? transportId;
  final String? pathId;
  final String? switchReason;
  final String? fallbackReason;
  final int? probeRttMs;

  TransportMetadata copyWith({
    String? transportId,
    String? pathId,
    String? switchReason,
    String? fallbackReason,
    int? probeRttMs,
  }) {
    return TransportMetadata(
      transportId: transportId ?? this.transportId,
      pathId: pathId ?? this.pathId,
      switchReason: switchReason ?? this.switchReason,
      fallbackReason: fallbackReason ?? this.fallbackReason,
      probeRttMs: probeRttMs ?? this.probeRttMs,
    );
  }

  Map<String, dynamic> toWire() => <String, dynamic>{
    if (transportId != null) 'transportId': transportId,
    if (pathId != null) 'pathId': pathId,
    if (switchReason != null) 'switchReason': switchReason,
    if (fallbackReason != null) 'fallbackReason': fallbackReason,
    if (probeRttMs != null) 'probeRttMs': probeRttMs,
  };

  static TransportMetadata fromWire(Map<String, dynamic> map) {
    int? parseRtt(Object? value) {
      if (value is int) {
        return value;
      }
      if (value is num) {
        return value.toInt();
      }
      return null;
    }

    return TransportMetadata(
      transportId: map['transportId'] as String?,
      pathId: map['pathId'] as String?,
      switchReason: map['switchReason'] as String?,
      fallbackReason: map['fallbackReason'] as String?,
      probeRttMs: parseRtt(map['probeRttMs']),
    );
  }
}
