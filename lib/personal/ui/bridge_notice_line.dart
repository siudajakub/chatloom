// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/bridge_notices.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// A bridge's notice as a small centred service line (BR-08), like the
/// timeline's day chips and state lines: opaque `surface` pill, secondary
/// text, a leading glyph. It never looks like the contact wrote it.
class BridgeNoticeLine extends StatelessWidget {
  final BridgeServiceNotice notice;
  const BridgeNoticeLine({super.key, required this.notice});

  @override
  Widget build(BuildContext context) {
    final notion = context.notion;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NotionSpace.xl,
        vertical: NotionSpace.xxs,
      ),
      child: Center(
        child: DecoratedBox(
          key: const ValueKey('bridge-notice-line'),
          decoration: BoxDecoration(
            color: notion.colors.surface,
            borderRadius: NotionRadius.lgAll,
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NotionSpace.sm,
              vertical: NotionSpace.xxs,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  notice.icon,
                  size: NotionSize.iconSm,
                  color: notion.colors.textSecondary,
                ),
                const SizedBox(width: NotionSpace.xxs),
                Flexible(
                  child: Text(
                    notice.text,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: notion.typography.captionMuted,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
