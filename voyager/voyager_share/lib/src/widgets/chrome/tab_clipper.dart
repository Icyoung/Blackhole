import 'package:flutter/material.dart';

/// Simple rounded rectangle — used by non-tab elements (buttons).
class TabClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    return Path()
      ..addRRect(RRect.fromLTRBR(
        0, 0, size.width, size.height,
        const Radius.circular(6),
      ));
  }

  @override
  bool shouldReclip(covariant TabClipper oldClipper) => false;
}

/// Chrome-style tab shape: rounded top corners, smooth concave bottom corners
/// that extend outward to meet the tab bar.
class TabClipperInverted extends CustomClipper<Path> {
  static const double _r = 6.0;   // top corner radius
  static const double _ext = 9.0; // bottom concave extension

  @override
  Path getClip(Size size) {
    final w = size.width;
    final h = size.height;

    return Path()
      ..moveTo(_ext + _r, 0)
      // Top edge
      ..lineTo(w - _ext - _r, 0)
      // Top-right rounded corner
      ..arcToPoint(Offset(w - _ext, _r), radius: const Radius.circular(_r))
      // Right side
      ..lineTo(w - _ext, h - _ext)
      // Bottom-right concave curve (cubic bezier for smooth transition)
      ..cubicTo(
        w - _ext, h,            // cp1: vertical tangent at start
        w - _ext * 0.5, h,      // cp2: horizontal tangent at end
        w, h,                    // end
      )
      // Bottom edge
      ..lineTo(0, h)
      // Bottom-left concave curve
      ..cubicTo(
        _ext * 0.5, h,          // cp1: horizontal tangent at start
        _ext, h,                 // cp2: vertical tangent at end
        _ext, h - _ext,          // end
      )
      // Left side
      ..lineTo(_ext, _r)
      // Top-left rounded corner
      ..arcToPoint(Offset(_ext + _r, 0), radius: const Radius.circular(_r))
      ..close();
  }

  @override
  bool shouldReclip(covariant TabClipperInverted oldClipper) => false;
}
