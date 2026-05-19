import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/multi_window_layout.dart';

typedef LayoutCellBuilder =
    Widget Function(BuildContext context, String sessionId, int visualIndex);

class MultiWindowGrid extends StatelessWidget {
  const MultiWindowGrid({
    super.key,
    required this.layout,
    required this.cellBuilder,
    this.trailingBuilder,
    required this.onResizeSplit,
    required this.onResizeEnd,
    this.onMoveCell,
    this.padding = EdgeInsets.zero,
    this.gap = 8,
    this.splitterVisualGap = 8,
    this.touchMinHitSize = 44,
    this.desktopHitSize = 12,
    this.mobileBreakpoint = 600,
    this.scrollPhysics,
  });

  final MultiWindowLayout layout;
  final LayoutCellBuilder cellBuilder;
  final WidgetBuilder? trailingBuilder;
  final void Function(
    List<int> splitPath,
    int dividerIndex,
    double deltaPx,
    double extent,
  )
  onResizeSplit;
  final VoidCallback onResizeEnd;
  final void Function(String fromSessionId, String toSessionId, DropSide side)?
  onMoveCell;
  final EdgeInsetsGeometry padding;
  final double gap;
  final double splitterVisualGap;
  final double touchMinHitSize;
  final double desktopHitSize;
  final double mobileBreakpoint;
  final ScrollPhysics? scrollPhysics;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < mobileBreakpoint) {
          return _buildSingleColumn(context);
        }
        return Padding(padding: padding, child: _buildSplitLayout(context));
      },
    );
  }

  Widget _buildSingleColumn(BuildContext context) {
    var index = 0;
    return ListView(
      padding: padding,
      physics: scrollPhysics,
      children: [
        for (final sessionId in layout.sessionIds) ...[
          SizedBox(
            height: 280,
            child: cellBuilder(context, sessionId, index++),
          ),
          SizedBox(height: gap),
        ],
        if (trailingBuilder != null)
          SizedBox(height: 180, child: trailingBuilder!(context)),
      ],
    );
  }

  Widget _buildSplitLayout(BuildContext context) {
    final root = layout.root;
    if (root == null) {
      return trailingBuilder?.call(context) ?? const SizedBox.shrink();
    }
    final visualIndexes = <String, int>{};
    final ids = layout.sessionIds;
    for (var i = 0; i < ids.length; i++) {
      visualIndexes.putIfAbsent(ids[i], () => i);
    }
    final rootWidget = _buildNode(context, root, const <int>[], visualIndexes);
    if (trailingBuilder == null) {
      return rootWidget;
    }
    return Column(
      children: [
        Expanded(child: rootWidget),
        SizedBox(height: gap),
        SizedBox(height: 180, child: trailingBuilder!(context)),
      ],
    );
  }

  Widget _buildNode(
    BuildContext context,
    LayoutNode node,
    List<int> path,
    Map<String, int> visualIndexes,
  ) {
    if (node is LayoutLeaf) {
      final child = cellBuilder(
        context,
        node.sessionId,
        visualIndexes[node.sessionId] ?? 0,
      );
      return onMoveCell == null
          ? child
          : _DraggableCell(
            sessionId: node.sessionId,
            onMoveCell: onMoveCell!,
            child: child,
          );
    }
    if (node is! LayoutSplit || node.children.isEmpty) {
      return const SizedBox.shrink();
    }

    final splitAxis =
        node.axis == LayoutSplitAxis.horizontal
            ? Axis.horizontal
            : Axis.vertical;
    final handleAxis =
        splitAxis == Axis.horizontal ? Axis.vertical : Axis.horizontal;
    final hitSize = _hitSize(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final extent =
            splitAxis == Axis.horizontal
                ? constraints.maxWidth
                : constraints.maxHeight;
        final children = <Widget>[];
        for (var i = 0; i < node.children.length; i++) {
          final childPath = <int>[...path, i];
          final child = _buildNode(
            context,
            node.children[i],
            childPath,
            visualIndexes,
          );
          children.add(
            Expanded(
              flex: _flex(i < node.weights.length ? node.weights[i] : 1),
              child: _ResizableSplitChild(
                axis: splitAxis,
                handleAxis: handleAxis,
                hitSize: hitSize,
                visualGap: splitterVisualGap,
                hasLeading: i > 0,
                hasTrailing: i < node.children.length - 1,
                onLeadingDrag:
                    i > 0
                        ? (delta) => onResizeSplit(path, i - 1, delta, extent)
                        : null,
                onTrailingDrag:
                    i < node.children.length - 1
                        ? (delta) => onResizeSplit(path, i, delta, extent)
                        : null,
                onDragEnd: onResizeEnd,
                child: child,
              ),
            ),
          );
        }
        return splitAxis == Axis.horizontal
            ? Row(children: children)
            : Column(children: children);
      },
    );
  }

  double _hitSize(BuildContext context) {
    final platform = Theme.of(context).platform;
    final touchPlatform =
        kIsWeb == false &&
        (platform == TargetPlatform.iOS || platform == TargetPlatform.android);
    return touchPlatform ? touchMinHitSize : desktopHitSize;
  }

  int _flex(double weight) {
    return (weight * 1000).round().clamp(1, 1000000);
  }
}

