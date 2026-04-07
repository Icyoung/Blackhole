import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:xterm/xterm.dart';

import 'design_tokens.dart';

const kTerminalFontFallback = <String>[
  'Menlo',
  'SF Mono',
  'Monaco',
  'Fira Code',
  'Consolas',
  'Liberation Mono',
  'Courier New',
  'Noto Sans Mono CJK SC',
  'Noto Sans Mono CJK TC',
  'Noto Sans Mono CJK KR',
  'Noto Sans Mono CJK JP',
  'Noto Sans Mono CJK HK',
  'SF Pro',
  'Apple Symbols',
  'Segoe UI Symbol',
  'Noto Sans Symbols 2',
  'Noto Sans Symbols',
  'monospace',
  'sans-serif',
];

// Shared light terminal theme matching white-gray palette.
// ANSI palette colors (red–cyan, bright*) are xterm domain constants
// and intentionally remain inline rather than using AppColors tokens.
@Deprecated('Use kTerminalThemeLight instead')
final TerminalTheme kTerminalThemeDark = kTerminalThemeLight;

final TerminalTheme kTerminalThemeLight = TerminalTheme(
  cursor: AppColors.accent,
  selection: AppColors.accent.withValues(alpha: 0.2),
  foreground: AppColors.textSecondary,
  background: AppColors.surfaceVariant,
  black: const Color(0xFF1F2937),
  red: const Color(0xFFA07171),
  green: const Color(0xFF5F7A67),
  yellow: const Color(0xFF8A8266),
  blue: const Color(0xFF6A7489),
  magenta: const Color(0xFF8A7281),
  cyan: const Color(0xFF6D8086),
  white: AppColors.divider,
  brightBlack: AppColors.accent,
  brightRed: const Color(0xFFB08A8A),
  brightGreen: const Color(0xFF7D9584),
  brightYellow: const Color(0xFF9A9072),
  brightBlue: const Color(0xFF7E889D),
  brightMagenta: const Color(0xFF9C8393),
  brightCyan: const Color(0xFF81969C),
  brightWhite: AppColors.textPrimary,
  searchHitBackground: const Color(0xFFD6D9DE),
  searchHitBackgroundCurrent: AppColors.accent,
  searchHitForeground: Colors.white,
);

TerminalStyle buildTerminalStyle({required double fontSize}) {
  final fontFamily =
      kIsWeb ? GoogleFonts.jetBrainsMono().fontFamily! : 'JetBrainsMono';
  return TerminalStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: kTerminalFontFallback,
    fontSize: fontSize,
  );
}
