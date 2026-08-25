import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TvFocusScope extends StatelessWidget {
  const TvFocusScope({
    super.key,
    required this.child,
    this.enabled = true,
    this.onBack,
  });

  final Widget child;
  final bool enabled;
  final VoidCallback? onBack;

  @override
  Widget build(BuildContext context) {
    if (!enabled) {
      return child;
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowUp):
            () => moveFocus(context, TraversalDirection.up),
        const SingleActivator(LogicalKeyboardKey.arrowDown):
            () => moveFocus(context, TraversalDirection.down),
        const SingleActivator(LogicalKeyboardKey.arrowLeft):
            () => moveFocus(context, TraversalDirection.left),
        const SingleActivator(LogicalKeyboardKey.arrowRight):
            () => moveFocus(context, TraversalDirection.right),
        const SingleActivator(LogicalKeyboardKey.escape): () => _back(context),
        const SingleActivator(LogicalKeyboardKey.goBack): () => _back(context),
      },
      child: Focus(
        autofocus: true,
        skipTraversal: true,
        child: FocusTraversalGroup(
          policy: ReadingOrderTraversalPolicy(),
          child: child,
        ),
      ),
    );
  }

  void _back(BuildContext context) {
    final callback = onBack;
    if (callback != null) {
      callback();
      return;
    }
    Navigator.of(context).maybePop();
  }

  static void moveFocus(BuildContext context, TraversalDirection direction) {
    final scope = FocusScope.of(context);
    if (!scope.focusInDirection(direction)) {
      switch (direction) {
        case TraversalDirection.up:
        case TraversalDirection.left:
          scope.previousFocus();
          break;
        case TraversalDirection.down:
        case TraversalDirection.right:
          scope.nextFocus();
          break;
      }
    }
  }
}
