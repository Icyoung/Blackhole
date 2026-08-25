import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import 'src/app.dart';
import 'src/services/platform_capabilities.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (VoyagerPlatform.supportsWindowTitle) {
    await windowManager.ensureInitialized();
  }
  runApp(const VoyagerApp());
}
