// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:cross_file/cross_file.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:material_ui/material_ui.dart';

/// Files dragged from Finder onto a conversation (desktop): a calm overlay
/// while they hover, [onFiles] when dropped. Only the overlay rebuilds; the
/// conversation below keeps its element (the overlay is a second child).
class ConversationDropTarget extends StatefulWidget {
  const ConversationDropTarget({
    super.key,
    required this.child,
    required this.onFiles,
    this.enabled = true,
  });

  final Widget child;
  final ValueChanged<List<XFile>> onFiles;

  /// False ignores drops (no source, sending).
  final bool enabled;

  @override
  State<ConversationDropTarget> createState() => _ConversationDropTargetState();
}

class _ConversationDropTargetState extends State<ConversationDropTarget> {
  final _dragging = ValueNotifier(false);

  @override
  void dispose() {
    _dragging.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => DropTarget(
    enable: widget.enabled,
    onDragEntered: (_) => _dragging.value = true,
    onDragExited: (_) => _dragging.value = false,
    onDragDone: (details) {
      _dragging.value = false;
      if (details.files.isNotEmpty) widget.onFiles(details.files);
    },
    child: Stack(
      fit: StackFit.expand,
      children: [
        widget.child,
        Positioned.fill(
          child: IgnorePointer(
            child: ValueListenableBuilder<bool>(
              valueListenable: _dragging,
              builder: (context, dragging, _) => dragging
                  ? ColoredBox(
                      color: Theme.of(
                        context,
                      ).scaffoldBackgroundColor.withAlpha(230),
                      child: Center(
                        child: Icon(
                          Icons.upload_outlined,
                          size: NotionSize.avatarLg,
                          color: context.notion.colors.textSecondary,
                        ),
                      ),
                    )
                  : const SizedBox.shrink(),
            ),
          ),
        ),
      ],
    ),
  );
}
