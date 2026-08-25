import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TvFocusTextField extends StatefulWidget {
  const TvFocusTextField({
    super.key,
    required this.controller,
    this.tvNavigation = false,
    this.decoration,
    this.style,
    this.textCapitalization = TextCapitalization.none,
    this.textAlign = TextAlign.start,
    this.obscureText = false,
    this.focusNode,
    this.onMoveUp,
    this.onMoveDown,
  });

  final TextEditingController controller;
  final bool tvNavigation;
  final InputDecoration? decoration;
  final TextStyle? style;
  final TextCapitalization textCapitalization;
  final TextAlign textAlign;
  final bool obscureText;
  final FocusNode? focusNode;
  final VoidCallback? onMoveUp;
  final VoidCallback? onMoveDown;

  @override
  State<TvFocusTextField> createState() => _TvFocusTextFieldState();
}

class _TvFocusTextFieldState extends State<TvFocusTextField> {
  late final FocusNode _focusNode;
  late final bool _ownsFocusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = widget.focusNode ?? FocusNode();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode.onKeyEvent = _handleKey;
  }

  @override
  void dispose() {
    _focusNode.onKeyEvent = null;
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    super.dispose();
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!widget.tvNavigation || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    if (event.logicalKey == LogicalKeyboardKey.arrowUp ||
        event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _focusNode.unfocus();
      final explicitMove =
          event.logicalKey == LogicalKeyboardKey.arrowUp
              ? widget.onMoveUp
              : widget.onMoveDown;
      if (explicitMove != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) explicitMove();
        });
        return KeyEventResult.handled;
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final scope = FocusScope.of(context);
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          scope.previousFocus();
        } else {
          scope.nextFocus();
        }
      });
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack) {
      _focusNode.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          FocusScope.of(context).nextFocus();
        }
      });
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: widget.controller,
      focusNode: _focusNode,
      onTapOutside: (_) => _focusNode.unfocus(),
      onSubmitted: (_) {
        if (widget.tvNavigation) {
          _focusNode.unfocus();
          FocusScope.of(context).nextFocus();
        }
      },
      textInputAction:
          widget.tvNavigation ? TextInputAction.done : TextInputAction.none,
      textCapitalization: widget.textCapitalization,
      textAlign: widget.textAlign,
      obscureText: widget.obscureText,
      decoration: widget.decoration,
      style: widget.style,
    );
  }
}
