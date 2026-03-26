import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:voyager_share/voyager_share.dart';
import 'package:xterm/xterm.dart';

import 'models/dev_mode_config.dart';
import 'pages/home_page.dart';

/// Centralized semantic color tokens for the Horizon light neutral theme.
///
/// Delegates to the shared [AppColors] from voyager_share for visual consistency
/// across Horizon and Voyager.
class HorizonColors {
  HorizonColors._();

  // Backgrounds
  static const background = AppColors.background;
  static const surface = AppColors.surface;
  static const surfaceVariant = AppColors.surfaceVariant;
  static const surfaceBright = AppColors.surfaceBright;

  // Accent
  static const accent = AppColors.accent;
  static const accentDim = AppColors.accentDim;

  // Status
  static const success = AppColors.success;
  static const error = AppColors.error;
  static const warning = AppColors.warning;
  static const statusAmber = AppColors.statusAmber;

  // Text
  static const textPrimary = AppColors.textPrimary;
  static const textSecondary = AppColors.textSecondary;
  static const textTertiary = AppColors.textTertiary;
  static const textMuted = AppColors.textMuted;

  // Borders
  static const border = AppColors.border;
  static const borderSubtle = AppColors.borderSubtle;
  static const borderFocus = AppColors.borderFocus;

  // Cards
  static const cardBackground = AppColors.cardBackground;
  static const cardBorder = AppColors.cardBorder;
}

class HorizonTerminalTheme {
  HorizonTerminalTheme._();

  @Deprecated('Use light instead — this is a light theme despite the name')
  static final TerminalTheme dark = light;

  static final TerminalTheme light = TerminalTheme(
    cursor: HorizonColors.accent,
    selection: const Color(0x336B7280),
    foreground: HorizonColors.textSecondary,
    background: HorizonColors.surfaceVariant,
    black: const Color(0xFF1F2937),
    red: HorizonColors.error,
    green: HorizonColors.success,
    yellow: const Color(0xFF8A8266),
    blue: const Color(0xFF6A7489),
    magenta: const Color(0xFF8A7281),
    cyan: const Color(0xFF6D8086),
    white: const Color(0xFFD1D5DB),
    brightBlack: const Color(0xFF6B7280),
    brightRed: const Color(0xFFB08A8A),
    brightGreen: const Color(0xFF7D9584),
    brightYellow: const Color(0xFF9A9072),
    brightBlue: const Color(0xFF7E889D),
    brightMagenta: const Color(0xFF9C8393),
    brightCyan: const Color(0xFF81969C),
    brightWhite: HorizonColors.textPrimary,
    searchHitBackground: const Color(0xFFD6D9DE),
    searchHitBackgroundCurrent: HorizonColors.accent,
    searchHitForeground: Colors.white,
  );
}

class HorizonApp extends StatelessWidget {
  const HorizonApp({super.key, required this.devModeConfig});

  final DevModeConfig devModeConfig;

  static ThemeData buildTheme() {
    final baseTextTheme = GoogleFonts.firaSansTextTheme(
      ThemeData.light().textTheme,
    );
    return ThemeData(
      brightness: Brightness.light,
      fontFamily: GoogleFonts.firaSans().fontFamily,
      scaffoldBackgroundColor: HorizonColors.background,
      colorScheme: ColorScheme.fromSeed(
        seedColor: HorizonColors.accent,
        brightness: Brightness.light,
        surface: HorizonColors.surface,
        primary: HorizonColors.accent,
      ),
      textTheme: baseTextTheme.apply(
        bodyColor: HorizonColors.textPrimary,
        displayColor: HorizonColors.textPrimary,
      ),
      cardTheme: CardThemeData(
        color: HorizonColors.cardBackground,
        elevation: 0,
        shadowColor: Colors.black.withValues(alpha: 0.06),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AppRadius.md),
          side: const BorderSide(color: HorizonColors.cardBorder, width: 0.5),
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return HorizonColors.accent;
          }
          return HorizonColors.textMuted;
        }),
        trackColor: WidgetStateProperty.resolveWith((states) {
          if (states.contains(WidgetState.selected)) {
            return HorizonColors.accent.withValues(alpha: 0.24);
          }
          return Colors.black.withValues(alpha: 0.08);
        }),
        trackOutlineColor: WidgetStateProperty.resolveWith((states) {
          return Colors.transparent;
        }),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: HorizonColors.surfaceVariant,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
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
          borderSide: const BorderSide(color: HorizonColors.borderSubtle, width: 0.5),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: HorizonColors.borderSubtle, width: 0.5),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(
            color: HorizonColors.border,
            width: 1,
          ),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: HorizonColors.accent,
          foregroundColor: Colors.white,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: HorizonColors.textSecondary,
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          side: const BorderSide(color: HorizonColors.border),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        backgroundColor: HorizonColors.surfaceVariant,
        contentTextStyle: const TextStyle(
          color: HorizonColors.textPrimary,
          fontSize: 13,
        ),
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
