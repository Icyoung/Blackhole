import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'hhkb_key.dart';

class HHKBKeyboard extends StatefulWidget {
  const HHKBKeyboard({
    super.key,
    required this.connected,
    required this.fn,
    required this.ctrl,
    required this.alt,
    required this.onKey,
    required this.onFnChanged,
    required this.onToggleCtrl,
    required this.onToggleAlt,
  });

  final bool connected;
  final bool fn;
  final bool ctrl;
  final bool alt;
  final void Function(String key, {bool isSpecial}) onKey;
  final void Function(bool fn) onFnChanged;
  final VoidCallback onToggleCtrl;
  final VoidCallback onToggleAlt;

  @override
  State<HHKBKeyboard> createState() => _HHKBKeyboardState();
}

class _HHKBKeyboardState extends State<HHKBKeyboard> {
  // Shift states: 0=off, 1=once (next char), 2=locked (caps)
  int _shiftState = 0;
  DateTime? _lastShiftTap;

  static const _bgColor = Color(0xFF1A1A1A);

  void _onShiftTap() {
    final now = DateTime.now();
    if (_lastShiftTap != null &&
        now.difference(_lastShiftTap!).inMilliseconds < 300) {
      // Double tap -> Caps Lock
      setState(() => _shiftState = _shiftState == 2 ? 0 : 2);
      _lastShiftTap = null;
    } else {
      // Single tap -> One-time shift
      setState(() => _shiftState = _shiftState == 0 ? 1 : 0);
      _lastShiftTap = now;
    }
  }

  void _onKeyTap(String output, {bool isSpecial = false}) {
    widget.onKey(output, isSpecial: isSpecial);

    // Auto-release one-time shift after letter
    if (_shiftState == 1 && !isSpecial) {
      setState(() => _shiftState = 0);
    }

    // Auto-return from Fn layer
    if (widget.fn) {
      widget.onFnChanged(false);
    }
  }

  bool get _shift => _shiftState > 0;

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
          _buildBottomRow(),
        ],
      ),
    );
  }

  // Row 1: Numbers (Fn: symbols)
  Widget _buildRow1() {
    final keys = widget.fn
        ? ['!', '@', '#', '\$', '%', '^', '&', '*', '(', ')']
        : ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
    return Row(
      children: keys.map((k) => _key(k, flex: 1)).toList(),
    );
  }

  // Row 2: QWERTY + ⌫ (Fn: brackets + ⌦)
  Widget _buildRow2() {
    List<String> keys;
    if (widget.fn) {
      keys = ['`', '~', '[', ']', '{', '}', '-', '=', '+', '\\', '⌦'];
    } else {
      keys = ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P', '⌫'];
    }
    return Row(
      children: [
        ...keys.sublist(0, 10).map((k) => _key(k, flex: 10)),
        _key(keys[10], flex: 12),
      ],
    );
  }

  // Row 3: ASDFGHJKL,. (Fn: navigation + punct)
  Widget _buildRow3() {
    List<String> keys;
    if (widget.fn) {
      keys = ['Hom', '◀W', 'PgU', 'PgD', 'W▶', 'End', '|', ';', ':', "'", '"'];
    } else {
      final punct = _shift ? ['<', '>'] : [',', '.'];
      keys = ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L', ...punct];
    }
    return Row(
      children: keys.map((k) => _key(k, flex: 1)).toList(),
    );
  }

  // Row 4: ⇧ ZXCVBNM/ (Fn: ⇧ + actions)
  Widget _buildRow4() {
    if (widget.fn) {
      // Fn layer: Shift(inactive) + terminal actions
      return Row(
        children: [
          _shiftKey(flex: 15, enabled: false),
          ...['Stop', 'Susp', 'EOF', 'Clr', 'Kill', 'W⌫', 'Yank', '?']
              .map((k) => _key(k, flex: 11)),
        ],
      );
    } else {
      // Default layer: Shift + letters + /
      final punct = _shift ? '?' : '/';
      return Row(
        children: [
          _shiftKey(flex: 15),
          ...['Z', 'X', 'C', 'V', 'B', 'N', 'M', punct]
              .map((k) => _key(k, flex: 11)),
        ],
      );
    }
  }

  // Row 5: Fn Ctrl Alt [Space] Tab Esc ⏎
  Widget _buildBottomRow() {
    return Row(
      children: [
        _fnKey(flex: 7),
        _modKey('Ctrl', widget.ctrl, widget.onToggleCtrl, flex: 7),
        _modKey('Alt', widget.alt, widget.onToggleAlt, flex: 6),
        _spaceKey(flex: 24),
        _key('Tab', flex: 6),
        _key('Esc', flex: 6),
        _key('⏎', flex: 9),
      ],
    );
  }

  // Shift key with iOS-style behavior
  Widget _shiftKey({required int flex, bool enabled = true}) {
    String label;
    bool active;

    if (_shiftState == 2) {
      label = '⇪'; // Caps lock indicator
      active = true;
    } else if (_shiftState == 1) {
      label = '⇧';
      active = true;
    } else {
      label = '⇧';
      active = false;
    }

    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: HHKBKey(
          label: label,
          enabled: enabled,
          active: active,
          isModifier: true,
          onTap: enabled ? _onShiftTap : () {},
          fontSize: 14,
        ),
      ),
    );
  }

  // Fn key: tap to toggle mode
  Widget _fnKey({required int flex}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: HHKBKey(
          label: 'Fn',
          enabled: true,
          active: widget.fn,
          isModifier: true,
          onTap: () => widget.onFnChanged(!widget.fn),
          fontSize: 11,
        ),
      ),
    );
  }

  // Space key with swipe gestures for arrows
  Widget _spaceKey({required int flex}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: _SpaceKey(
          enabled: widget.connected,
          onSpace: () => _onKeyTap(' '),
          onArrow: (direction) {
            final codes = {
              'left': '\x1b[D',
              'right': '\x1b[C',
              'up': '\x1b[A',
              'down': '\x1b[B',
            };
            _onKeyTap(codes[direction]!, isSpecial: true);
          },
        ),
      ),
    );
  }

  Widget _key(String label, {int flex = 1}) {
    String output = label;
    bool isSpecialKey = false;

    // Special key mappings
    if (label == 'Esc') {
      output = '\x1b';
      isSpecialKey = true;
    } else if (label == 'Tab') {
      output = '\t';
      isSpecialKey = true;
    } else if (label == '⏎') {
      output = '\r';
      isSpecialKey = true;
    } else if (label == '⌫') {
      output = '\x7f';
      isSpecialKey = true;
    } else if (label == '⌦') {
      output = '\x1b[3~';
      isSpecialKey = true;
    }
    // Fn layer navigation
    else if (label == 'Hom') {
      output = '\x1b[H';
      isSpecialKey = true;
    } else if (label == 'End') {
      output = '\x1b[F';
      isSpecialKey = true;
    } else if (label == '◀W') {
      output = '\x1bb'; // Alt+B
      isSpecialKey = true;
    } else if (label == 'W▶') {
      output = '\x1bf'; // Alt+F
      isSpecialKey = true;
    } else if (label == 'PgU') {
      output = '\x1b[5~';
      isSpecialKey = true;
    } else if (label == 'PgD') {
      output = '\x1b[6~';
      isSpecialKey = true;
    }
    // Fn layer terminal actions (semantic labels)
    else if (label == 'Stop') {
      output = '\x03'; // Ctrl+C
      isSpecialKey = true;
    } else if (label == 'Susp') {
      output = '\x1a'; // Ctrl+Z
      isSpecialKey = true;
    } else if (label == 'EOF') {
      output = '\x04'; // Ctrl+D
      isSpecialKey = true;
    } else if (label == 'Clr') {
      output = '\x0c'; // Ctrl+L
      isSpecialKey = true;
    } else if (label == 'Kill') {
      output = '\x0b'; // Ctrl+K
      isSpecialKey = true;
    } else if (label == 'W⌫') {
      output = '\x17'; // Ctrl+W
      isSpecialKey = true;
    } else if (label == 'Yank') {
      output = '\x19'; // Ctrl+Y
      isSpecialKey = true;
    }
    // Letters with shift
    else if (label.length == 1) {
      final code = label.codeUnitAt(0);
      if (code >= 65 && code <= 90) {
        // Uppercase letter -> apply shift
        output = _shift ? label : label.toLowerCase();
      }
    }

    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 1.5),
        child: HHKBKey(
          label: label,
          enabled: widget.connected && output.isNotEmpty,
          onTap: () => _onKeyTap(output, isSpecial: isSpecialKey),
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
}

