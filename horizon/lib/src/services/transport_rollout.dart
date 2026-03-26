class TransportRolloutConfig {
  static const bool enableTransportSwitch = bool.fromEnvironment(
    'BH_ENABLE_TRANSPORT_SWITCH',
    defaultValue: false,
  );
}
