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
  'Apple Color Emoji',
  'Segoe UI Emoji',
  'Segoe UI Symbol',
  'Symbola',
  'Noto Sans Symbols 2',
  'Noto Sans Symbols',
  'Noto Color Emoji',
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
  red: AppColors.error,
  green: AppColors.success,
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

final TerminalTheme kTerminalThemeTv = TerminalTheme(
  cursor: Colors.white,
  selection: const Color(0xFF4D82FF).withValues(alpha: 0.35),
  foreground: const Color(0xFFF8FAFC),
  background: Colors.black,
  black: const Color(0xFF111827),
  red: const Color(0xFFF87171),
  green: const Color(0xFF34D399),
  yellow: const Color(0xFFFBBF24),
  blue: const Color(0xFF60A5FA),
  magenta: const Color(0xFFC084FC),
  cyan: const Color(0xFF22D3EE),
  white: const Color(0xFFE5E7EB),
  brightBlack: const Color(0xFF6B7280),
  brightRed: const Color(0xFFFCA5A5),
  brightGreen: const Color(0xFF86EFAC),
  brightYellow: const Color(0xFFFDE68A),
  brightBlue: const Color(0xFF93C5FD),
  brightMagenta: const Color(0xFFD8B4FE),
  brightCyan: const Color(0xFF67E8F9),
  brightWhite: Colors.white,
  searchHitBackground: const Color(0xFF374151),
  searchHitBackgroundCurrent: const Color(0xFF4D82FF),
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
