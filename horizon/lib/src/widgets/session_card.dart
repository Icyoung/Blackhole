import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import '../app.dart';

class HorizonSessionCard extends StatefulWidget {
  const HorizonSessionCard({
    super.key,
    required this.sessionId,
    required this.terminal,
    required this.controller,
    required this.scrollController,
    required this.viewKey,
    required this.label,
    required this.isActive,
    required this.showHHKB,
    required this.deleteDetection,
    this.isDragTarget = false,
    required this.terminalStyle,
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
  final bool isDragTarget;
  final TerminalStyle terminalStyle;
  final VoidCallback? onTap;
  final VoidCallback? onClose;

  @override
  State<HorizonSessionCard> createState() => _HorizonSessionCardState();
}

class _HorizonSessionCardState extends State<HorizonSessionCard>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  double? _savedScrollOffset;

  @override
  void didUpdateWidget(HorizonSessionCard oldWidget) {
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
        widget.isActive
            ? HorizonColors.accent.withValues(alpha: 0.65)
            : HorizonColors.borderSubtle;
    final headerColor =
        widget.isActive
            ? HorizonColors.surfaceBright
            : HorizonColors.surface;
    return GestureDetector(
      onTapDown: (_) => widget.onTap?.call(),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        decoration: BoxDecoration(
          color: HorizonColors.surfaceVariant,
          borderRadius: BorderRadius.circular(12),
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
                      topLeft: Radius.circular(15),
                      topRight: Radius.circular(15),
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
                                    ? HorizonColors.textPrimary
                                    : HorizonColors.textSecondary,
                            fontSize: 11,
                            fontWeight:
                                widget.isActive
                                    ? FontWeight.w600
                                    : FontWeight.w500,
                          ),
                        ),
                      ),
                      const SizedBox(width: 6),
                      IconButton(
                        onPressed: widget.onClose,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints.tightFor(width: 24, height: 24),
                        splashRadius: 12,
                        icon: const Icon(
                          Icons.close_rounded,
                          size: 14,
                          color: HorizonColors.textMuted,
                        ),
                      ),
                    ],
                  ),
                ),
                Expanded(
                  child: ClipRRect(
                    borderRadius: const BorderRadius.only(
                      bottomLeft: Radius.circular(12),
                      bottomRight: Radius.circular(12),
                    ),
                    child: TerminalView(
                      widget.terminal,
                      key: widget.viewKey,
                      controller: widget.controller,
                      scrollController: widget.scrollController,
                      theme: HorizonTerminalTheme.dark,
                      autoResize: true,
                      autofocus: false,
                      deleteDetection: widget.deleteDetection,
                      readOnly: widget.showHHKB,
                      keyboardType:
                          widget.showHHKB
                              ? TextInputType.none
                              : TextInputType.text,
                      backgroundOpacity: 1.0,
                      padding: const EdgeInsets.all(10),
                      textStyle: widget.terminalStyle,
                    ),
                  ),
                ),
              ],
            ),
            if (widget.isDragTarget)
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: HorizonColors.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