/// Adds invisible edge handles and visual padding around a child in a split.
/// The hit zone stays inside the split gutter created by [visualGap].
class _ResizableSplitChild extends StatelessWidget {
  const _ResizableSplitChild({
    required this.child,
    required this.axis,
    required this.handleAxis,
    required this.hitSize,
    required this.visualGap,
    required this.hasLeading,
    required this.hasTrailing,
    required this.onLeadingDrag,
    required this.onTrailingDrag,
    required this.onDragEnd,
  });

  final Widget child;
  final Axis axis;
  final Axis handleAxis;
  final double hitSize;
  final double visualGap;
  final bool hasLeading;
  final bool hasTrailing;
  final ValueChanged<double>? onLeadingDrag;
  final ValueChanged<double>? onTrailingDrag;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final handleExtent = hitSize / 2;
    final visualInset = visualGap / 2;
    final padded =
        axis == Axis.horizontal
            ? Padding(
              padding: EdgeInsets.only(
                left: hasLeading && onLeadingDrag != null ? visualInset : 0,
                right: hasTrailing && onTrailingDrag != null ? visualInset : 0,
              ),
              child: child,
            )
            : Padding(
              padding: EdgeInsets.only(
                top: hasLeading && onLeadingDrag != null ? visualInset : 0,
                bottom: hasTrailing && onTrailingDrag != null ? visualInset : 0,
              ),
              child: child,
            );

    return Stack(
      fit: StackFit.expand,
      children: [
        padded,
        if (axis == Axis.horizontal && hasLeading && onLeadingDrag != null)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: handleExtent,
            child: _EdgeHandle(
              axis: handleAxis,
              onDrag: onLeadingDrag!,
              onEnd: onDragEnd,
            ),
          ),
        if (axis == Axis.horizontal && hasTrailing && onTrailingDrag != null)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: handleExtent,
            child: _EdgeHandle(
              axis: handleAxis,
              onDrag: onTrailingDrag!,
              onEnd: onDragEnd,
            ),
          ),
        if (axis == Axis.vertical && hasLeading && onLeadingDrag != null)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: handleExtent,
            child: _EdgeHandle(
              axis: handleAxis,
              onDrag: onLeadingDrag!,
              onEnd: onDragEnd,
            ),
          ),
        if (axis == Axis.vertical && hasTrailing && onTrailingDrag != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: handleExtent,
            child: _EdgeHandle(
              axis: handleAxis,
              onDrag: onTrailingDrag!,
              onEnd: onDragEnd,
            ),
          ),
      ],
    );
  }
}

class _EdgeHandle extends StatefulWidget {
  const _EdgeHandle({
    required this.axis,
    required this.onDrag,
    required this.onEnd,
  });

  final Axis axis;
  final ValueChanged<double> onDrag;
  final VoidCallback onEnd;

  @override
  State<_EdgeHandle> createState() => _EdgeHandleState();
}

class _EdgeHandleState extends State<_EdgeHandle> {
  bool _didMove = false;

  @override
  Widget build(BuildContext context) {
    final cursor =
        widget.axis == Axis.vertical
            ? SystemMouseCursors.resizeLeftRight
            : SystemMouseCursors.resizeUpDown;
    final gesture =
        widget.axis == Axis.vertical
            ? GestureDetector(
              behavior: HitTestBehavior.opaque,
              onHorizontalDragStart: (_) {
                _didMove = false;
                HapticFeedback.selectionClick();
              },
              onHorizontalDragUpdate: (details) {
                _didMove = true;
                widget.onDrag(details.delta.dx);
              },
              onHorizontalDragEnd: (_) {
                if (_didMove) widget.onEnd();
              },
              onHorizontalDragCancel: () {
                if (_didMove) widget.onEnd();
              },
              child: const SizedBox.expand(),
            )
            : GestureDetector(
              behavior: HitTestBehavior.opaque,
              onVerticalDragStart: (_) {
                _didMove = false;
                HapticFeedback.selectionClick();
              },
              onVerticalDragUpdate: (details) {
                _didMove = true;
                widget.onDrag(details.delta.dy);
              },
              onVerticalDragEnd: (_) {
                if (_didMove) widget.onEnd();
              },
              onVerticalDragCancel: () {
                if (_didMove) widget.onEnd();
              },
              child: const SizedBox.expand(),
            );
    return MouseRegion(cursor: cursor, opaque: false, child: gesture);
  }
}

