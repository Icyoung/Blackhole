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
    required this.onToggleFn,
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
  final VoidCallback onToggleFn;
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
          _buildRow1(),
          const SizedBox(height: 4),
          _buildRow2(),
          const SizedBox(height: 4),
          _buildRow3(),
          const SizedBox(height: 4),
          _buildRow4(),
          const SizedBox(height: 4),
          _buildRow5(),
        ],
      ),
    );
  }

  Widget _buildRow1() {
    List<String> keys;
    if (fn) {
      keys = [
        'Esc',
        'F1',
        'F2',
        'F3',
        'F4',
        'F5',
        'F6',
        'F7',
        'F8',
        'F9',
        'F10',
        'F11',
        'F12',
        'Ins',
        'Del'
      ];
    } else if (shift) {
      keys = [
        'Esc',
        '!',
        '@',
        '#',
        '\$',
        '%',
        '^',
        '&',
        '*',
        '(',
        ')',
        '_',
        '+',
        '|',
        '~'
      ];
    } else {
      keys = ['Esc', '1', '2', '3', '4', '5', '6', '7', '8', '9', '0', '-', '=', '\\', '`'];
    }
    return Row(
      children: keys.map((k) => _key(k, flex: 1)).toList(),
    );
  }

  Widget _buildRow2() {
    List<String> keys;
    if (fn) {
      keys = ['Tab', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 'BS'];
    } else if (shift) {
      keys = ['Tab', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '{', '}', 'BS'];
    } else {
      keys = ['Tab', 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '[', ']', 'BS'];
    }
    return Row(
      children: [
        _key(keys[0], flex: 12, special: true),
        ...keys.sublist(1, 13).map((k) => _key(k, flex: 11)),
        _key(keys[13], flex: 12, special: true),
      ],
    );
  }

  Widget _buildRow3() {
    List<String> keys;
    if (fn) {
      keys = ['A', 'S', 'D', 'F', 'G', '←', '↓', '↑', '→', ';', "'"];
    } else if (shift) {
      keys = ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':', '"'];
    } else {
      keys = ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ';', "'"];
    }
    return Row(
      children: [
        _modKey('Ctrl', ctrl, onToggleCtrl, flex: 14),
        ...keys.map((k) => _key(k, flex: 11)),
        _key('Enter', flex: 15, special: true),
      ],
    );
  }

  Widget _buildRow4() {
    final keys = shift
        ? ['Z', 'X', 'C', 'V', 'B', 'N', 'M', '<', '>', '?']
        : ['Z', 'X', 'C', 'V', 'B', 'N', 'M', ',', '.', '/'];
    return Row(
      children: [
        _modKey('Shift', shift, onToggleShift, flex: 16),
        ...keys.map((k) => _key(k, flex: 11)),
        _modKey('Shift', shift, onToggleShift, flex: 14),
      ],
    );
  }

  Widget _buildRow5() {
    return Row(
      children: [
        _modKey('Fn', fn, onToggleFn, flex: 10),
        _key('◇', flex: 10, special: true),
        _modKey('Alt', alt, onToggleAlt, flex: 10),
        _key('', flex: 72, special: true, isSpace: true),
        _modKey('Alt', alt, onToggleAlt, flex: 10),
        _key('◇', flex: 10, special: true),
        _modKey('Fn', fn, onToggleFn, flex: 10),
      ],
    );
  }

  Widget _key(String label,
      {int flex = 1, bool special = false, bool isSpace = false}) {
    String output = label;
    bool isSpecialKey = special;

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
    } else if (label == 'Ins') {
      output = '\x1b[2~';
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
    } else if (label.startsWith('F') && label.length > 1) {
      final fNum = int.tryParse(label.substring(1));
      if (fNum != null && fNum >= 1 && fNum <= 12) {
        output = _getFnKeyCode(fNum);
        isSpecialKey = true;
      }
    } else if (label == '◇') {
      output = '';
    } else if (label.length == 1) {
      final code = label.codeUnitAt(0);
      if (code >= 65 && code <= 90) {
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
          onTap: () => onKey(output, isSpecial: isSpecialKey),
          fontSize: label.length > 2 ? 10.0 : 13.0,
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
