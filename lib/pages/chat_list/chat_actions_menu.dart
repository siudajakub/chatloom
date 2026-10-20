// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// The long-press actions of an inbox row. Deliberately short: everything
/// else (leave, block, tags, spaces, low priority) lives in chat details.
enum ChatMenuAction { pin, merge, unmerge, notifications, ignore }

class ChatMenuItem {
  final ChatMenuAction action;
  final IconData icon;
  final String label;
  final bool enabled;
  const ChatMenuItem(this.action, this.icon, this.label, {this.enabled = true});
}

/// Rounded glass panel anchored to the long-pressed row, in the inbox
/// dock's language (overlay tint, hairline, rounded corners, inset row
/// highlights). It grows from the row with the popover motion and blurs
/// only once the popover has settled (DESIGN.md "Glass").
Future<ChatMenuAction?> showChatActionsMenu(
  BuildContext context, {
  required Rect anchor,
  required String title,
  required List<ChatMenuItem> items,
  Widget? avatar,
}) {
  NotionHaptics.longPress();
  final root = Navigator.of(context, rootNavigator: true).context;
  final window =
      (root.findRenderObject() as RenderBox?)?.size ??
      MediaQuery.sizeOf(context);
  // A large anchor (the whole inbox for a pinned shortcut) centres the menu.
  final centred = anchor.height > window.height * .4;
  final below = !centred && anchor.bottom < window.height * .6;
  final origin = centred
      ? anchor.center
      : Offset(
          anchor.left + NotionSize.avatar,
          below ? anchor.bottom : anchor.top,
        );
  return showNotionPopover<ChatMenuAction>(
    context: context,
    alignment: window.isEmpty
        ? Alignment.center
        : Alignment(
            (origin.dx / window.width * 2 - 1).clamp(-1.0, 1.0),
            (origin.dy / window.height * 2 - 1).clamp(-1.0, 1.0),
          ),
    builder: (context) => CustomSingleChildLayout(
      delegate: _ChatMenuLayout(
        anchor: anchor,
        padding: MediaQuery.paddingOf(context),
        below: below,
        centred: centred,
      ),
      child: ChatActionsPanel(title: title, avatar: avatar, items: items),
    ),
  );
}

class _ChatMenuLayout extends SingleChildLayoutDelegate {
  final Rect anchor;
  final EdgeInsets padding;
  final bool below;
  final bool centred;
  const _ChatMenuLayout({
    required this.anchor,
    required this.padding,
    required this.below,
    this.centred = false,
  });

  static const _maxWidth = 280.0;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(
          0,
          math.min(_maxWidth, constraints.maxWidth - 2 * NotionSpace.md),
        ),
        maxHeight: math.max(
          0,
          constraints.maxHeight - padding.vertical - 2 * NotionSpace.md,
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size child) {
    final maxLeft = math.max(
      NotionSpace.md,
      size.width - child.width - NotionSpace.md,
    );
    final left = centred
        ? (size.width - child.width) / 2
        : (anchor.left + NotionSpace.lg).clamp(NotionSpace.md, maxLeft);
    final minTop = padding.top + NotionSpace.md;
    final maxTop = math.max(
      minTop,
      size.height - padding.bottom - NotionSpace.md - child.height,
    );
    final top = centred
        ? anchor.center.dy - child.height / 2
        : below
        ? anchor.bottom + NotionSpace.xxs
        : anchor.top - NotionSpace.xxs - child.height;
    return Offset(left, top.clamp(minTop, maxTop));
  }

  @override
  bool shouldRelayout(_ChatMenuLayout old) =>
      old.anchor != anchor ||
      old.padding != padding ||
      old.below != below ||
      old.centred != centred;
}

class ChatActionsPanel extends StatelessWidget {
  final String title;
  final Widget? avatar;
  final List<ChatMenuItem> items;
  const ChatActionsPanel({
    super.key,
    required this.title,
    required this.items,
    this.avatar,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    return NotionGlassPanel(
      child: Focus(
        autofocus: true,
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(vertical: NotionSpace.xs),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: NotionEntrance.stagger(
              [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NotionSpace.md,
                    NotionSpace.xxs,
                    NotionSpace.md,
                    NotionSpace.xs,
                  ),
                  child: Row(
                    children: [
                      if (avatar != null) ...[
                        ExcludeSemantics(
                          child: SizedBox.square(
                            dimension: NotionSize.avatarSm,
                            child: avatar,
                          ),
                        ),
                        const SizedBox(width: NotionSpace.sm),
                      ],
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: tokens.typography.bodyStrong,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const NotionGlassDivider(vertical: false),
                for (final item in items) _ChatMenuRow(item: item),
              ],
              rise: NotionMotion.rise / 2,
              afterRoute: false,
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatMenuRow extends StatelessWidget {
  final ChatMenuItem item;
  const _ChatMenuRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final color = item.enabled
        ? tokens.colors.text
        : tokens.colors.textTertiary;
    return NotionPressable(
      enabled: item.enabled,
      scale: NotionMotion.pressRow,
      child: NotionGlassMenuRow(
        key: ValueKey('chat-menu-${item.action.name}'),
        leading: Icon(item.icon, size: NotionSize.icon, color: color),
        title: item.label,
        style: tokens.typography.body.copyWith(color: color),
        onTap: item.enabled
            ? () => Navigator.of(context).pop(item.action)
            : null,
      ),
    );
  }
}
