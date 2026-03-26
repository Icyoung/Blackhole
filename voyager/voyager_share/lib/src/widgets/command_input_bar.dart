import 'package:flutter/material.dart';

import 'design_tokens.dart';

class CommandInputBar extends StatefulWidget {
  const CommandInputBar({
    super.key,
    required this.onSend,
    this.readOnly = false,
  });

  /// Called with the input text. The caller should inject it into the terminal
  /// followed by Enter.
  final void Function(String text) onSend;

  /// When true, the TextField won't show the system keyboard (used when HHKB is active).
  final bool readOnly;

  @override
  State<CommandInputBar> createState() => CommandInputBarState();
}

class CommandInputBarState extends State<CommandInputBar> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();

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
    return Container(
      width: double.infinity,
      decoration: const BoxDecoration(
        color: AppColors.surfaceDim,
        border: Border(
          top: BorderSide(color: AppColors.border),
        ),
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
                style: const TextStyle(
                  fontSize: 13,
                  color: AppColors.textPrimary,
                ),
                decoration: InputDecoration(
                  hintText: 'Say something...',
                  hintStyle: const TextStyle(
                    fontSize: 13,
                    color: AppColors.textMuted,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  filled: true,
                  fillColor: AppColors.surfaceVariant,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: AppColors.border,
                      width: 0.5,
                    ),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: AppColors.border,
                      width: 0.5,
                    ),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(8),
                    borderSide: const BorderSide(
                      color: AppColors.accent,
                      width: 1,
                    ),
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
                backgroundColor: AppColors.accent,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              icon: const Icon(
                Icons.send_rounded,
                size: 16,
                color: Colors.white,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
