import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:xterm/xterm.dart';

import 'design_tokens.dart';
import 'terminal_style.dart';

class SessionWindowCard extends StatefulWidget {
  const SessionWindowCard({
    super.key,
    required this.sessionId,
    required this.terminal,
    required this.controller,
    required this.scrollController,
    required this.viewKey,
    required this.label,
    required this.isActive,
    required this.showHHKB,
    this.deleteDetection = true,
    this.hardwareKeyboardOnly = false,
    this.isDragTarget = false,
    this.terminalStyle,
    this.onTap,
    this.onClose,
  });

  final String sessionId;
  final Terminal terminal;
  final TerminalController controller;
  final ScrollController scrollController;
  final GlobalKey<TerminalViewState> viewKey;
  final String label;
  final bool isActive;
  final bool showHHKB;
  final bool deleteDetection;
  final bool hardwareKeyboardOnly;
  final bool isDragTarget;
  final TerminalStyle? terminalStyle;
  final VoidCallback? onTap;
  final VoidCallback? onClose;

  @override
  State<SessionWindowCard> createState() => _SessionWindowCardState();
}

class _SessionWindowCardState extends State<SessionWindowCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  double? _savedScrollOffset;

  @override
  void didUpdateWidget(SessionWindowCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.isActive && !widget.isActive) {
      if (widget.scrollController.hasClients) {
        _savedScrollOffset = widget.scrollController.offset;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (widget.scrollController.hasClients &&
              _savedScrollOffset != null) {
            widget.scrollController.jumpTo(_savedScrollOffset!);
          }
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final borderColor =
        widget.isActive ? AppColors.border : AppColors.borderSubtle;
    final headerColor =
        widget.isActive ? AppColors.surfaceBright : AppColors.surface;
    // Listener does not join the tap arena, so TerminalView still receives
    // the click and can take keyboard focus. GestureDetector here used to
    // steal the tap; Space then hit Flutter's ActivateIntent instead of the
    // terminal (xterm's keytab has no unshifted Space mapping).
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) {
        widget.onTap?.call();
        if (widget.showHHKB) {
          return;
        }
        WidgetsBinding.instance.addPostFrameCallback((_) {
          widget.viewKey.currentState?.requestKeyboard();
        });
      },
      child: AnimatedContainer(
        duration: AppDurations.normal,
        decoration: BoxDecoration(
          color: AppColors.surfaceVariant,
          borderRadius: BorderRadius.circular(AppRadius.md),
          border: Border.all(color: borderColor, width: 1),
        ),
        child: Stack(
          children: [
            Column(
              children: [
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: headerColor,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(AppRadius.md),
                      topRight: Radius.circular(AppRadius.md),
                    ),
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          widget.label,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color:
                                widget.isActive
                                    ? AppColors.textPrimary
                                    : AppColors.textSecondary,
                            fontSize: 11,
                            fontWeight:
                                widget.isActive
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                          ),
                        ),
                      ),
                      if (widget.onClose != null) ...[
                        const SizedBox(width: 6),
                        GestureDetector(
                          onTap: widget.onClose,
                          child: const SizedBox(
                            width: 24,
                            height: 24,
                            child: Icon(
                              Icons.close_rounded,
                              size: 14,
                              color: AppColors.textMuted,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(AppRadius.md),
                      bottomRight: Radius.circular(AppRadius.md),
                    ),
                    child: TerminalView(
                      widget.terminal,
                      key: widget.viewKey,
                      controller: widget.controller,
                      scrollController: widget.scrollController,
                      theme: kTerminalThemeLight,
                      autoResize: true,
                      autofocus: widget.isActive,
                      deleteDetection: widget.deleteDetection,
                      hardwareKeyboardOnly: widget.hardwareKeyboardOnly,
                      readOnly: widget.showHHKB,
                      keyboardType:
                          widget.showHHKB
                              ? TextInputType.none
                              : TextInputType.text,
                      onKeyEvent: _handleTerminalKeyEvent,
                      backgroundOpacity: 1.0,
                      padding: const EdgeInsets.all(10),
                      textStyle:
                          widget.terminalStyle ??
                          buildTerminalStyle(fontSize: 8),
                    ),
                  ),
                ),
              ],
            ),
            if (widget.isDragTarget)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  KeyEventResult _handleTerminalKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    if (event.logicalKey != LogicalKeyboardKey.space) {
      return KeyEventResult.ignored;
    }
    if (HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed) {
      return KeyEventResult.ignored;
    }
    final character = event.character;
    widget.terminal.textInput(
      character != null && character.isNotEmpty ? character : ' ',
    );
    return KeyEventResult.handled;
  }
}
