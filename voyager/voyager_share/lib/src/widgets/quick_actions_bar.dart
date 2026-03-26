import 'package:flutter/material.dart';
import 'package:xterm/xterm.dart';

import 'common/action_button.dart';
import 'design_tokens.dart';

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

  /// Threshold below which we use horizontal scroll instead of wrap.
  static const double _wrapBreakpoint = 480;

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
            duration: AppDurations.normal,
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

      return _scrollController.offset + (boxGlobal.dx - ancestorGlobal.dx);
    } catch (_) {
      return null;
    }
  }

  List<Widget> _buildButtons({bool useSnapKeys = false}) {
    return [
      ActionButton(
        label: 'CTRL',
        modifier: true,
        active: widget.ctrl,
        onTap: widget.onToggleCtrl,
      ),
      ActionButton(
        label: 'ALT',
        modifier: true,
        active: widget.alt,
        onTap: widget.onToggleAlt,
      ),
      ActionButton(
        key: useSnapKeys ? _snapKeys[0] : null,
        label: 'TAB',
        onTap: widget.connected ? () => widget.onKey(TerminalKey.tab) : null,
      ),
      ActionButton(
        label: 'ESC',
        onTap: widget.connected ? () => widget.onKey(TerminalKey.escape) : null,
      ),
      ActionButton(
        key: useSnapKeys ? _snapKeys[1] : null,
        icon: Icons.keyboard_arrow_up,
        onTap: widget.connected ? () => widget.onKey(TerminalKey.arrowUp) : null,
      ),
      ActionButton(
        icon: Icons.keyboard_arrow_down,
        onTap: widget.connected ? () => widget.onKey(TerminalKey.arrowDown) : null,
      ),
      ActionButton(
        icon: Icons.keyboard_arrow_left,
        onTap: widget.connected ? () => widget.onKey(TerminalKey.arrowLeft) : null,
      ),
      ActionButton(
        icon: Icons.keyboard_arrow_right,
        onTap: widget.connected ? () => widget.onKey(TerminalKey.arrowRight) : null,
      ),
      ActionButton(
        key: useSnapKeys ? _snapKeys[2] : null,
        icon: Icons.keyboard_return,
        onTap: widget.connected ? () => widget.onSend('\r') : null,
      ),
      ActionButton(
        key: useSnapKeys ? _snapKeys[4] : null,
        icon: Icons.vertical_align_bottom,
        onTap: widget.onScrollToBottom,
      ),
      ActionButton(
        label: 'LF',
        onTap: widget.connected ? () => widget.onSend('\n') : null,
      ),
      ActionButton(
        key: useSnapKeys ? _snapKeys[3] : null,
        label: 'PASTE',
        onTap: widget.connected ? widget.onPaste : null,
      ),
      ActionButton(
        label: 'COPY',
        onTap: widget.connected ? widget.onCopy : null,
      ),
    ];
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
      padding: const EdgeInsets.symmetric(vertical: AppSpacing.sm),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth >= QuickActionsBar._wrapBreakpoint) {
            return Wrap(
              spacing: 6,
              runSpacing: 6,
              children: _buildButtons(),
            );
          }
          return NotificationListener<ScrollNotification>(
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
                children: _buildButtons(useSnapKeys: true)
                    .expand((w) => [w, const SizedBox(width: 6)])
                    .toList()
                  ..removeLast(),
              ),
            ),
          );
        },
      ),
    );
  }
}
