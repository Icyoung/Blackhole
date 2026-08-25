import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

typedef FocusableTapBuilder =
    Widget Function(
      BuildContext context,
      bool focused,
      bool hovered,
      bool pressed,
    );

class FocusableTapRegion extends StatefulWidget {
  const FocusableTapRegion({
    super.key,
    required this.builder,
    this.onTap,
    this.onLongPress,
    this.semanticLabel,
    this.autofocus = false,
    this.focusNode,
    this.onKeyEvent,
    this.activateOnSpace = true,
  });

  final FocusableTapBuilder builder;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final String? semanticLabel;
  final bool autofocus;
  final FocusNode? focusNode;
  final FocusOnKeyEventCallback? onKeyEvent;

  /// Whether Space activates this region when it has focus.
  ///
  /// Disable this for wrappers around editable surfaces, such as terminal
  /// panes, so Space can reach the descendant input widget.
  final bool activateOnSpace;

  @override
  State<FocusableTapRegion> createState() => _FocusableTapRegionState();
}

class _FocusableTapRegionState extends State<FocusableTapRegion> {
  bool _focused = false;
  bool _hovered = false;
  bool _pressed = false;

  bool get _enabled => widget.onTap != null || widget.onLongPress != null;

  void _activate() {
    if (!_enabled) {
      return;
    }
    widget.onTap?.call();
  }

  @override
  Widget build(BuildContext context) {
    final child = widget.builder(context, _focused, _hovered, _pressed);

    final shortcuts = <ShortcutActivator, Intent>{
      const SingleActivator(LogicalKeyboardKey.select): ActivateIntent(),
      const SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
      if (widget.activateOnSpace)
        const SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
    };

    return FocusableActionDetector(
      autofocus: widget.autofocus,
      focusNode: widget.focusNode,
      enabled: _enabled,
      mouseCursor:
          _enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      shortcuts: shortcuts,
      actions: <Type, Action<Intent>>{
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            _activate();
            return null;
          },
        ),
      },
      onShowFocusHighlight: (value) => setState(() => _focused = value),
      onShowHoverHighlight: (value) => setState(() => _hovered = value),
      child: Focus(
        onKeyEvent: widget.onKeyEvent,
        child: Semantics(
          button: _enabled,
          enabled: _enabled,
          label: widget.semanticLabel,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _enabled ? _activate : null,
            onLongPress: widget.onLongPress,
            onTapDown: _enabled ? (_) => setState(() => _pressed = true) : null,
            onTapUp: _enabled ? (_) => setState(() => _pressed = false) : null,
            onTapCancel:
                _enabled ? () => setState(() => _pressed = false) : null,
            child: child,
          ),
        ),
      ),
    );
  }
}
