import 'package:flutter/material.dart';

import 'hhkb_key.dart';

class HHKBKeyboard extends StatelessWidget {
  const HHKBKeyboard({
    super.key,
    required this.connected,
    required this.fn,
    required this.ctrl,
    required this.alt,
    required this.shift,
    required this.onKey,
    required this.onFnChanged,
    required this.onToggleCtrl,
    required this.onToggleAlt,
    required this.onToggleShift,
  });

  final bool connected;
  final bool fn;
  final bool ctrl;
  final bool alt;
  final bool shift;
  final void Function(String key, {bool isSpecial}) onKey;
  final void Function(bool fn) onFnChanged;
  final VoidCallback onToggleCtrl;
  final VoidCallback onToggleAlt;
  final VoidCallback onToggleShift;

  static const _bgColor = Color(0xFF1A1A1A);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: _bgColor,
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildNumberRow(),
          const SizedBox(height: 4),
          _buildQRow(),
          const SizedBox(height: 4),
          _buildARow(),
          const SizedBox(height: 4),
          _buildZRow(),
          const SizedBox(height: 4),
          _buildBottomRow(),
        ],
      ),
    );
  }

  // Row 1: Numbers (Fn: F1-F10)
  Widget _buildNumberRow() {
    final keys = fn
        ? ['F1', 'F2', 'F3', 'F4', 'F5', 'F6', 'F7', 'F8', 'F9', 'F10']
        : (shift
            ? ['!', '@', '#', '\$', '%', '^', '&', '*', '(', ')']
            : ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0']);
    return Row(
      children: keys.map((k) => _key(k, flex: 1)).toList(),
    );
  }

  // Row 2: Q W E R T Y U I O P BS
  // Fn: Q=_, W=C-W, E=End, R=_, T=C-T, Y=_, U=PgUp, I=_, O=_, P=C-P, BS=Del
  Widget _buildQRow() {
    List<String> keys;
    if (fn) {
      keys = ['Q', 'C-W', 'End', 'R', 'C-T', 'Y', 'PgUp', 'I', 'O', 'C-P', 'Del'];
    } else {
      keys = ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', 'BS'];
    }
    return Row(
      children: [
        ...keys.sublist(0, 10).map((k) => _key(k, flex: 10)),
        _key(keys[10], flex: 12, special: true),
      ],
    );
  }

  // Row 3: A S D F G H J K L
  // Fn: A=Home, S=C-S, D=PgDn, F=_, G=_, H=←, J=↓, K=↑, L=→ (Vim nav)
  Widget _buildARow() {
    List<String> keys;
    if (fn) {
      keys = ['Home', 'C-S', 'PgDn', 'F', 'G', '←', '↓', '↑', '→'];
    } else {
      keys = ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'];
    }
    return Row(
      children: keys.map((k) => _key(k, flex: 1)).toList(),
    );
  }

  // Row 4: Z X C V B N M , . /
  // Fn: Z=C-Z, X=_, C=C-C, V=_, B=_, N=C-N, M=_, ,=_, .=_, /=_
  Widget _buildZRow() {
    List<String> keys;
    if (fn) {
      keys = ['C-Z', 'X', 'C-C', 'V', 'B', 'C-N', 'C-L', ',', '.', '/'];
    } else if (shift) {
      keys = ['Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?'];
    } else {
      keys = ['Z', 'X', 'C', 'V', 'B', 'N', 'M', ',', '.', '/'];
    }
    return Row(
      children: keys.map((k) => _key(k, flex: 1)).toList(),
    );
  }

  // Row 5: Ctrl Alt [Fn] [Space] ← ↓ ↑ → Esc Enter
  Widget _buildBottomRow() {
    return Row(
      children: [
        _modKey('Ctrl', ctrl, onToggleCtrl, flex: 7),
        _modKey('Alt', alt, onToggleAlt, flex: 7),
        _fnKey(flex: 7),
        _key('', flex: 20, special: true, isSpace: true), // Space
        _key('←', flex: 7, special: true),
        _key('↓', flex: 7, special: true),
        _key('↑', flex: 7, special: true),
        _key('→', flex: 7, special: true),
        _key('Esc', flex: 8, special: true),
        _key('Enter', flex: 10, special: true),
      ],
    );
  }

  // Fn key: tap to toggle mode, NOT hold
  Widget _fnKey({required int flex}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: HHKBKey(
          label: 'Fn',
          enabled: true,
          active: fn,
          isModifier: true,
          onTap: () => onFnChanged(!fn),
          fontSize: 10,
        ),
      ),
    );
  }

  Widget _key(String label,
      {int flex = 1, bool special = false, bool isSpace = false}) {
    String output = label;
    bool isSpecialKey = special;

    // Handle special labels
    if (label == 'Esc') {
      output = '\x1b';
      isSpecialKey = true;
    } else if (label == 'Tab') {
      output = '\t';
      isSpecialKey = true;
    } else if (label == 'Enter') {
      output = '\r';
      isSpecialKey = true;
    } else if (label == 'BS') {
      output = '\x7f';
      isSpecialKey = true;
    } else if (label == 'Del') {
      output = '\x1b[3~';
      isSpecialKey = true;
    } else if (isSpace) {
      output = ' ';
    } else if (label == '←') {
      output = '\x1b[D';
      isSpecialKey = true;
    } else if (label == '→') {
      output = '\x1b[C';
      isSpecialKey = true;
    } else if (label == '↑') {
      output = '\x1b[A';
      isSpecialKey = true;
    } else if (label == '↓') {
      output = '\x1b[B';
      isSpecialKey = true;
    } else if (label == 'Home') {
      output = '\x1b[H';
      isSpecialKey = true;
    } else if (label == 'End') {
      output = '\x1b[F';
      isSpecialKey = true;
    } else if (label == 'PgUp') {
      output = '\x1b[5~';
      isSpecialKey = true;
    } else if (label == 'PgDn') {
      output = '\x1b[6~';
      isSpecialKey = true;
    } else if (label.startsWith('F') && label.length > 1) {
      final fNum = int.tryParse(label.substring(1));
      if (fNum != null && fNum >= 1 && fNum <= 12) {
        output = _getFnKeyCode(fNum);
        isSpecialKey = true;
      }
    } else if (label == 'C-C') {
      output = '\x03'; // Ctrl+C
      isSpecialKey = true;
    } else if (label == 'C-Z') {
      output = '\x1a'; // Ctrl+Z
      isSpecialKey = true;
    } else if (label == 'C-S') {
      output = '\x13'; // Ctrl+S
      isSpecialKey = true;
    } else if (label == 'C-W') {
      output = '\x17'; // Ctrl+W (close tab)
      isSpecialKey = true;
    } else if (label == 'C-T') {
      output = '\x14'; // Ctrl+T (new tab)
      isSpecialKey = true;
    } else if (label == 'C-P') {
      output = '\x10'; // Ctrl+P (history prev)
      isSpecialKey = true;
    } else if (label == 'C-N') {
      output = '\x0e'; // Ctrl+N (history next)
      isSpecialKey = true;
    } else if (label == 'C-L') {
      output = '\x0c'; // Ctrl+L (clear screen)
      isSpecialKey = true;
    } else if (label.length == 1) {
      final code = label.codeUnitAt(0);
      if (code >= 65 && code <= 90) {
        // Uppercase letter
        output = shift ? label : label.toLowerCase();
      } else if (shift) {
        output = _applyShift(label);
      }
    }

    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: HHKBKey(
          label: isSpace ? '' : label,
          enabled: connected && output.isNotEmpty,
          onTap: () {
            onKey(output, isSpecial: isSpecialKey);
            // Auto-return to default layer after Fn key press
            if (fn) {
              onFnChanged(false);
            }
          },
          fontSize: label.length > 3 ? 9.0 : (label.length > 2 ? 10.0 : 13.0),
        ),
      ),
    );
  }

  Widget _modKey(String label, bool active, VoidCallback onTap,
      {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: HHKBKey(
          label: label,
          enabled: true,
          active: active,
          isModifier: true,
          onTap: onTap,
          fontSize: 10,
        ),
      ),
    );
  }

  String _getFnKeyCode(int n) {
    const codes = {
      1: '\x1bOP',
      2: '\x1bOQ',
      3: '\x1bOR',
      4: '\x1bOS',
      5: '\x1b[15~',
      6: '\x1b[17~',
      7: '\x1b[18~',
      8: '\x1b[19~',
      9: '\x1b[20~',
      10: '\x1b[21~',
      11: '\x1b[23~',
      12: '\x1b[24~',
    };
    return codes[n] ?? '';
  }

  String _applyShift(String char) {
    const shiftMap = {
      '1': '!',
      '2': '@',
      '3': '#',
      '4': '\$',
      '5': '%',
      '6': '^',
      '7': '&',
      '8': '*',
      '9': '(',
      '0': ')',
      '-': '_',
      '=': '+',
      '[': '{',
      ']': '}',
      '\\': '|',
      ';': ':',
      "'": '"',
      ',': '<',
      '.': '>',
      '/': '?',
      '`': '~',
    };
    if (shiftMap.containsKey(char)) {
      return shiftMap[char]!;
    }
    if (char.length == 1 &&
        char.codeUnitAt(0) >= 97 &&
        char.codeUnitAt(0) <= 122) {
      return char.toUpperCase();
    }
    return char;
  }
}