/// Space key with swipe gesture support for arrow keys
class _SpaceKey extends StatefulWidget {
  const _SpaceKey({
    required this.enabled,
    required this.onSpace,
    required this.onArrow,
  });

  final bool enabled;
  final VoidCallback onSpace;
  final void Function(String direction) onArrow;

  @override
  State<_SpaceKey> createState() => _SpaceKeyState();
}

class _SpaceKeyState extends State<_SpaceKey> {
  bool _pressed = false;
  Offset _totalDelta = Offset.zero;
  static const _swipeThreshold = 25.0;

  static const _keyColor = Color(0xFF2D2D2D);
  static const _keyPressedColor = Color(0xFF1A1A1A);
  static const _keyBorder = Color(0xFF3D3D3D);

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onPanStart: widget.enabled
          ? (details) {
              setState(() => _pressed = true);
              _totalDelta = Offset.zero;
              HapticFeedback.lightImpact();
            }
          : null,
      onPanUpdate: widget.enabled
          ? (details) {
              _totalDelta += details.delta;
            }
          : null,
      onPanEnd: widget.enabled
          ? (details) {
              setState(() => _pressed = false);
              _handleSwipe();
            }
          : null,
      onPanCancel: widget.enabled
          ? () {
              setState(() => _pressed = false);
              _totalDelta = Offset.zero;
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 100),
        height: 42,
        decoration: BoxDecoration(
          color: _pressed ? _keyPressedColor : _keyColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: _keyBorder, width: 0.5),
          boxShadow: _pressed
              ? [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.5),
                    blurRadius: 1,
                    offset: const Offset(0, 0),
                  ),
                ]
              : [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 2,
                    offset: const Offset(0, 1.5),
                  ),
                ],
        ),
        child: Center(
          child: Text(
            '← ↑↓ →',
            style: TextStyle(
              color: widget.enabled ? Colors.white30 : Colors.white12,
              fontSize: 10,
              letterSpacing: 2,
            ),
          ),
        ),
      ),
    );
  }

  void _handleSwipe() {
    final dx = _totalDelta.dx;
    final dy = _totalDelta.dy;

    if (dx.abs() < _swipeThreshold && dy.abs() < _swipeThreshold) {
      // Tap (no significant movement)
      widget.onSpace();
    } else if (dx.abs() > dy.abs()) {
      // Horizontal swipe
      widget.onArrow(dx > 0 ? 'right' : 'left');
    } else {
      // Vertical swipe
      widget.onArrow(dy > 0 ? 'down' : 'up');
    }

    _totalDelta = Offset.zero;
  }
}
