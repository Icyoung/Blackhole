import 'package:flutter/widgets.dart';

class VoyagerDropDoneDetails {
  const VoyagerDropDoneDetails({
    required this.files,
    required this.globalPosition,
  });

  final List<dynamic> files;
  final Offset globalPosition;
}

class VoyagerDesktopDropTarget extends StatelessWidget {
  const VoyagerDesktopDropTarget({
    super.key,
    required this.enabled,
    required this.child,
    required this.onDragDone,
    required this.onDragEntered,
    required this.onDragExited,
    required this.onDragUpdated,
  });

  final bool enabled;
  final Widget child;
  final ValueChanged<VoyagerDropDoneDetails> onDragDone;
  final ValueChanged<Offset> onDragEntered;
  final VoidCallback onDragExited;
  final ValueChanged<Offset> onDragUpdated;

  @override
  Widget build(BuildContext context) {
    return child;
  }
}
