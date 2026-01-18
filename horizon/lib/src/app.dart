import 'package:flutter/material.dart';

import 'models/dev_mode_config.dart';
import 'pages/home_page.dart';

class HorizonApp extends StatelessWidget {
  const HorizonApp({super.key, required this.devModeConfig});

  final DevModeConfig devModeConfig;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Blackhole Horizon',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F141B),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A2A3A),
          brightness: Brightness.dark,
          surface: const Color(0xFF111620),
        ),
        cardTheme: CardThemeData(
          color: const Color(0xFF111620),
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(
              color: Colors.white.withValues(alpha: 0.05),
              width: 1,
            ),
          ),
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: Color(0xFF0F141B),
          elevation: 0,
          centerTitle: false,
          titleTextStyle: TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.bold,
            color: Colors.white,
          ),
        ),
        useMaterial3: true,
      ),
      home: HorizonHome(devModeConfig: devModeConfig),
    );
  }
}
