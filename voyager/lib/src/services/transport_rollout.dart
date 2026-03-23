import 'transport_models.dart';

class TransportRolloutConfig {
  static const bool enableSmartTransport = bool.fromEnvironment(
    'BH_ENABLE_SMART_TRANSPORT',
    defaultValue: false,
  );
  static const bool forceWormholeRelay = bool.fromEnvironment(
    'BH_FORCE_WORMHOLE_RELAY',
    defaultValue: false,
  );
  static const bool preferDirectByDefault = bool.fromEnvironment(
    'BH_PREFER_DIRECT_BY_DEFAULT',
    defaultValue: false,
  );
  static const int _canaryPercentRaw = int.fromEnvironment(
    'BH_TRANSPORT_CANARY_PERCENT',
    defaultValue: 0,
  );
  static int get canaryPercent {
    if (_canaryPercentRaw < 0) {
      return 0;
    }
    if (_canaryPercentRaw > 100) {
      return 100;
    }
    return _canaryPercentRaw;
  }

  static bool isSmartRoutingEnabledForSeed(String seed) {
    if (!enableSmartTransport || forceWormholeRelay) {
      return false;
    }
    final pct = canaryPercent;
    if (pct <= 0) {
      return false;
    }
    if (pct >= 100) {
      return true;
    }
    return _stablePercent(seed) < pct;
  }

  static int defaultPriorityFor(TransportKind kind) {
    final prefersDirect = preferDirectByDefault;
    switch (kind) {
      case TransportKind.wireguardDirect:
        return 130;
      case TransportKind.lanDirect:
        return prefersDirect ? 110 : 90;
      case TransportKind.wormholeRelay:
        return prefersDirect ? 80 : 120;
      case TransportKind.unknown:
        return 0;
    }
  }

  static int _stablePercent(String seed) {
    if (seed.isEmpty) {
      return 0;
    }
    var hash = 2166136261;
    for (final code in seed.codeUnits) {
      hash ^= code;
      hash = (hash * 16777619) & 0x7fffffff;
    }
    return hash % 100;
  }
}
