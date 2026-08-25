import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/widgets.dart';

class VoyagerDropDoneDetails {
  const VoyagerDropDoneDetails({
    required this.files,
    required this.globalPosition,
  });

  factory VoyagerDropDoneDetails.fromDesktopDrop(DropDoneDetails details) {
    return VoyagerDropDoneDetails(
      files: details.files,
      globalPosition: details.globalPosition,
    );
  }

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
    if (!enabled) {
      return child;
    }
    return DropTarget(
      onDragDone:
          (details) =>
              onDragDone(VoyagerDropDoneDetails.fromDesktopDrop(details)),
      onDragEntered: (details) => onDragEntered(details.globalPosition),
      onDragExited: (_) => onDragExited(),
      onDragUpdated: (details) => onDragUpdated(details.globalPosition),
      child: child,
    );
  }
}
