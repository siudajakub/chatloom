// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/deleted_messages.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// The icon of a deleted message (WhatsApp's ⊘; a timer for a message that
/// disappeared).
IconData deletedMessageIcon(DeletedKind kind) =>
    kind == DeletedKind.disappeared ? Icons.timer_off_outlined : Icons.block;

/// A deleted message's words after its icon, muted and italic. The bubble
/// placeholder and reply quotes share this look; the words come from
/// [deletedLabel].
class DeletedMessageLabel extends StatelessWidget {
  final String label;
  final DeletedKind kind;
  final Color color;
  final TextStyle style;
  final int? maxLines;

  const DeletedMessageLabel({
    super.key,
    required this.label,
    required this.kind,
    required this.color,
    required this.style,
    this.maxLines,
  });

  @override
  Widget build(BuildContext context) {
    final size = style.fontSize ?? NotionType.body.fontSize!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          deletedMessageIcon(kind),
          // Follows the text size (message text size, accessibility).
          size: MediaQuery.textScalerOf(context).scale(size),
          color: color,
        ),
        const SizedBox(width: NotionSpace.xxs),
        Flexible(
          child: Text(
            label,
            maxLines: maxLines,
            overflow: maxLines == null ? null : TextOverflow.ellipsis,
            style: style.copyWith(color: color, fontStyle: FontStyle.italic),
          ),
        ),
      ],
    );
  }
}