class _DraggableCell extends StatefulWidget {
  const _DraggableCell({
    required this.sessionId,
    required this.onMoveCell,
    required this.child,
  });

  final String sessionId;
  final void Function(String fromSessionId, String toSessionId, DropSide side)
  onMoveCell;
  final Widget child;

  @override
  State<_DraggableCell> createState() => _DraggableCellState();
}

class _DraggableCellState extends State<_DraggableCell> {
  static const double _feedbackWidth = 220;
  static const double _feedbackHeight = 140;
  DropSide? _hoverSide;
  bool _isDragSource = false;

  DropSide _sideForOffset(Offset local, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final dx = local.dx - cx;
    final dy = local.dy - cy;
    if (dx.abs() > dy.abs()) {
      return dx < 0 ? DropSide.left : DropSide.right;
    }
    return dy < 0 ? DropSide.top : DropSide.bottom;
  }

  @override
  Widget build(BuildContext context) {
    final accent = Theme.of(context).colorScheme.primary;
    return LongPressDraggable<String>(
      data: widget.sessionId,
      delay: const Duration(milliseconds: 220),
      hapticFeedbackOnStart: true,
      dragAnchorStrategy: (_, _, _) => const Offset(_feedbackWidth / 2, 0),
      feedback: Material(
        color: Colors.transparent,
        child: Opacity(
          opacity: 0.85,
          child: SizedBox(
            width: _feedbackWidth,
            height: _feedbackHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: accent, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.35, child: widget.child),
      onDragStarted: () => setState(() => _isDragSource = true),
      onDragEnd: (_) => setState(() => _isDragSource = false),
      onDraggableCanceled: (_, _) => setState(() => _isDragSource = false),
      child: DragTarget<String>(
        onWillAcceptWithDetails: (details) {
          return details.data != widget.sessionId;
        },
        onMove: (details) {
          if (details.data == widget.sessionId) return;
          final box = context.findRenderObject() as RenderBox?;
          if (box == null) return;
          final local = box.globalToLocal(details.offset);
          final side = _sideForOffset(local, box.size);
          if (side != _hoverSide) {
            setState(() => _hoverSide = side);
          }
        },
        onLeave: (_) => setState(() => _hoverSide = null),
        onAcceptWithDetails: (details) {
          final side = _hoverSide;
          setState(() => _hoverSide = null);
          if (side == null) return;
          if (details.data == widget.sessionId) return;
          widget.onMoveCell(details.data, widget.sessionId, side);
        },
        builder: (context, candidates, _) {
          return Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (_hoverSide != null && !_isDragSource)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: _DropIndicatorPainter(
                        side: _hoverSide!,
                        color: accent,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _DropIndicatorPainter extends CustomPainter {
  _DropIndicatorPainter({required this.side, required this.color});

  final DropSide side;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final fill = Paint()..color = color.withValues(alpha: 0.18);
    final stroke =
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3;
    Rect rect;
    switch (side) {
      case DropSide.left:
        rect = Rect.fromLTWH(0, 0, size.width / 2, size.height);
        break;
      case DropSide.right:
        rect = Rect.fromLTWH(size.width / 2, 0, size.width / 2, size.height);
        break;
      case DropSide.top:
        rect = Rect.fromLTWH(0, 0, size.width, size.height / 2);
        break;
      case DropSide.bottom:
        rect = Rect.fromLTWH(0, size.height / 2, size.width, size.height / 2);
        break;
    }
    final rrect = RRect.fromRectAndRadius(
      rect.deflate(4),
      const Radius.circular(8),
    );
    canvas.drawRRect(rrect, fill);
    canvas.drawRRect(rrect, stroke);
  }

  @override
  bool shouldRepaint(covariant _DropIndicatorPainter old) {
    return old.side != side || old.color != color;
  }
}
