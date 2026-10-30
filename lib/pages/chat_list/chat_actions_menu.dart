// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// What swiping an inbox row does (Settings → Chats → Swipe left / right).
enum InboxSwipeChoice {
  archive('Archive'),
  read('Mark as read or unread'),
  pin('Pin or unpin'),
  none('Nothing');

  final String label;
  const InboxSwipeChoice(this.label);

  static InboxSwipeChoice parse(String? name, InboxSwipeChoice fallback) =>
      values.firstWhere((value) => value.name == name, orElse: () => fallback);
}

/// The long-press actions of an inbox row (Telegram, Messenger). Deliberately
/// short: everything else (leave, block, tags, spaces, low priority) lives in
/// chat details; notification details sit at the end of the Mute menu.
/// "Delete chat…" appears only where the chat's bridge can delete it on the
/// network (FX-01) and always asks first.
enum ChatMenuAction {
  read,
  unread,
  pin,
  moveDown,
  mute,
  unmute,
  archive,
  unarchive,
  merge,
  unmerge,
  notifications,
  ignore,
  deleteChat,
}

/// The second step of "Mute…": how long (Telegram's durations), or the
/// chat's notification settings.
enum MuteChoice {
  hour(Duration(hours: 1)),
  eightHours(Duration(hours: 8)),
  week(Duration(days: 7)),
  always(null),
  settings(null);

  const MuteChoice(this.duration);

  /// Null: no end ([always]) or not a mute ([settings]).
  final Duration? duration;
}

class ChatMenuItem<T extends Object> {
  final T action;
  final IconData icon;
  final String label;
  final bool enabled;

  /// Irreversible on the network: drawn in the danger colour.
  final bool destructive;
  const ChatMenuItem(
    this.action,
    this.icon,
    this.label, {
    this.enabled = true,
    this.destructive = false,
  });

  String get keyName => switch (action) {
    final Enum value => value.name,
    final value => '$value',
  };
}

/// The rows of the Mute menu; the durations need private sync ([canMute]),
/// the settings row is always there.
List<ChatMenuItem<MuteChoice>> muteMenuItems({required bool canMute}) => [
  ChatMenuItem(MuteChoice.hour, Icons.schedule, 'For 1 hour', enabled: canMute),
  ChatMenuItem(
    MuteChoice.eightHours,
    Icons.bedtime_outlined,
    'For 8 hours',
    enabled: canMute,
  ),
  ChatMenuItem(
    MuteChoice.week,
    Icons.date_range_outlined,
    'For 1 week',
    enabled: canMute,
  ),
  ChatMenuItem(
    MuteChoice.always,
    Icons.notifications_off_outlined,
    'Until I unmute',
    enabled: canMute,
  ),
  const ChatMenuItem(MuteChoice.settings, Icons.tune, 'Notification settings…'),
];

/// Rounded glass panel anchored to the long-pressed row, in the inbox
/// dock's language (overlay tint, hairline, rounded corners, inset row
/// highlights). It grows from the row with the popover motion and blurs
/// only once the popover has settled (DESIGN.md "Glass").
Future<T?> showChatActionsMenu<T extends Object>(
  BuildContext context, {
  required Rect anchor,
  required String title,
  required List<ChatMenuItem<T>> items,
  Widget? avatar,
  bool haptic = true,
}) {
  if (haptic) NotionHaptics.longPress();
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
  return showNotionPopover<T>(
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
      child: ChatActionsPanel<T>(title: title, avatar: avatar, items: items),
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

class ChatActionsPanel<T extends Object> extends StatelessWidget {
  final String title;
  final Widget? avatar;
  final List<ChatMenuItem<T>> items;
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
                for (final item in items) _ChatMenuRow<T>(item: item),
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

class _ChatMenuRow<T extends Object> extends StatelessWidget {
  final ChatMenuItem<T> item;
  const _ChatMenuRow({required this.item});

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final color = !item.enabled
        ? tokens.colors.textTertiary
        : item.destructive
        ? tokens.colors.danger
        : tokens.colors.text;
    return NotionPressable(
      enabled: item.enabled,
      scale: NotionMotion.pressRow,
      child: NotionGlassMenuRow(
        key: ValueKey('chat-menu-${item.keyName}'),
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
