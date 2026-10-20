// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Slim strip under a chat header: "3 messages couldn't be decrypted" with
/// a "Fix" action. Lives inside the glass header, so it has no fill of its
/// own. Data and callbacks only.
class UndecryptableChatHint extends StatelessWidget {
  final int count;
  final VoidCallback onFix;

  const UndecryptableChatHint({
    super.key,
    required this.count,
    required this.onFix,
  });

  /// Fixed strip height, scaled with text so large type never clips.
  static double heightFor(TextScaler scaler) =>
      scaler.scale(NotionSpace.xxl + NotionSpace.xs);

  static String label(int count) => count == 1
      ? '1 message couldn’t be decrypted'
      : '$count messages couldn’t be decrypted';

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    return SizedBox(
      height: heightFor(MediaQuery.textScalerOf(context)),
      child: Padding(
        padding: const EdgeInsets.only(
          left: NotionSpace.inset,
          right: NotionSpace.xs,
        ),
        child: Row(
          children: [
            Icon(
              Icons.lock_clock_outlined,
              size: NotionSize.iconSm,
              color: tokens.colors.textSecondary,
            ),
            const SizedBox(width: NotionSpace.xs),
            Expanded(
              child: Text(
                label(count),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: tokens.typography.footnoteMuted,
              ),
            ),
            NotionButton.ghost(label: 'Fix', onPressed: onFix),
          ],
        ),
      ),
    );
  }
}
