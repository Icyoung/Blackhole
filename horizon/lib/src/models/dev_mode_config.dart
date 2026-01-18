class DevModeConfig {
  const DevModeConfig({
    required this.requested,
    required this.requiresConfirmation,
  });

  final bool requested;
  final bool requiresConfirmation;
}
