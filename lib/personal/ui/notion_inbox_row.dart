// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

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
  });

  @override
  Widget build(BuildContext context) {
    final large = MediaQuery.textScalerOf(context).scale(16) > 22;
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    final announcement = [
      name,
      preview,
      if (time != null) time!,
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
      child: Material(
        color: selected
            ? Theme.of(context).colorScheme.surfaceContainerHighest
            : Colors.transparent,
        borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          onSecondaryTap: onLongPress,
          borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
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
                                style: const TextStyle(
                                  fontSize: 16,
                                  height: 1.25,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            if (muted)
                              Padding(
                                padding: const EdgeInsets.only(left: 4),
                                child: Icon(
                                  Icons.notifications_off_outlined,
                                  size: 13,
                                  color: secondary,
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
                              child: Text(
                                preview,
                                maxLines: large ? 2 : 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 14,
                                  height: 1.3,
                                  color: secondary,
                                  fontStyle: draft ? FontStyle.italic : null,
                                  decoration: redacted
                                      ? TextDecoration.lineThrough
                                      : null,
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
                        Text(
                          time!,
                          style: TextStyle(
                            fontSize: 13,
                            height: 1.4,
                            color: secondary,
                          ),
                        ),
                      if (unreadCount > 0 || unread) ...[
                        const SizedBox(height: 4),
                        Container(
                          constraints: const BoxConstraints(
                            minWidth: 20,
                            minHeight: 20,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(20),
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            unreadCount > 0 ? '$unreadCount' : '•',
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                ?action,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
