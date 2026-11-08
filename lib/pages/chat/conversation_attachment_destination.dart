// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// The destination of the whole attachment selection, above its caption.
/// Routing belongs to the caller; this row only displays and opens its choice.
class ConversationAttachmentDestination extends StatelessWidget {
  final String network;
  final String recipient;
  final bool replyLocked;
  final VoidCallback? onPressed;

  const ConversationAttachmentDestination({
    super.key,
    required this.network,
    required this.recipient,
    this.replyLocked = false,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final name = notionNetworkLabel(network);
    final choose = replyLocked ? null : onPressed;
    final description = replyLocked ? 'Reply stays on this network' : recipient;
    return Semantics(
      label: 'Send via $name, $recipient',
      hint: replyLocked
          ? description
          : choose == null
          ? null
          : 'Choose sending source',
      button: choose != null,
      onTap: choose,
      excludeSemantics: true,
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          onTap: choose,
          borderRadius: NotionRadius.rowAll,
          child: NotionPressable(
            enabled: choose != null,
            scale: NotionMotion.pressRow,
            child: ConstrainedBox(
              constraints: const BoxConstraints(
                minHeight: NotionSize.touchTarget,
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: NotionSpace.sm,
                  vertical: NotionSpace.xs,
                ),
                child: Row(
                  children: [
                    NotionReappear(
                      trigger: network,
                      rise: 0,
                      child: NotionNetworkGlyph(
                        network: network.toLowerCase(),
                        size: NotionSize.iconLg,
                      ),
                    ),
                    const SizedBox(width: NotionSpace.sm),
                    Expanded(
                      child: NotionReappear(
                        trigger: (network, recipient),
                        rise: 0,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'Send via $name',
                              style: context.notion.typography.callout,
                            ),
                            Text(
                              description,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: context.notion.typography.captionMuted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (replyLocked || choose != null) ...[
                      const SizedBox(width: NotionSpace.xs),
                      Icon(
                        replyLocked
                            ? Icons.lock_outline_rounded
                            : Icons.expand_more_rounded,
                        size: NotionSize.icon,
                        color: context.notion.colors.textSecondary,
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
