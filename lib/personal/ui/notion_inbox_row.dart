// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Diameter of the manual-unread dot.
const double _unreadDot = 10;

/// The actual inbox row presenter, also used by account-free visual captures.
class NotionInboxRow extends StatelessWidget {
  final Widget avatar;
  final String name;
  final String preview;
  final String? time;
  final int unreadCount;
  final bool unread;
  final bool selected;
  final bool muted;
  final String? notificationLabel;
  final bool draft;
  final bool redacted;
  final Widget? previewLeading;
  final Widget? action;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// A value that changes when this conversation receives something new
  /// (and usually moves to the top): the row flashes a soft highlight once.
  /// Null on first build and for own messages, so nothing flashes on scroll.
  final Object? highlight;
  const NotionInboxRow({
    super.key,
    required this.avatar,
    required this.name,
    required this.preview,
    required this.onTap,
    this.time,
    this.unreadCount = 0,
    this.unread = false,
    this.selected = false,
    this.muted = false,
    this.notificationLabel,
    this.draft = false,
    this.redacted = false,
    this.previewLeading,
    this.action,
    this.onLongPress,
    this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    final colors = context.notion.colors;
    final hasUnread = unreadCount > 0 || unread;
    // Unread: bold name, brighter preview, accent badge; muted chats keep a
    // grey badge so they do not compete with chats that notify.
    final badgeColor = muted ? colors.selected : colors.accent;
    final badgeText = muted ? colors.textSecondary : colors.onAccent;
    final announcement = [
      name,
      preview,
      ?time,
      if (unreadCount > 0)
        '$unreadCount unread messages'
      else if (unread)
        'Unread',
      if (muted) notificationLabel ?? 'Notifications limited',
    ];
    return Semantics(
      button: true,
      selected: selected,
      label: announcement.join(', '),
      onTap: onTap,
      onLongPress: onLongPress,
      child: NotionRowHighlight(
        trigger: highlight,
        borderRadius: NotionRadius.rowAll,
        child: NotionPressable(
          scale: NotionMotion.pressRow,
          child: AnimatedContainer(
            // The selected background follows the open conversation.
            duration: NotionMotion.of(context, NotionMotion.quick),
            curve: NotionMotion.standard,
            decoration: BoxDecoration(
              color: selected
                  ? Theme.of(context).colorScheme.surfaceContainerHighest
                  : Colors.transparent,
              borderRadius: NotionRadius.rowAll,
            ),
            child: Material(
              type: MaterialType.transparency,
              borderRadius: NotionRadius.rowAll,
              child: InkWell(
                onTap: onTap,
                onLongPress: onLongPress,
                onSecondaryTap: onLongPress,
                borderRadius: NotionRadius.rowAll,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 9),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ExcludeSemantics(
                        child: SizedBox.square(dimension: 40, child: avatar),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ExcludeSemantics(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  Expanded(
                                    child: Text(
                                      name,
                                      maxLines: large ? 2 : 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: NotionType.body.copyWith(
                                        height: 1.25,
                                        color: colors.text,
                                        fontWeight: hasUnread
                                            ? FontWeight.w700
                                            : FontWeight.w500,
                                      ),
                                    ),
                                  ),
                                  // Muting pops the bell in and out; the first
                                  // build shows it as is.
                                  NotionMorphSwitcher(
                                    rotate: false,
                                    child: muted
                                        ? Padding(
                                            key: const ValueKey('muted'),
                                            padding:
                                                const EdgeInsetsDirectional.only(
                                                  start: NotionSpace.xxs,
                                                ),
                                            child: Icon(
                                              Icons.notifications_off_outlined,
                                              size:
                                                  NotionType.footnote.fontSize,
                                              color: secondary,
                                            ),
                                          )
                                        : const SizedBox.shrink(
                                            key: ValueKey('not-muted'),
                                          ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 3),
                              Row(
                                children: [
                                  if (previewLeading != null) ...[
                                    previewLeading!,
                                    const SizedBox(width: 4),
                                  ],
                                  Expanded(
                                    child: _InboxCrossFade(
                                      child: Text(
                                        preview,
                                        key: ValueKey(preview),
                                        maxLines: large ? 2 : 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: NotionType.footnote.copyWith(
                                          height: 1.3,
                                          color: hasUnread && !muted && !draft
                                              ? colors.text
                                              : secondary,
                                          fontStyle: draft
                                              ? FontStyle.italic
                                              : null,
                                          decoration: redacted
                                              ? TextDecoration.lineThrough
                                              : null,
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(width: 10),
                      ExcludeSemantics(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            if (time != null)
                              _InboxCrossFade(
                                alignment: AlignmentDirectional.topEnd,
                                child: Text(
                                  time!,
                                  key: ValueKey(time),
                                  style: NotionType.footnote.copyWith(
                                    color: hasUnread && !muted
                                        ? colors.text
                                        : secondary,
                                  ),
                                ),
                              ),
                            // The badge pops in when the first unread arrives,
                            // pulses and rolls its number on every new one, and
                            // shrinks away once read. Rows built by scrolling
                            // show it as is (a switcher never animates its first
                            // child).
                            NotionMorphSwitcher(
                              bounce: true,
                              rotate: false,
                              child: unreadCount > 0
                                  ? Padding(
                                      key: const ValueKey('count'),
                                      padding: const EdgeInsets.only(
                                        top: NotionSpace.xxs,
                                      ),
                                      child: NotionPop(
                                        trigger: unreadCount,
                                        playOnMount: false,
                                        child: Container(
                                          constraints: const BoxConstraints(
                                            minWidth: 20,
                                            minHeight: 20,
                                          ),
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: badgeColor,
                                            borderRadius: NotionRadius.pillAll,
                                          ),
                                          alignment: Alignment.center,
                                          child: NotionAnimatedCount(
                                            count: unreadCount,
                                            style: NotionType.caption.copyWith(
                                              color: badgeText,
                                              fontWeight: FontWeight.w600,
                                            ),
                                          ),
                                        ),
                                      ),
                                    )
                                  : unread
                                  // Marked unread by hand: a plain dot, no count.
                                  ? Padding(
                                      key: const ValueKey('dot'),
                                      padding: const EdgeInsets.only(
                                        top: NotionSpace.xs,
                                      ),
                                      child: Container(
                                        key: const ValueKey(
                                          'notion_inbox_unread_dot',
                                        ),
                                        width: _unreadDot,
                                        height: _unreadDot,
                                        decoration: BoxDecoration(
                                          color: badgeColor,
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                    )
                                  : const SizedBox.shrink(
                                      key: ValueKey('read'),
                                    ),
                            ),
                          ],
                        ),
                      ),
                      ?action,
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Short cross-fade for one line of row text (preview, time) when it
/// changes; the first build and reduced motion show it directly.
class _InboxCrossFade extends StatelessWidget {
  const _InboxCrossFade({
    required this.child,
    this.alignment = AlignmentDirectional.topStart,
  });

  final Widget child;
  final AlignmentGeometry alignment;

  @override
  Widget build(BuildContext context) => AnimatedSwitcher(
    duration: NotionMotion.of(context, NotionMotion.short),
    reverseDuration: NotionMotion.of(context, NotionMotion.quick),
    switchInCurve: NotionMotion.standard,
    switchOutCurve: NotionMotion.exitFast,
    layoutBuilder: (current, previous) =>
        Stack(alignment: alignment, children: [...previous, ?current]),
    child: child,
  );
}
