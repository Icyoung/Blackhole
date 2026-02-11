import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:xterm/xterm.dart';

import 'models/dev_mode_config.dart';
import 'pages/home_page.dart';

/// Centralized semantic color tokens for the Horizon dark theme.
class HorizonColors {
  HorizonColors._();

  // Backgrounds
  static const background = Color(0xFF0B0F14);
  static const surface = Color(0xFF11161F);
  static const surfaceVariant = Color(0xFF151C28);
  static const surfaceBright = Color(0xFF1C2533);

  // Accent
  static const accent = Color(0xFF47D7A1);
  static const accentDim = Color(0xFF2FA678);

  // Status
  static const success = Color(0xFF4CCB8F);
  static const error = Color(0xFFFF6B6B);

  // Text
  static const textPrimary = Color(0xFFE7EDF5);
  static const textSecondary = Color(0xFFC5D0DE);
  static const textTertiary = Color(0xFF95A3B6);
  static const textMuted = Color(0xFF6E7A8C);

  // Borders
  static const border = Color(0x20FFFFFF); // white ~12%
  static const borderSubtle = Color(0x12FFFFFF); // white ~7%
  static const borderFocus = Color(0x9947D7A1); // accent 60%

  // Cards
  static const cardBackground = Color(0xFF151C28);
  static const cardBorder = Color(0x12FFFFFF); // white ~7%
}

class HorizonTerminalTheme {
  HorizonTerminalTheme._();

  static final TerminalTheme dark = TerminalTheme(
    cursor: HorizonColors.accent,
    selection: const Color(0x3347D7A1),
    foreground: HorizonColors.textSecondary,
    background: HorizonColors.surfaceVariant,
    black: HorizonColors.background,
    red: HorizonColors.error,
    green: HorizonColors.accent,
    yellow: const Color(0xFFF4D17A),
    blue: const Color(0xFF6CA0FF),
    magenta: const Color(0xFFFF6FB1),
    cyan: const Color(0xFF4FD6FF),
    white: HorizonColors.textSecondary,
    brightBlack: const Color(0xFF3B4452),
    brightRed: const Color(0xFFFF8C8C),
    brightGreen: const Color(0xFF6EE7B7),
    brightYellow: const Color(0xFFFFE3A1),
    brightBlue: const Color(0xFF8AB4FF),
    brightMagenta: const Color(0xFFFF9AD1),
    brightCyan: const Color(0xFF88E6FF),
    brightWhite: HorizonColors.textPrimary,
    searchHitBackground: const Color(0xFF324B3F),
    searchHitBackgroundCurrent: HorizonColors.accent,
    searchHitForeground: HorizonColors.background,
  );
}

class HorizonApp extends StatelessWidget {
  const HorizonApp({super.key, required this.devModeConfig});

  final DevModeConfig devModeConfig;

  static ThemeData buildTheme() {
    final baseTextTheme = GoogleFonts.firaSansTextTheme(
      ThemeData.dark().textTheme,
    );
    return ThemeData(
        brightness: Brightness.dark,
        fontFamily: GoogleFonts.firaSans().fontFamily,
        scaffoldBackgroundColor: HorizonColors.background,
        colorScheme: ColorScheme.fromSeed(
          seedColor: HorizonColors.accent,
          brightness: Brightness.dark,
          surface: HorizonColors.surface,
          primary: HorizonColors.accent,
        ),
        textTheme: baseTextTheme.apply(
          bodyColor: HorizonColors.textSecondary,
          displayColor: HorizonColors.textPrimary,
        ),
        cardTheme: CardThemeData(
          color: HorizonColors.cardBackground,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: const BorderSide(
              color: HorizonColors.cardBorder,
              width: 1,
            ),
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return HorizonColors.accent;
            }
            return const Color(0xFF9AA0A6);
          }),
          trackColor: WidgetStateProperty.resolveWith((states) {
            if (states.contains(WidgetState.selected)) {
              return HorizonColors.accent.withValues(alpha: 0.35);
            }
            return Colors.white.withValues(alpha: 0.1);
          }),
          trackOutlineColor: WidgetStateProperty.resolveWith((states) {
            return Colors.transparent;
          }),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: HorizonColors.surfaceVariant,
          isDense: true,
          contentPadding:
              const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          hintStyle: const TextStyle(
            color: HorizonColors.textMuted,
            fontSize: 12,
          ),
          labelStyle: const TextStyle(
            color: HorizonColors.textTertiary,
            fontSize: 12,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: HorizonColors.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: const BorderSide(color: HorizonColors.border),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide:
                const BorderSide(color: HorizonColors.borderFocus, width: 1.5),
          ),
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: HorizonColors.accent,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            foregroundColor: Colors.white70,
            padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
            side: const BorderSide(color: HorizonColors.border),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            textStyle:
                const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: HorizonColors.surfaceVariant,
          contentTextStyle: const TextStyle(color: Colors.white70, fontSize: 13),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: HorizonColors.border),
          ),
        ),
        useMaterial3: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Blackhole Horizon',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: HorizonHome(devModeConfig: devModeConfig),
    );
  }
}
