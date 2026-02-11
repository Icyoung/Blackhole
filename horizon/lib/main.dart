import 'dart:io';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/models/dev_mode_config.dart';
import 'src/pages/settings_page.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  await windowManager.ensureInitialized();

  final windowController = await WindowController.fromCurrentEngine();
  final arguments = windowController.arguments;

  if (arguments == 'settings') {
    // Settings sub-window
    const windowOptions = WindowOptions(
      size: Size(760, 580),
      center: true,
      backgroundColor: Color(0xFF202124),
      skipTaskbar: false,
      titleBarStyle: TitleBarStyle.hidden,
      title: 'Settings',
    );
    await windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setBackgroundColor(const Color(0xFF202124));
      await windowManager.show();
      await windowManager.focus();
    });
    runApp(const SettingsWindowApp());
    return;
  }

  // Main window — immersive (no titlebar border)
  const mainWindowOptions = WindowOptions(
    backgroundColor: Color(0xFF202124),
    titleBarStyle: TitleBarStyle.hidden,
  );
  await windowManager.waitUntilReadyToShow(mainWindowOptions, () async {
    await windowManager.setBackgroundColor(const Color(0xFF202124));
    await windowManager.show();
    await windowManager.focus();
  });

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

/// Settings window app wrapper — reuses the main HorizonApp theme.
class SettingsWindowApp extends StatelessWidget {
  const SettingsWindowApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      theme: HorizonApp.buildTheme(),
      home: const SettingsPage(),
    );
  }
}
