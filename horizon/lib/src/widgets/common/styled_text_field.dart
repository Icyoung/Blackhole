import 'package:flutter/material.dart';

import '../../app.dart';

class StyledTextField extends StatefulWidget {
  const StyledTextField({
    super.key,
    required this.controller,
    required this.label,
    this.hint,
    this.isPassword = false,
    this.maxLength,
    this.textCapitalization = TextCapitalization.none,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool isPassword;
  final int? maxLength;
  final TextCapitalization textCapitalization;

  @override
  State<StyledTextField> createState() => _StyledTextFieldState();
}

class _StyledTextFieldState extends State<StyledTextField> {
  bool _hovered = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final fillColor = _hovered || _focused
        ? Colors.white.withValues(alpha: 0.08)
        : Colors.white.withValues(alpha: 0.05);

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
        ),
        child: Focus(
          onFocusChange: (focused) => setState(() => _focused = focused),
          child: TextField(
            controller: widget.controller,
            obscureText: widget.isPassword,
            maxLength: widget.maxLength,
            textCapitalization: widget.textCapitalization,
            cursorColor: HorizonColors.accent,
            style: const TextStyle(color: Colors.white, fontSize: 14),
            decoration: InputDecoration(
              labelText: widget.label,
              hintText: widget.hint,
              hintStyle:
                  const TextStyle(color: Colors.white24, fontSize: 13),
              labelStyle: const TextStyle(
                  color: HorizonColors.textTertiary, fontSize: 13),
              filled: true,
              fillColor: fillColor,
              isDense: true,
              counterText: '',
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 16, vertical: 14),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: HorizonColors.border),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                  color: _hovered
                      ? Colors.white.withValues(alpha: 0.15)
                      : HorizonColors.border,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(
                    color: HorizonColors.borderFocus, width: 1.5),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
