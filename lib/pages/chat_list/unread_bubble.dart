// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/config/themes.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class UnreadBubble extends StatelessWidget {
  final Room room;
  final int? countOverride;
  final bool? unreadOverride;
  const UnreadBubble({
    required this.room,
    this.countOverride,
    this.unreadOverride,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final unread = unreadOverride ?? room.isUnread;
    final count = countOverride ?? room.notificationCount;
    final hasNotifications = count > 0;
    final unreadBubbleSize = unread || room.hasNewMessages
        ? count > 0
              ? 20.0
              : 14.0
        : 0.0;
    return AnimatedContainer(
      duration: FluffyThemes.animationDuration,
      curve: FluffyThemes.animationCurve,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(horizontal: 7),
      height: unreadBubbleSize,
      width: !hasNotifications && !unread && !room.hasNewMessages
          ? 0
          : (unreadBubbleSize - 9) * count.toString().length + 9,
      decoration: BoxDecoration(
        color: room.highlightCount > 0
            ? theme.colorScheme.error
            : hasNotifications || room.markedUnread
            ? theme.colorScheme.primary
            : theme.colorScheme.primaryContainer,
        borderRadius: BorderRadius.circular(unreadBubbleSize),
      ),
      child: hasNotifications || room.markedUnread
          ? NotionAnimatedCount(
              count: count,
              style: TextStyle(
                color: room.highlightCount > 0
                    ? theme.colorScheme.onError
                    : hasNotifications
                    ? theme.colorScheme.onPrimary
                    : theme.colorScheme.onPrimaryContainer,
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            )
          : const SizedBox.shrink(),
    );
  }
}
