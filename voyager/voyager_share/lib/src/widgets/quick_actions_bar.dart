import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'common/action_button.dart';

class QuickActionsBar extends StatefulWidget {
  const QuickActionsBar({
    super.key,
    required this.connected,
    required this.ctrl,
    required this.alt,
    required this.meta,
    required this.onToggleCtrl,
    required this.onToggleAlt,
    required this.onToggleMeta,
    required this.onKey,
    required this.onPaste,
    required this.onCopy,
    required this.onSend,
    required this.onScrollToBottom,
  });

  final bool connected;
  final bool ctrl;
  final bool alt;
  final bool meta;
  final VoidCallback onToggleCtrl;
  final VoidCallback onToggleAlt;
  final VoidCallback onToggleMeta;
  final void Function(TerminalKey key) onKey;
  final Future<void> Function() onPaste;
  final Future<void> Function() onCopy;
  final void Function(String data) onSend;
  final VoidCallback onScrollToBottom;

  @override
  State<QuickActionsBar> createState() => _QuickActionsBarState();
}

class _QuickActionsBarState extends State<QuickActionsBar> {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _snapKeys = List.generate(5, (_) => GlobalKey());
  bool _isSnapping = false;
  bool _didInitOffset = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _setInitialOffset());
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  void _setInitialOffset() {
    if (!mounted || _didInitOffset || !_scrollController.hasClients) {
      return;
    }
    final ctx = _snapKeys[0].currentContext;
    final box = ctx?.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _setInitialOffset());
      return;
    }
    final offset = _getSnapOffset(box);
    if (offset == null) {
      return;
    }
    final maxScroll = _scrollController.position.maxScrollExtent;
    _scrollController.jumpTo(offset.clamp(0.0, maxScroll));
    _didInitOffset = true;
  }

  void _onScrollEnd() {
    if (_isSnapping || !_scrollController.hasClients) return;

    final currentOffset = _scrollController.offset;
    final maxScroll = _scrollController.position.maxScrollExtent;

    if (currentOffset <= 0 || currentOffset >= maxScroll) return;

    final snapOffsets = <double>[0];

    for (final key in _snapKeys) {
      final ctx = key.currentContext;
      if (ctx != null) {
        final box = ctx.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) {
          final offset = _getSnapOffset(box);
          if (offset != null && offset > 0) {
            snapOffsets.add(offset);
          }
        }
      }
    }

    if (snapOffsets.length <= 1) return;

    snapOffsets.sort();

    double nearest = 0;
    double minDist = double.infinity;

    for (final snap in snapOffsets) {
      final dist = (currentOffset - snap).abs();
      if (dist < minDist) {
        minDist = dist;
        nearest = snap;
      }
    }

    nearest = nearest.clamp(0.0, maxScroll);

    if ((nearest - currentOffset).abs() > 2) {
      _isSnapping = true;
      _scrollController
          .animateTo(
            nearest,
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeOut,
          )
          .then((_) => _isSnapping = false);
    }
  }

  double? _getSnapOffset(RenderBox box) {
    try {
      final ancestor = context.findRenderObject() as RenderBox?;
      if (ancestor == null) return null;

      final boxGlobal = box.localToGlobal(Offset.zero);
      final ancestorGlobal = ancestor.localToGlobal(Offset.zero);

      return _scrollController.offset + (boxGlobal.dx - ancestorGlobal.dx) - 12;
    } catch (_) {
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: const Color(0xFF111620),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: NotificationListener<ScrollNotification>(
        onNotification: (notification) {
          if (notification is ScrollEndNotification && !_isSnapping) {
            Future.delayed(const Duration(milliseconds: 80), _onScrollEnd);
          }
          return false;
        },
        child: SingleChildScrollView(
          controller: _scrollController,
          scrollDirection: Axis.horizontal,
          physics: const BouncingScrollPhysics(),
          child: Row(
            children: [
              ActionButton(
                label: 'CTRL',
                modifier: true,
                active: widget.ctrl,
                onTap: widget.onToggleCtrl,
              ),
              const SizedBox(width: 6),
              ActionButton(
                label: 'ALT',
                modifier: true,
                active: widget.alt,
                onTap: widget.onToggleAlt,
              ),
              const SizedBox(width: 12),
              ActionButton(
                key: _snapKeys[0],
                label: 'TAB',
                onTap:
                    widget.connected
                        ? () => widget.onKey(TerminalKey.tab)
                        : null,
              ),
              const SizedBox(width: 6),
              ActionButton(
                label: 'ESC',
                onTap:
                    widget.connected
                        ? () => widget.onKey(TerminalKey.escape)
                        : null,
              ),
              const SizedBox(width: 12),
              ActionButton(
                key: _snapKeys[1],
                icon: Icons.keyboard_arrow_up,
                onTap:
                    widget.connected
                        ? () => widget.onKey(TerminalKey.arrowUp)
                        : null,
              ),
              const SizedBox(width: 6),
              ActionButton(
                icon: Icons.keyboard_arrow_down,
                onTap:
                    widget.connected
                        ? () => widget.onKey(TerminalKey.arrowDown)
                        : null,
              ),
              const SizedBox(width: 6),
              ActionButton(
                icon: Icons.keyboard_arrow_left,
                onTap:
                    widget.connected
                        ? () => widget.onKey(TerminalKey.arrowLeft)
                        : null,
              ),
              const SizedBox(width: 6),
              ActionButton(
                icon: Icons.keyboard_arrow_right,
                onTap:
                    widget.connected
                        ? () => widget.onKey(TerminalKey.arrowRight)
                        : null,
              ),
              const SizedBox(width: 12),
              ActionButton(
                key: _snapKeys[2],
                icon: Icons.keyboard_return,
                onTap: widget.connected ? () => widget.onSend('\r') : null,
              ),
              const SizedBox(width: 6),
              ActionButton(
                key: _snapKeys[4],
                icon: Icons.vertical_align_bottom,
                onTap: widget.onScrollToBottom,
              ),
              const SizedBox(width: 12),
              ActionButton(
                label: 'LF',
                onTap: widget.connected ? () => widget.onSend('\n') : null,
              ),
              const SizedBox(width: 6),
              ActionButton(
                key: _snapKeys[3],
                label: 'PASTE',
                onTap: widget.connected ? widget.onPaste : null,
              ),
              const SizedBox(width: 6),
              ActionButton(
                label: 'COPY',
                onTap: widget.connected ? widget.onCopy : null,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
