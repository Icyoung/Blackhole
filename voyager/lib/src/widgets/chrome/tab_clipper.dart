import 'package:flutter/material.dart';

class TabClipper extends CustomClipper<Path> {
  static Path buildPath(Size size) {
    final w = size.width;
    final h = size.height;

    // Fixed shoulder width (left+right). Clamp so it never exceeds the widget width.
    final moldWidth = w < 40.0 ? w : 40.0;

    const c1 = 0.40;
    const c2 = 0.65;

    final topY = 0.0;
    final bottomY = h * 0.9;

    final shoulder = moldWidth / 2.0;
    final leftJoinX = shoulder;
    final rightJoinX = w - shoulder;

    // Right curve control points (defined in absolute coordinates)
    final cp1R = Offset(rightJoinX + shoulder * c1, topY);
    final cp2R = Offset(rightJoinX + shoulder * c2, bottomY);

    // Mirror those control points across the vertical centerline x = w/2
    final cp1LForward = Offset(w - cp1R.dx, topY);
    final cp2LForward = Offset(w - cp2R.dx, bottomY);

    return Path()
      // Top cap
      ..moveTo(0, topY)
      ..lineTo(w, topY)

      // Right shoulder (top -> bottom)
      ..cubicTo(cp1R.dx, cp1R.dy, cp2R.dx, cp2R.dy, rightJoinX, bottomY)

      // Bottom flat stretch (the only part that grows with width)
      ..lineTo(leftJoinX, bottomY)

      // Left shoulder (bottom -> top), using the *reversed* mirrored control points
      ..cubicTo(
        cp2LForward.dx,
        cp2LForward.dy,
        cp1LForward.dx,
        cp1LForward.dy,
        0,
        topY,
      )
      ..close();
  }

  @override
  Path getClip(Size size) {
    return buildPath(size);
  }

  @override
  bool shouldReclip(covariant TabClipper oldClipper) => false;
}

class TabClipperInverted extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final path = TabClipper.buildPath(size);
    final matrix = Matrix4.identity()
      // ignore: deprecated_member_use
      ..translate(0.0, size.height)
      // ignore: deprecated_member_use
      ..scale(1.0, -1.0);
    return path.transform(matrix.storage);
  }

  @override
  bool shouldReclip(covariant TabClipperInverted oldClipper) => false;
}
