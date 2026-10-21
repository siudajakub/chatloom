// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_motion.dart';
import 'notion_switchers.dart';
import 'notion_tokens.dart';

/// A one-line muted status under a header title or name (connection
/// status in the inbox and chat headers, as Telegram shows it).
/// Grows in when [status] appears and shrinks away when it clears.
class NotionStatusLine extends StatefulWidget {
  const NotionStatusLine({super.key, this.status});

  final String? status;

  @override
  State<NotionStatusLine> createState() => _NotionStatusLineState();
}

class _NotionStatusLineState extends State<NotionStatusLine> {
  String? _last;

  @override
  Widget build(BuildContext context) {
    final status = widget.status;
    if (status != null) _last = status;
    final shown = _last;
    if (shown == null) return const SizedBox.shrink();
    return NotionSizeReveal(
      visible: status != null,
      revealOnMount: true,
      duration: NotionMotion.short,
      child: NotionFadeThrough(
        duration: NotionMotion.short,
        alignment: AlignmentDirectional.centerStart,
        child: Semantics(
          key: ValueKey(shown),
          liveRegion: true,
          child: Text(
            shown,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: context.notion.typography.captionMuted,
          ),
        ),
      ),
    );
  }
}
