import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'common/status_dot.dart';
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
    this.isDragTarget = false,
    this.terminalStyle,
    this.showActiveShadow = true,
    this.showActiveChevron = true,
    this.showCloseButton = true,
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
  final bool isDragTarget;
  final TerminalStyle? terminalStyle;
  final bool showActiveShadow;
  final bool showActiveChevron;
  final bool showCloseButton;
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
    return GestureDetector(
      onTapDown: (_) => widget.onTap?.call(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeInOut,
        decoration: BoxDecoration(
          color: const Color(0xFF0A0E14),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: widget.isActive
                ? const Color(0xFF4B7AA6).withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.05),
            width: widget.isActive ? 1.5 : 1.0,
          ),
          boxShadow: [
            if (widget.isActive && widget.showActiveShadow)
              BoxShadow(
                color: const Color(0xFF4B7AA6).withValues(alpha: 0.1),
                blurRadius: 10,
                spreadRadius: 0,
              ),
          ],
        ),
        child: Stack(
          children: [
            Column(
              children: [
                Container(
                  height: 28,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: widget.isActive
                        ? const Color(0xFF1A2A3A).withValues(alpha: 0.4)
                        : const Color(0xFF111620).withValues(alpha: 0.2),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(9),
                      topRight: Radius.circular(9),
                    ),
                  ),
                  child: Row(
                    children: [
                      StatusDot(connected: widget.isActive, size: 6),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          widget.label,
                          style: TextStyle(
                            color: widget.isActive
                                ? Colors.white
                                : Colors.white38,
                            fontSize: 9,
                            fontWeight: widget.isActive
                                ? FontWeight.bold
                                : FontWeight.normal,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                      if (widget.isActive &&
                          (widget.showActiveChevron || widget.showCloseButton))
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (widget.showActiveChevron) ...[
                              const Icon(
                                Icons.keyboard_arrow_right,
                                size: 12,
                                color: Color(0xFF4B7AA6),
                              ),
                              const SizedBox(width: 8),
                            ],
                            if (widget.showCloseButton && widget.onClose != null)
                              GestureDetector(
                                onTap: widget.onClose,
                                child: Icon(
                                  Icons.close_rounded,
                                  size: 14,
                                  color: Colors.white.withValues(alpha: 0.3),
                                ),
                              ),
                          ],
                        ),
                    ],
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(9),
                      bottomRight: Radius.circular(9),
                    ),
                    child: TerminalView(
                      widget.terminal,
                      key: widget.viewKey,
                      controller: widget.controller,
                      scrollController: widget.scrollController,
                      autoResize: true,
                      autofocus: false,
                      deleteDetection: true,
                      readOnly: widget.showHHKB,
                      keyboardType: widget.showHHKB
                          ? TextInputType.none
                          : TextInputType.text,
                      backgroundOpacity: 1.0,
                      padding: const EdgeInsets.all(8),
                      textStyle:
                          widget.terminalStyle ??
                          buildTerminalStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
            ),
            if (widget.isDragTarget)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blue.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
