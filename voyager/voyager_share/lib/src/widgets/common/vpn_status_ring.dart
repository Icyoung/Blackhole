import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../design_tokens.dart';

/// A status dot wrapped with a VPN outline ring.
///
/// - No VPN: plain status dot (no ring)
/// - VPN connecting: animated chasing/marching ring (spinner around the dot)
/// - VPN connected: solid green ring around the dot
class VpnStatusRing extends StatefulWidget {
  const VpnStatusRing({
    super.key,
    required this.connected,
    required this.vpnState,
    this.size = 10,
    this.ringWidth = 2.0,
    this.ringGap = 2.0,
  });

  final bool connected;

  /// `none` = no VPN, `connecting` = marching animation, `connected` = solid ring
  final VpnRingState vpnState;

  /// Size of the inner status dot.
  final double size;

  /// Width of the outline ring stroke.
  final double ringWidth;

  /// Gap between dot and ring.
  final double ringGap;

  @override
  State<VpnStatusRing> createState() => _VpnStatusRingState();
}

enum VpnRingState { none, connecting, connected }

class _VpnStatusRingState extends State<VpnStatusRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _syncAnimation();
  }

  @override
  void didUpdateWidget(VpnStatusRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.vpnState != widget.vpnState) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    if (widget.vpnState == VpnRingState.connecting) {
      _controller.repeat();
    } else {
      _controller.stop();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dotColor = widget.connected
        ? AppColors.statusGreen
        : AppColors.statusRed;

    final totalSize =
        widget.size + (widget.ringGap + widget.ringWidth) * 2;

    return SizedBox(
      width: totalSize,
      height: totalSize,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Ring (only when VPN active)
          if (widget.vpnState != VpnRingState.none)
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                return CustomPaint(
                  size: Size(totalSize, totalSize),
                  painter: _RingPainter(
                    state: widget.vpnState,
                    progress: _controller.value,
                    ringWidth: widget.ringWidth,
                    color: widget.vpnState == VpnRingState.connected
                        ? AppColors.statusGreen
                        : AppColors.statusYellow,
                  ),
                );
              },
            ),
          // Inner status dot
          Container(
            width: widget.size,
            height: widget.size,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: dotColor.withValues(alpha: 0.4),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  _RingPainter({
    required this.state,
    required this.progress,
    required this.ringWidth,
    required this.color,
  });

  final VpnRingState state;
  final double progress;
  final double ringWidth;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = (size.width - ringWidth) / 2;
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = ringWidth
      ..strokeCap = StrokeCap.round;

    if (state == VpnRingState.connected) {
      // Full solid ring with glow
      paint.color = color.withValues(alpha: 0.3);
      canvas.drawCircle(center, radius, paint);
      paint.color = color;
      canvas.drawCircle(center, radius, paint);
    } else if (state == VpnRingState.connecting) {
      // Marching arc — a sweeping segment that chases around the circle
      final startAngle = progress * 2 * math.pi - math.pi / 2;
      const sweepAngle = math.pi * 0.7; // ~126 degrees arc

      // Faint background ring
      paint.color = color.withValues(alpha: 0.15);
      canvas.drawCircle(center, radius, paint);

      // Bright chasing arc
      paint.color = color;
      final rect = Rect.fromCircle(center: center, radius: radius);
      canvas.drawArc(rect, startAngle, sweepAngle, false, paint);
    }
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      state != oldDelegate.state ||
      progress != oldDelegate.progress ||
      color != oldDelegate.color;
}
