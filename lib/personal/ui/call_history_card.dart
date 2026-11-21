// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/personal/bridge_notices.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// A record of a bridge call in its chronological place in the conversation.
class CallHistoryCard extends StatelessWidget {
  const CallHistoryCard({
    super.key,
    required this.call,
    required this.time,
    this.source,
  });

  final BridgeCallNotice call;
  final String time;
  final String? source;

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    final title = switch (call.kind) {
      BridgeCallKind.voice => 'Voice call',
      BridgeCallKind.video => 'Video call',
      BridgeCallKind.unknown => 'Call',
    };
    final direction = switch (call.direction) {
      BridgeCallDirection.incoming => 'Incoming',
      BridgeCallDirection.outgoing => 'Outgoing',
      null => null,
    };
    final outcome = switch (call.outcome) {
      BridgeCallOutcome.incoming => 'Incoming',
      BridgeCallOutcome.outgoing => 'Outgoing',
      BridgeCallOutcome.started => 'Started',
      BridgeCallOutcome.missed => 'Missed',
      BridgeCallOutcome.answered => 'Answered',
      BridgeCallOutcome.rejected => 'Declined',
      BridgeCallOutcome.failed => 'Failed',
      BridgeCallOutcome.silenced => 'Silenced',
      BridgeCallOutcome.ended => 'Ended',
      BridgeCallOutcome.disconnected => 'Disconnected',
      BridgeCallOutcome.canceled => 'Canceled',
      BridgeCallOutcome.unknown =>
        call.text.toLowerCase() == title.toLowerCase() ? null : call.text,
    };
    final duration = call.duration;
    final detail = [
      if (direction != outcome) ?direction,
      ?outcome,
      if (duration != null) _formatDuration(duration),
    ].join(' · ');
    final metadata = [?source, time].join(' · ');
    final unsuccessful = switch (call.outcome) {
      BridgeCallOutcome.missed ||
      BridgeCallOutcome.rejected ||
      BridgeCallOutcome.failed ||
      BridgeCallOutcome.disconnected => true,
      _ => false,
    };

    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NotionSpace.xl,
        vertical: NotionSpace.xxs,
      ),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: NotionSize.dialogMaxWidth,
          ),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: notion.colors.surface,
              border: Border.all(color: notion.colors.border),
              borderRadius: NotionRadius.lgAll,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: NotionSpace.sm,
                vertical: NotionSpace.xs,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      color: notion.colors.selected,
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(NotionSpace.xs),
                      child: Icon(
                        call.kind == BridgeCallKind.video
                            ? Icons.videocam_outlined
                            : call.icon,
                        size: NotionSize.icon,
                        color: unsuccessful
                            ? notion.colors.danger
                            : notion.colors.text,
                      ),
                    ),
                  ),
                  const SizedBox(width: NotionSpace.sm),
                  Flexible(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(title, style: notion.typography.bodyStrong),
                        if (detail.isNotEmpty)
                          Text(
                            detail,
                            style: notion.typography.body,
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        Text(metadata, style: notion.typography.captionMuted),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _formatDuration(Duration duration) {
  if (duration.inHours == 0) return notionAudioTime(duration);
  final minutes = (duration.inMinutes % 60).toString().padLeft(2, '0');
  final seconds = (duration.inSeconds % 60).toString().padLeft(2, '0');
  return '${duration.inHours}:$minutes:$seconds';
}
