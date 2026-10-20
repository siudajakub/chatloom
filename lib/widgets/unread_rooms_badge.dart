// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:badges/badges.dart' as b;
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'matrix.dart';

class UnreadRoomsBadge extends StatelessWidget {
  final bool Function(Room) filter;
  final b.BadgePosition? badgePosition;
  final Widget? child;

  const UnreadRoomsBadge({
    super.key,
    required this.filter,
    this.badgePosition,
    this.child,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    final unreadCount = Matrix.of(context).client.rooms
        .where(filter)
        .where((r) => (r.isUnread || r.membership == Membership.invite))
        .length;
    return b.Badge(
      badgeStyle: b.BadgeStyle(
        badgeColor: theme.colorScheme.primary,
        elevation: 4,
        borderSide: BorderSide(color: theme.colorScheme.surface, width: 2),
      ),
      badgeContent: NotionAnimatedCount(
        count: unreadCount,
        style: TextStyle(color: theme.colorScheme.onPrimary, fontSize: 12),
      ),
      showBadge: unreadCount != 0,
      // Pops in on a spring; the count rolls instead of re-popping.
      badgeAnimation: b.BadgeAnimation.scale(
        toAnimate: !NotionMotion.reduced(context),
        animationDuration: NotionMotion.bouncyCurve.duration,
        curve: NotionMotion.bouncyCurve,
        disappearanceFadeAnimationDuration: NotionMotion.instant,
      ),
      position: badgePosition ?? b.BadgePosition.bottomEnd(),
      child: child,
    );
  }
}
