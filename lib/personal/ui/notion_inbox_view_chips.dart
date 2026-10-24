// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:personal_core/personal_core.dart';

/// The one-tap views above the inbox list (UX-16; Messenger's "All · Unread
/// · Groups" chips, Telegram's folder tabs).
const notionInboxChipViews = [
  InboxFilter.inbox,
  InboxFilter.unread,
  InboxFilter.groups,
];

String notionInboxChipLabel(InboxFilter view) =>
    view == InboxFilter.inbox ? 'All' : inboxViewLabel(view);

/// A row of in-content pills (opaque, never glass: they scroll with the
/// list). They select the same view as the dock's "Show chats" menu, through
/// [onViewSelected]; the page keeps no view state of its own. A view chosen
/// elsewhere (Ignored, Archive, …) shows as one more selected chip so the
/// list stays labelled.
class NotionInboxViewChips extends StatelessWidget {
  const NotionInboxViewChips({
    super.key,
    required this.selected,
    required this.onViewSelected,
    this.unreadCount = 0,
    this.requestCount = 0,
  });

  final InboxFilter selected;
  final ValueChanged<InboxFilter>? onViewSelected;

  /// Unread chats of the current network selection; shown on "Unread".
  final int unreadCount;

  /// Message requests waiting for an answer (Instagram, Messenger): the
  /// "Requests" chip appears only while there are some (FX-02).
  final int requestCount;

  @override
  Widget build(BuildContext context) {
    final palette = context.notion.palette;
    final chips = [
      ...notionInboxChipViews,
      if (requestCount > 0) InboxFilter.requests,
    ];
    final views = [...chips, if (!chips.contains(selected)) selected];
    return Semantics(
      container: true,
      label: 'Views',
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (index, view) in views.indexed) ...[
              if (index > 0) const SizedBox(width: NotionSpace.xs),
              NotionGlassPill(
                key: ValueKey('notion_inbox_chip_${view.name}'),
                label: notionInboxChipLabel(view),
                selected: view == selected,
                trailing: view == InboxFilter.requests && requestCount > 0
                    ? Text(
                        '$requestCount',
                        semanticsLabel: '$requestCount waiting',
                        style: context.notion.typography.captionMuted,
                      )
                    : view == InboxFilter.unread && unreadCount > 0
                    ? Container(
                        constraints: const BoxConstraints(
                          minWidth: 20,
                          minHeight: 20,
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: NotionSpace.xxs,
                        ),
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: palette.accentFill,
                          borderRadius: NotionRadius.pillAll,
                        ),
                        child: Text(
                          unreadCount > 99 ? '99+' : '$unreadCount',
                          semanticsLabel: '$unreadCount unread',
                          style: NotionType.caption.copyWith(
                            color: palette.onAccentFill,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    : null,
                onPressed: onViewSelected == null
                    ? null
                    : () {
                        if (view != selected) onViewSelected!(view);
                      },
              ),
            ],
          ],
        ),
      ),
    );
  }
}
