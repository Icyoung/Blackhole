import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'common/focusable_tap_region.dart';
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
    this.terminalTheme,
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
  final TerminalTheme? terminalTheme;
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
    return FocusableTapRegion(
      onTap: widget.onTap,
      semanticLabel: widget.label,
      // Space is terminal input, not card activation. Keep it available to
      // the descendant TerminalView when this card is focused.
      activateOnSpace: false,
      builder: (context, focused, hovered, pressed) {
        final active = focused || hovered || pressed;

        return AnimatedScale(
          duration: AppDurations.fast,
          scale: focused ? 1.015 : 1,
          child: AnimatedContainer(
            duration: AppDurations.normal,
            decoration: BoxDecoration(
              color: AppColors.surfaceVariant,
              borderRadius: BorderRadius.circular(AppRadius.md),
              border: Border.all(
                color: focused ? AppColors.borderFocus : borderColor,
                width: focused ? 2 : 1,
              ),
              boxShadow:
                  active
                      ? [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.12),
                          blurRadius: focused ? 14 : 8,
                          offset: const Offset(0, 4),
                        ),
                      ]
                      : null,
            ),
            child: Stack(
              children: [
                Column(
                  children: [
                    Container(
                      height: 32,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: focused ? AppColors.surfaceBright : headerColor,
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
                            IconButton(
                              onPressed: widget.onClose,
                              padding: EdgeInsets.zero,
                              constraints: const BoxConstraints.tightFor(
                                width: 24,
                                height: 24,
                              ),
                              splashRadius: 12,
                              icon: const Icon(
                                Icons.close_rounded,
                                size: 14,
                                color: AppColors.textMuted,
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
                          theme: widget.terminalTheme ?? kTerminalThemeLight,
                          autoResize: true,
                          autofocus: false,
                          deleteDetection: widget.deleteDetection,
                          hardwareKeyboardOnly: widget.hardwareKeyboardOnly,
                          readOnly: widget.showHHKB,
                          keyboardType:
                              widget.showHHKB
                                  ? TextInputType.none
                                  : TextInputType.text,
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
      },
    );
  }
}
