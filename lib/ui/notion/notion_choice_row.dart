// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:material_ui/material_ui.dart';

import 'notion_lazy_switcher.dart';
import 'notion_motion.dart';
import 'notion_pressable.dart';
import 'notion_tokens.dart';

/// One option of a single-choice list (chat history visibility, who may
/// join, a permission level): the title, an optional subtitle and, on the
/// selected option, an accent check (Telegram's settings lists). It replaces
/// `RadioListTile` on Notion pages.
///
/// `onTap: null` disables the row (muted text, no press); the selected
/// option keeps its check. The check swaps with [NotionLazySwitcher], so a
/// row costs no controller until the selection first changes.
class NotionChoiceRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool selected;
  final VoidCallback? onTap;

  const NotionChoiceRow({
    super.key,
    required this.title,
    this.subtitle,
    required this.selected,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final enabled = onTap != null;
    return Semantics(
      button: true,
      inMutuallyExclusiveGroup: true,
      selected: selected,
      enabled: enabled,
      child: NotionPressable(
        enabled: enabled,
        scale: NotionMotion.pressRow,
        child: InkWell(
          onTap: onTap,
          borderRadius: NotionRadius.rowAll,
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: NotionSize.rowMinHeight,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          title,
                          style: tokens.typography.body.copyWith(
                            color: enabled
                                ? tokens.colors.text
                                : tokens.colors.textTertiary,
                          ),
                        ),
                        if (subtitle != null)
                          Text(
                            subtitle!,
                            style: tokens.typography.footnoteMuted,
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: NotionSpace.sm),
                  SizedBox.square(
                    dimension: NotionSize.iconLg,
                    child: NotionLazySwitcher(
                      style: NotionLazySwitch.morph,
                      alignment: Alignment.center,
                      child: selected
                          ? Icon(
                              Icons.check,
                              key: const ValueKey(true),
                              size: NotionSize.iconMd,
                              color: enabled
                                  ? tokens.colors.accent
                                  : tokens.colors.textTertiary,
                            )
                          : const SizedBox.shrink(key: ValueKey(false)),
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
