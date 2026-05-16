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
    required this.onResizeColumn,
    required this.onResizeRow,
    required this.onResizeEnd,
    this.onMoveCell,
    this.padding = EdgeInsets.zero,
    this.gap = 8,
    this.touchMinHitSize = 32,
    this.desktopHitSize = 6,
    this.mobileBreakpoint = 600,
    this.scrollPhysics,
  });

  final MultiWindowLayout layout;
  final LayoutCellBuilder cellBuilder;
  final WidgetBuilder? trailingBuilder;
  final void Function(int rowIndex, int cellIndex, double deltaPx, double width)
  onResizeColumn;
  final void Function(int rowIndex, double deltaPx, double height) onResizeRow;
  final VoidCallback onResizeEnd;
  final void Function(String fromSessionId, String toSessionId, DropSide side)?
  onMoveCell;
  final EdgeInsetsGeometry padding;
  final double gap;
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
        return Padding(
          padding: padding,
          child: _buildSplitLayout(context, constraints),
        );
      },
    );
  }

  Widget _buildSingleColumn(BuildContext context) {
    var index = 0;
    return ListView(
      padding: padding,
      physics: scrollPhysics,
      children: [
        for (final row in layout.rows)
          for (final cell in row.cells) ...[
            SizedBox(
              height: 280,
              child: cellBuilder(context, cell.sessionId, index++),
            ),
            SizedBox(height: gap),
          ],
        if (trailingBuilder != null)
          SizedBox(height: 180, child: trailingBuilder!(context)),
      ],
    );
  }

  Widget _buildSplitLayout(BuildContext context, BoxConstraints constraints) {
    final rows = layout.rows;
    if (rows.isEmpty) {
      return trailingBuilder?.call(context) ?? const SizedBox.shrink();
    }
    final hitSize = _hitSize(context);
    final innerHeight = constraints.maxHeight - _verticalPadding(context);
    var visualIndex = 0;
    final children = <Widget>[];
    for (var rowIndex = 0; rowIndex < rows.length; rowIndex++) {
      final row = rows[rowIndex];
      final firstVisualIndex = visualIndex;
      children.add(
        Expanded(
          flex: _flex(row.weight),
          child: LayoutBuilder(
            builder: (context, rowConstraints) {
              return _buildRow(
                context,
                row,
                rowIndex,
                rows.length,
                rowConstraints,
                innerHeight,
                firstVisualIndex,
                hitSize,
              );
            },
          ),
        ),
      );
      visualIndex += row.cells.length;
      if (rowIndex < rows.length - 1) {
        children.add(SizedBox(height: gap));
      }
    }
    return Column(children: children);
  }

  Widget _buildRow(
    BuildContext context,
    LayoutRow row,
    int rowIndex,
    int rowCount,
    BoxConstraints rowConstraints,
    double parentHeight,
    int firstVisualIndex,
    double hitSize,
  ) {
    final cells = row.cells;
    final children = <Widget>[];
    for (var cellIndex = 0; cellIndex < cells.length; cellIndex++) {
      final cell = cells[cellIndex];
      final cellChild = cellBuilder(
        context,
        cell.sessionId,
        firstVisualIndex + cellIndex,
      );
      final wrapped = onMoveCell == null
          ? cellChild
          : _DraggableCell(
              sessionId: cell.sessionId,
              onMoveCell: onMoveCell!,
              child: cellChild,
            );
      children.add(
        Expanded(
          flex: _flex(cell.weight),
          child: _ResizableCell(
            hitSize: hitSize,
            hasLeft: cellIndex > 0,
            hasRight: cellIndex < cells.length - 1,
            hasTop: rowIndex > 0,
            hasBottom: rowIndex < rowCount - 1,
            onLeftDrag:
                cellIndex > 0
                    ? (delta) => onResizeColumn(
                          rowIndex,
                          cellIndex - 1,
                          delta,
                          rowConstraints.maxWidth,
                        )
                    : null,
            onRightDrag:
                cellIndex < cells.length - 1
                    ? (delta) => onResizeColumn(
                          rowIndex,
                          cellIndex,
                          delta,
                          rowConstraints.maxWidth,
                        )
                    : null,
            onTopDrag:
                rowIndex > 0
                    ? (delta) =>
                        onResizeRow(rowIndex - 1, delta, parentHeight)
                    : null,
            onBottomDrag:
                rowIndex < rowCount - 1
                    ? (delta) => onResizeRow(rowIndex, delta, parentHeight)
                    : null,
            onDragEnd: onResizeEnd,
            child: wrapped,
          ),
        ),
      );
      if (cellIndex < cells.length - 1) {
        children.add(SizedBox(width: gap));
      }
    }
    if (trailingBuilder != null && rowIndex == rowCount - 1) {
      if (children.isNotEmpty) {
        children.add(SizedBox(width: gap));
      }
      children.add(Expanded(child: trailingBuilder!(context)));
    }
    return Row(children: children);
  }

  double _hitSize(BuildContext context) {
    final platform = Theme.of(context).platform;
    final touchPlatform =
        kIsWeb == false &&
        (platform == TargetPlatform.iOS || platform == TargetPlatform.android);
    return touchPlatform ? touchMinHitSize : desktopHitSize;
  }

  double _verticalPadding(BuildContext context) {
    final resolved = padding.resolve(Directionality.of(context));
    return resolved.top + resolved.bottom;
  }

  int _flex(double weight) {
    return (weight * 1000).round().clamp(1, 1000000);
  }
}

