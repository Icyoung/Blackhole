import 'package:flutter/material.dart';

import 'pages/home_page.dart';

class VoyagerApp extends StatelessWidget {
  const VoyagerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Blackhole Voyager',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0F141B),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF1A2A3A),
          brightness: Brightness.dark,
          surface: const Color(0xFF111620),
        ),
        textTheme: const TextTheme(
          bodyMedium: TextStyle(color: Colors.white70),
          titleMedium: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        useMaterial3: true,
      ),
      home: const VoyagerHome(),
    );
  }
}
