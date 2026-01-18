import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/models/dev_mode_config.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  final devMode = _resolveDevMode();
  runApp(HorizonApp(devModeConfig: devMode));
}

DevModeConfig _resolveDevMode() {
  final envEnabled = Platform.environment['BLACKHOLE_DEV'] == '1';
  final argsEnabled = Platform.executableArguments.contains('--dev-mode');
  final requested = envEnabled || argsEnabled;
  final requiresConfirmation = kReleaseMode && requested;
  return DevModeConfig(
    requested: requested,
    requiresConfirmation: requiresConfirmation,
  );
}
