import 'package:flutter/foundation.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:xterm/xterm.dart';

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
  'Segoe UI Symbol',
  'Symbola',
  'Noto Sans Symbols 2',
  'Noto Sans Symbols',
  'Noto Color Emoji',
  'monospace',
  'sans-serif',
];

TerminalStyle buildTerminalStyle({required double fontSize}) {
  final fontFamily =
      kIsWeb ? GoogleFonts.jetBrainsMono().fontFamily! : 'JetBrainsMono';
  return TerminalStyle(
    fontFamily: fontFamily,
    fontFamilyFallback: kTerminalFontFallback,
    fontSize: fontSize,
  );
}
