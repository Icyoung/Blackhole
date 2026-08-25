import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'design_tokens.dart';

class CommandInputBar extends StatefulWidget {
  const CommandInputBar({
    super.key,
    required this.onSend,
    this.readOnly = false,
    this.tvNavigation = false,
    this.dark = false,
  });

  /// Called with the input text. The caller should inject it into the terminal
  /// followed by Enter.
  final void Function(String text) onSend;

  /// When true, the TextField won't show the system keyboard (used when HHKB is active).
  final bool readOnly;
  final bool tvNavigation;
  final bool dark;

  @override
  State<CommandInputBar> createState() => CommandInputBarState();
}

class CommandInputBarState extends State<CommandInputBar> {
  final _controller = TextEditingController();
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode(onKeyEvent: _handleKey);
  }

  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (!widget.tvNavigation || event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }

    final direction = switch (event.logicalKey) {
      LogicalKeyboardKey.arrowUp => TraversalDirection.up,
      LogicalKeyboardKey.arrowDown => TraversalDirection.down,
      _ => null,
    };

    if (direction != null) {
      _focusNode.unfocus();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) {
          return;
        }
        final scope = FocusScope.of(context);
        if (!scope.focusInDirection(direction)) {
          switch (direction) {
            case TraversalDirection.up:
              scope.previousFocus();
              break;
            case TraversalDirection.down:
              scope.nextFocus();
              break;
            case TraversalDirection.left:
            case TraversalDirection.right:
              break;
          }
        }
      });
      return KeyEventResult.handled;
    }

    if (event.logicalKey == LogicalKeyboardKey.escape ||
        event.logicalKey == LogicalKeyboardKey.goBack) {
      _focusNode.unfocus();
      return KeyEventResult.handled;
    }

    return KeyEventResult.ignored;
  }

  /// Insert text at the current cursor position.
  void insertText(String text) {
    final sel = _controller.selection;
    final cur = _controller.text;
    if (sel.isValid && sel.start >= 0) {
      final before = cur.substring(0, sel.start);
      final after = cur.substring(sel.end);
      _controller.value = TextEditingValue(
        text: '$before$text$after',
        selection: TextSelection.collapsed(offset: sel.start + text.length),
      );
    } else {
      _controller.text += text;
      _controller.selection = TextSelection.collapsed(
        offset: _controller.text.length,
      );
    }
  }

  /// Delete one character before the cursor.
  void deleteBack() {
    final sel = _controller.selection;
    final cur = _controller.text;
    if (!sel.isValid || sel.start <= 0 && sel.end <= 0) return;
    if (sel.start != sel.end) {
      // Delete selection
      final before = cur.substring(0, sel.start);
      final after = cur.substring(sel.end);
      _controller.value = TextEditingValue(
        text: '$before$after',
        selection: TextSelection.collapsed(offset: sel.start),
      );
    } else if (sel.start > 0) {
      final before = cur.substring(0, sel.start - 1);
      final after = cur.substring(sel.start);
      _controller.value = TextEditingValue(
        text: '$before$after',
        selection: TextSelection.collapsed(offset: sel.start - 1),
      );
    }
  }

  /// Submit the current content.
  void submit() => _submit();

  void _submit() {
    final text = _controller.text;
    if (text.isEmpty) return;
    widget.onSend(text);
    _controller.clear();
    _focusNode.requestFocus();
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bg = widget.dark ? const Color(0xFF161B22) : AppColors.surfaceDim;
    final border = widget.dark ? const Color(0xFF2B3441) : AppColors.border;
    final fill =
        widget.dark ? const Color(0xFF0C0F14) : AppColors.surfaceVariant;
    final text = widget.dark ? const Color(0xFFF8FAFC) : AppColors.textPrimary;
    final hint = widget.dark ? const Color(0xFF718096) : AppColors.textMuted;
    final focus = widget.dark ? const Color(0xFF4D82FF) : AppColors.accent;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: bg,
        border: Border(top: BorderSide(color: border)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 34,
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                readOnly: widget.readOnly,
                keyboardType:
                    widget.readOnly ? TextInputType.none : TextInputType.text,
                showCursor: true,
                style: TextStyle(fontSize: 13, color: text),
                decoration: InputDecoration(
                  hintText: 'Type to send...',
                  hintStyle: TextStyle(fontSize: 13, color: hint),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  filled: true,
                  fillColor: fill,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: border, width: 0.5),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: border, width: 0.5),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: BorderSide(color: focus, width: 1),
                  ),
                ),
                textInputAction: TextInputAction.send,
                onSubmitted: (_) => _submit(),
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 34,
            height: 34,
            child: IconButton(
              onPressed: _submit,
              padding: EdgeInsets.zero,
              style: IconButton.styleFrom(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: Icon(Icons.send_rounded, size: 16, color: focus),
            ),
          ),
        ],
      ),
    );
  }
}
