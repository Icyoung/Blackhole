import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../design_tokens.dart';

class HHKBKey extends StatefulWidget {
  const HHKBKey({
    super.key,
    required this.label,
    required this.enabled,
    required this.onTap,
    this.active = false,
    this.isModifier = false,
    this.fontSize = 13,
  });

  final String label;
  final bool enabled;
  final bool active;
  final bool isModifier;
  final VoidCallback onTap;
  final double fontSize;

  @override
  State<HHKBKey> createState() => _HHKBKeyState();
}

class _HHKBKeyState extends State<HHKBKey> {
  bool _pressed = false;
  OverlayEntry? _bubbleEntry;
  final GlobalKey _keyKey = GlobalKey();

  static const _keyColor = AppColors.keyBackground;
  static const _keyPressedColor = AppColors.keyPressed;
  static const _keyBorder = AppColors.keyBorder;
  static const _modActiveColor = AppColors.keyPressed;
  static const _modPressedColor = AppColors.textMuted;

  @override
  void dispose() {
    _hideBubble();
    super.dispose();
  }

  void _showBubble() {
    if (widget.label.isEmpty || widget.isModifier) return;

    final renderBox = _keyKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;

    _bubbleEntry = OverlayEntry(
      builder: (context) => Positioned(
        left: position.dx + size.width / 2 - 28,
        top: position.dy - 52,
        child: IgnorePointer(
          child: Container(
            width: 56,
            height: 52,
            decoration: BoxDecoration(
              color: AppColors.keyBackground,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 8,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.label,
                  style: const TextStyle(
                    color: AppColors.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w500,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(_bubbleEntry!);
  }

  void _hideBubble() {
    _bubbleEntry?.remove();
    _bubbleEntry = null;
  }

  @override
  Widget build(BuildContext context) {
    Color bgColor;
    Color borderColor;

    if (widget.isModifier) {
      if (_pressed) {
        bgColor = widget.active ? _modPressedColor : _keyPressedColor;
      } else {
        bgColor = widget.active ? _modActiveColor : _keyColor;
      }
      borderColor =
          widget.active ? _modActiveColor.withValues(alpha: 0.8) : _keyBorder;
    } else {
      bgColor = _pressed ? _keyPressedColor : _keyColor;
      borderColor = _keyBorder;
    }

    return GestureDetector(
      onTapDown: widget.enabled
          ? (_) {
              setState(() => _pressed = true);
              HapticFeedback.lightImpact();
              _showBubble();
            }
          : null,
      onTapUp: widget.enabled
          ? (_) {
              setState(() => _pressed = false);
              _hideBubble();
            }
          : null,
      onTapCancel: widget.enabled
          ? () {
              setState(() => _pressed = false);
              _hideBubble();
            }
          : null,
      onTap: widget.enabled ? widget.onTap : null,
      child: AnimatedContainer(
        key: _keyKey,
        duration: AppDurations.fast,
        height: 42,
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: borderColor, width: 0.5),
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
            widget.label,
            style: TextStyle(
              color: widget.enabled ? AppColors.textPrimary : AppColors.textMuted,
              fontSize: widget.fontSize,
              fontWeight:
                  widget.isModifier ? FontWeight.bold : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}
