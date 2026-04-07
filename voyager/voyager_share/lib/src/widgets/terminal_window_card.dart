import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'design_tokens.dart';
import 'terminal_style.dart';

class TerminalWindowCard extends StatefulWidget {
  const TerminalWindowCard({
    super.key,
    required this.sessionId,
    required this.terminal,
    required this.controller,
    required this.scrollController,
    required this.viewKey,
    required this.label,
    required this.isActive,
    required this.showHHKB,
    this.hardwareKeyboardOnly = false,
    this.isDragTarget = false,
    this.terminalStyle,
    this.showActiveShadow = true,
    this.showActiveChevron = true,
    this.showCloseButton = true,
    this.showStatusDot = true,
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
  final bool hardwareKeyboardOnly;
  final bool isDragTarget;
  final TerminalStyle? terminalStyle;
  final bool showActiveShadow;
  final bool showActiveChevron;
  final bool showCloseButton;
  final bool showStatusDot;
  final VoidCallback? onTap;
  final VoidCallback? onClose;

  @override
  State<TerminalWindowCard> createState() => _TerminalWindowCardState();
}

class _TerminalWindowCardState extends State<TerminalWindowCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  double? _savedScrollOffset;

  @override
  void didUpdateWidget(TerminalWindowCard oldWidget) {
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
    final borderColor = widget.isActive ? AppColors.border : Colors.transparent;
    final headerColor = widget.isActive ? AppColors.background : AppColors.surface;
    return GestureDetector(
      onTapDown: (_) => widget.onTap?.call(),
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
                      topLeft: Radius.circular(12),
                      topRight: Radius.circular(12),
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
                    child: IgnorePointer(
                      ignoring: !widget.isActive,
                      child: TerminalView(
                        widget.terminal,
                        key: widget.viewKey,
                        controller: widget.controller,
                        scrollController: widget.scrollController,
                        theme: kTerminalThemeLight,
                        autoResize: true,
                        autofocus: false,
                        deleteDetection: true,
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
                            buildTerminalStyle(fontSize: 12),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (widget.isDragTarget)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: AppColors.accent.withValues(alpha: AppOpacity.light),
                    borderRadius: BorderRadius.circular(AppRadius.lg),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
