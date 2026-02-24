class TransportRolloutConfig {
  static const bool enableTailnetIngress = bool.fromEnvironment(
    'BH_ENABLE_TAILNET_INGRESS',
    defaultValue: false,
  );
  static const bool enableTransportSwitch = bool.fromEnvironment(
    'BH_ENABLE_TRANSPORT_SWITCH',
    defaultValue: false,
  );
  static const String tailnetHint = String.fromEnvironment(
    'BH_TAILNET_HINT',
    defaultValue: '',
  );
}