/// Wraps a cell with invisible edge handles so dragging either side of a
/// shared border resizes the same split. There is no visible splitter line
/// between cells — only the [gap] visual whitespace from the parent layout.
class _ResizableCell extends StatelessWidget {
  const _ResizableCell({
    required this.child,
    required this.hitSize,
    required this.hasLeft,
    required this.hasRight,
    required this.hasTop,
    required this.hasBottom,
    required this.onLeftDrag,
    required this.onRightDrag,
    required this.onTopDrag,
    required this.onBottomDrag,
    required this.onDragEnd,
  });

  final Widget child;
  final double hitSize;
  final bool hasLeft;
  final bool hasRight;
  final bool hasTop;
  final bool hasBottom;
  final ValueChanged<double>? onLeftDrag;
  final ValueChanged<double>? onRightDrag;
  final ValueChanged<double>? onTopDrag;
  final ValueChanged<double>? onBottomDrag;
  final VoidCallback onDragEnd;

  @override
  Widget build(BuildContext context) {
    final edge = hitSize;
    final hasAnyEdge = (hasLeft && onLeftDrag != null) ||
        (hasRight && onRightDrag != null) ||
        (hasTop && onTopDrag != null) ||
        (hasBottom && onBottomDrag != null);
    // Inset child by hitSize on every active edge so the LongPressDraggable
    // inside the cell never receives pointer events on the resize zone. The
    // EdgeHandle layers below sit on top of the inset gap and own those
    // pixels exclusively.
    final insetChild = hasAnyEdge
        ? Padding(
            padding: EdgeInsets.only(
              left: hasLeft && onLeftDrag != null ? edge : 0,
              right: hasRight && onRightDrag != null ? edge : 0,
              top: hasTop && onTopDrag != null ? edge : 0,
              bottom: hasBottom && onBottomDrag != null ? edge : 0,
            ),
            child: child,
          )
        : child;
    return Stack(
      fit: StackFit.expand,
      children: [
        insetChild,
        if (hasLeft && onLeftDrag != null)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: edge,
            child: _EdgeHandle(
              axis: Axis.vertical,
              onDrag: onLeftDrag!,
              onEnd: onDragEnd,
            ),
          ),
        if (hasRight && onRightDrag != null)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            width: edge,
            child: _EdgeHandle(
              axis: Axis.vertical,
              onDrag: onRightDrag!,
              onEnd: onDragEnd,
            ),
          ),
        if (hasTop && onTopDrag != null)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            height: edge,
            child: _EdgeHandle(
              axis: Axis.horizontal,
              onDrag: onTopDrag!,
              onEnd: onDragEnd,
            ),
          ),
        if (hasBottom && onBottomDrag != null)
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            height: edge,
            child: _EdgeHandle(
              axis: Axis.horizontal,
              onDrag: onBottomDrag!,
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
    final gesture = widget.axis == Axis.vertical
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
    return MouseRegion(
      cursor: cursor,
      opaque: false,
      child: gesture,
    );
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
    // Divide the cell into 4 wedges via the diagonals from center.
    // Whichever wedge the pointer is in determines the drop side.
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
      dragAnchorStrategy: (_, _, _) =>
          const Offset(_feedbackWidth / 2, 0),
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
          // details.offset is the pointer's global position.
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
    final stroke = Paint()
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
