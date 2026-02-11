import 'package:flutter/material.dart';

/// Icon-only button with circular hover/press feedback (matches HeaderChrome add-tab button).
class SidebarToggleButton extends StatefulWidget {
  const SidebarToggleButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.diameter = 24,
    this.hoverBg = const Color(0x14FFFFFF), // white @ ~0.08
    this.pressedBg = const Color(0x26FFFFFF), // white @ ~0.15
    this.tooltip,
  });

  final Widget icon;
  final VoidCallback onTap;

  final double diameter;
  final Color hoverBg;
  final Color pressedBg;
  final String? tooltip;

  @override
  State<SidebarToggleButton> createState() => _SidebarToggleButtonState();
}

class _SidebarToggleButtonState extends State<SidebarToggleButton> {
  bool _hovered = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final Color bg;
    if (_pressed) {
      bg = widget.pressedBg;
    } else if (_hovered) {
      bg = widget.hoverBg;
    } else {
      bg = Colors.transparent;
    }

    Widget child = MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() {
        _hovered = false;
        _pressed = false;
      }),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: (_) => setState(() => _pressed = true),
        onTapUp: (_) => setState(() => _pressed = false),
        onTapCancel: () => setState(() => _pressed = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          width: widget.diameter,
          height: widget.diameter,
          decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
          child: Center(child: widget.icon),
        ),
      ),
    );

    final tooltip = widget.tooltip;
    if (tooltip != null && tooltip.isNotEmpty) {
      child = Tooltip(message: tooltip, child: child);
    }

    return child;
  }
}
