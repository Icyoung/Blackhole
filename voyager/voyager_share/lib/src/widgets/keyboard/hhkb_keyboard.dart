import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../common/focusable_tap_region.dart';
import '../design_tokens.dart';
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
    this.chineseMode = false,
    this.onToggleChineseMode,
    this.onScrollToBottom,
    this.dark = false,
  });

  final bool connected;
  final bool fn;
  final bool ctrl;
  final bool alt;
  final bool chineseMode;
  final void Function(String key, {bool isSpecial}) onKey;
  final void Function(bool fn) onFnChanged;
  final VoidCallback onToggleCtrl;
  final VoidCallback onToggleAlt;
  final VoidCallback? onToggleChineseMode;
  final VoidCallback? onScrollToBottom;
  final bool dark;

  @override
  State<HHKBKeyboard> createState() => _HHKBKeyboardState();
}

class _HHKBKeyboardState extends State<HHKBKeyboard> {
  // Shift states: 0=off, 1=once (next char), 2=locked (caps)
  int _shiftState = 0;
  DateTime? _lastShiftTap;
  DateTime? _lastFnTap;
  bool _fnLocked = false;

  static const _shiftDeleteFlex = 12;

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
    if (widget.fn && !_fnLocked) {
      widget.onFnChanged(false);
    }
  }

  void _onFnTap() {
    final now = DateTime.now();
    if (_lastFnTap != null &&
        now.difference(_lastFnTap!).inMilliseconds < 300) {
      // Double tap -> lock/unlock Fn
      setState(() => _fnLocked = !_fnLocked);
      widget.onFnChanged(_fnLocked);
      _lastFnTap = null;
      return;
    }
    _lastFnTap = now;
    if (_fnLocked) {
      setState(() => _fnLocked = false);
      widget.onFnChanged(false);
      return;
    }
    widget.onFnChanged(!widget.fn);
  }

  bool get _shift => _shiftState > 0;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: widget.dark ? const Color(0xFF161B22) : AppColors.surfaceDim,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildRow1(),
          const SizedBox(height: 6),
          _buildRow2(),
          const SizedBox(height: 6),
          _buildRow3(),
          const SizedBox(height: 6),
          _buildRow4(),
          const SizedBox(height: 6),
          _buildBottomRow(),
        ],
      ),
    );
  }

  // Row 1: Numbers (Fn: symbols)
  Widget _buildRow1() {
    final keys =
        widget.fn
            ? ['!', '@', '#', '\$', '%', '^', '&', '*', '(', ')']
            : ['1', '2', '3', '4', '5', '6', '7', '8', '9', '0'];
    return Row(children: keys.map((k) => _key(k, flex: 1)).toList());
  }

  // Row 2: QWERTY (Fn: brackets)
  Widget _buildRow2() {
    List<String> keys;
    if (widget.fn) {
      keys = ['`', '~', '[', ']', '{', '}', '-', '=', '+', '\\'];
    } else {
      final letters = ['Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I', 'O', 'P'];
      keys = _shift ? letters : letters.map((l) => l.toLowerCase()).toList();
    }
    return Row(children: keys.map((k) => _key(k, flex: 1)).toList());
  }

  // Row 3: Tab ASDFGHJKL. (Fn: navigation + punct)
  Widget _buildRow3() {
    List<String> keys;
    if (widget.fn) {
      keys = ['Home', '↑', 'PgU', 'PgD', '↓', 'End', '←', '→', '|', ';', ':'];
    } else {
      final letters = ['A', 'S', 'D', 'F', 'G', 'H', 'J', 'K', 'L'];
      keys = [
        'Tab',
        ...(_shift ? letters : letters.map((l) => l.toLowerCase())),
        '.', // Don't change on shift
      ];
    }
    return Row(children: keys.map((k) => _key(k, flex: 1)).toList());
  }

  // Row 4: ⇧ ZXCVBNM / ⌫ (Fn: ⇧ + actions + ⌦)
  Widget _buildRow4() {
    if (widget.fn) {
      // Fn layer: Shift(inactive) + terminal actions + ⌦
      return Row(
        children: [
          _shiftKey(flex: _shiftDeleteFlex, enabled: false),
          ...[
            'Stop',
            'Susp',
            'EOF',
            'Clr',
            'Kill',
            'W⌫',
            'Yank',
            'Bot',
          ].map((k) => _key(k, flex: 10)),
          _key('⌦', flex: _shiftDeleteFlex),
        ],
      );
    } else {
      // Default layer: Shift + letters + / + ⌫
      final letters = ['Z', 'X', 'C', 'V', 'B', 'N', 'M'];
      return Row(
        children: [
          _shiftKey(flex: _shiftDeleteFlex),
          ...(_shift ? letters : letters.map((l) => l.toLowerCase())).map(
            (k) => _key(k, flex: 10),
          ),
          _key('/', flex: 10), // Don't change on shift
          _key('⌫', flex: _shiftDeleteFlex),
        ],
      );
    }
  }

  // Row 5: Fn Ctrl Alt [Space] 🌐 Esc ⏎
  Widget _buildBottomRow() {
    return Row(
      children: [
        _fnKey(flex: 7),
        _modKey('Ctrl', widget.ctrl, widget.onToggleCtrl, flex: 7),
        _modKey('Alt', widget.alt, widget.onToggleAlt, flex: 6),
        _spaceKey(flex: widget.onToggleChineseMode != null ? 22 : 28),
        if (widget.onToggleChineseMode != null)
          _modKey(
            widget.chineseMode ? '中' : 'EN',
            widget.chineseMode,
            widget.onToggleChineseMode!,
            flex: 6,
          ),
        _key('Esc', flex: 7),
        _key('↵', flex: 10),
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
        padding: const EdgeInsets.symmetric(horizontal: 2.5),
        child: HHKBKey(
          label: label,
          enabled: enabled,
          active: active,
          isModifier: true,
          onTap: enabled ? _onShiftTap : () {},
          fontSize: 14,
          dark: widget.dark,
        ),
      ),
    );
  }

  // Fn key: tap to toggle mode
  Widget _fnKey({required int flex}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2.5),
        child: HHKBKey(
          label: 'Fn',
          enabled: true,
          active: widget.fn || _fnLocked,
          isModifier: true,
          onTap: _onFnTap,
          fontSize: 11,
          dark: widget.dark,
        ),
      ),
    );
  }

  // Space key with swipe gestures for arrows
  Widget _spaceKey({required int flex}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2.5),
        child: _SpaceKey(
          enabled: widget.connected,
          dark: widget.dark,
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
    } else if (label == '↵' || label == '⏎') {
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
    else if (label == 'Home') {
      output = '\x1b[H';
      isSpecialKey = true;
    } else if (label == 'End') {
      output = '\x1b[F';
      isSpecialKey = true;
    } else if (label == '↑') {
      output = '\x1b[A';
      isSpecialKey = true;
    } else if (label == '↓') {
      output = '\x1b[B';
      isSpecialKey = true;
    } else if (label == '←') {
      output = '\x1b[D';
      isSpecialKey = true;
    } else if (label == '→') {
      output = '\x1b[C';
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
    // Scroll to bottom (UI action)
    else if (label == 'Bot') {
      if (widget.onScrollToBottom != null) {
        return _actionKey(label, widget.onScrollToBottom!, flex: flex);
      }
      output = '\x1b[F';
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
        padding: const EdgeInsets.symmetric(horizontal: 2.5),
        child: HHKBKey(
          label: label,
          enabled: widget.connected && output.isNotEmpty,
          onTap: () => _onKeyTap(output, isSpecial: isSpecialKey),
          fontSize: label.length > 3 ? 9.0 : (label.length > 2 ? 10.0 : 13.0),
          dark: widget.dark,
        ),
      ),
    );
  }

  Widget _actionKey(String label, VoidCallback onTap, {int flex = 1}) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2.5),
        child: HHKBKey(
          label: label,
          enabled: widget.connected,
          onTap: () {
            onTap();
            if (widget.fn && !_fnLocked) {
              widget.onFnChanged(false);
            }
          },
          fontSize: label.length > 3 ? 9.0 : (label.length > 2 ? 10.0 : 13.0),
          dark: widget.dark,
        ),
      ),
    );
  }

  Widget _modKey(
    String label,
    bool active,
    VoidCallback onTap, {
    int flex = 1,
  }) {
    return Expanded(
      flex: flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2.5),
        child: HHKBKey(
          label: label,
          enabled: true,
          active: active,
          isModifier: true,
          onTap: onTap,
          fontSize: 10,
          dark: widget.dark,
        ),
      ),
    );
  }
}

/// Space key with swipe gesture support for arrow keys (continuous)
class _SpaceKey extends StatefulWidget {
  const _SpaceKey({
    required this.enabled,
    required this.dark,
    required this.onSpace,
    required this.onArrow,
  });

  final bool enabled;
  final bool dark;
  final VoidCallback onSpace;
  final void Function(String direction) onArrow;

  @override
  State<_SpaceKey> createState() => _SpaceKeyState();
}

class _SpaceKeyState extends State<_SpaceKey> {
  bool _pressed = false;
  double _accumulatedX = 0;
  double _accumulatedY = 0;
  bool _hasMoved = false;
  bool _verticalTriggered = false; // Vertical swipe triggers only once
  static const _stepThreshold = 20.0; // Distance per arrow key trigger

  static const _keyColor = AppColors.keyBackground;
  static const _keyPressedColor = AppColors.keyPressed;
  static const _keyBorder = AppColors.keyBorder;

  @override
  Widget build(BuildContext context) {
    final keyColor = widget.dark ? const Color(0xFF11161D) : _keyColor;
    final keyPressedColor =
        widget.dark ? const Color(0xFF222936) : _keyPressedColor;
    final keyBorder = widget.dark ? const Color(0xFF2B3441) : _keyBorder;

    return FocusableTapRegion(
      onTap: widget.enabled ? widget.onSpace : null,
      semanticLabel: 'Space',
      builder: (context, focused, hovered, pressed) {
        final effectivePressed = _pressed || pressed;
        final bgColor =
            focused
                ? (widget.dark ? const Color(0xFF1D4ED8) : AppColors.keyPressed)
                : effectivePressed
                ? keyPressedColor
                : keyColor;
        final borderColor =
            focused
                ? (widget.dark ? const Color(0xFF93C5FD) : AppColors.accent)
                : keyBorder;

        return GestureDetector(
          onPanStart:
              widget.enabled
                  ? (details) {
                    setState(() => _pressed = true);
                    _accumulatedX = 0;
                    _accumulatedY = 0;
                    _hasMoved = false;
                    _verticalTriggered = false;
                    HapticFeedback.lightImpact();
                  }
                  : null,
          onPanUpdate:
              widget.enabled
                  ? (details) {
                    _accumulatedX += details.delta.dx;
                    _accumulatedY += details.delta.dy;

                    if (_accumulatedX.abs() > _accumulatedY.abs()) {
                      while (_accumulatedX.abs() >= _stepThreshold) {
                        if (_accumulatedX > 0) {
                          widget.onArrow('right');
                          _accumulatedX -= _stepThreshold;
                        } else {
                          widget.onArrow('left');
                          _accumulatedX += _stepThreshold;
                        }
                        _hasMoved = true;
                        HapticFeedback.selectionClick();
                      }
                    } else if (!_verticalTriggered &&
                        _accumulatedY.abs() >= _stepThreshold) {
                      widget.onArrow(_accumulatedY > 0 ? 'down' : 'up');
                      _hasMoved = true;
                      _verticalTriggered = true;
                      HapticFeedback.selectionClick();
                    }
                  }
                  : null,
          onPanEnd:
              widget.enabled
                  ? (details) {
                    setState(() => _pressed = false);
                    if (!_hasMoved) {
                      widget.onSpace();
                    }
                    _accumulatedX = 0;
                    _accumulatedY = 0;
                  }
                  : null,
          onPanCancel:
              widget.enabled
                  ? () {
                    setState(() => _pressed = false);
                    _accumulatedX = 0;
                    _accumulatedY = 0;
                  }
                  : null,
          child: AnimatedContainer(
            duration: AppDurations.fast,
            height: 42,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: borderColor,
                width: focused ? 1.5 : 0.5,
              ),
              boxShadow:
                  effectivePressed || focused
                      ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: focused ? 6 : 1,
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
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }
}
