// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/bridged_room.dart';
import 'package:chatloom/personal/ui/contact_sheet.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/member_actions_popup_menu_button.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../widgets/avatar.dart';

/// One participant, Notion style (FX-05, UI-06): avatar, name, the network's
/// phone number or username for a bridged person (never the bridge's ghost
/// Matrix ID), role and membership as quiet tags. A tap on a bridged person
/// opens the contact sheet; a long press (or a tap in a native Matrix room)
/// opens the member actions.
class ParticipantListItem extends StatelessWidget {
  final User user;

  const ParticipantListItem(this.user, {super.key});

  /// The subtitle under the name: a network identifier in a bridged room,
  /// the Matrix ID in a native one.
  static String? subtitleFor(User user) {
    final room = user.room;
    if (!isBridgedRoom(room)) return user.id;
    return contactIdentifiers(room, user.id).firstOrNull?.value;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final l10n = L10n.of(context);
    final membership = switch (user.membership) {
      Membership.ban => l10n.banned,
      Membership.invite => l10n.invited,
      Membership.join => null,
      Membership.knock => l10n.knocking,
      Membership.leave => l10n.leftTheChat,
    };
    final role = switch (user.powerLevel.role) {
      PowerLevelRole.user => null,
      PowerLevelRole.moderator => l10n.moderator,
      PowerLevelRole.admin => l10n.admin,
      PowerLevelRole.owner => l10n.owner,
    };
    final bridged = isBridgedRoom(user.room);
    final subtitle = subtitleFor(user);
    final verified =
        user.room.client.userDeviceKeys[user.id]?.masterKey?.verified == true;
    void actions() => showMemberActionsPopupMenu(context: context, user: user);
    return NotionPressable(
      scale: NotionMotion.pressRow,
      child: InkWell(
        borderRadius: NotionRadius.rowAll,
        onTap: bridged && user.id != user.room.client.userID
            ? () => showContactSheet(context, room: user.room, userId: user.id)
            : actions,
        onLongPress: actions,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: NotionSize.rowMinHeight),
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: NotionSpace.xs,
              vertical: NotionSpace.xs,
            ),
            child: Row(
              children: [
                Opacity(
                  opacity: user.membership == Membership.join ? 1 : 0.5,
                  child: Avatar(
                    mxContent: user.avatarUrl,
                    name: user.calcDisplayname(),
                    size: NotionSize.avatar,
                    presenceUserId: bridged ? null : user.stateKey,
                  ),
                ),
                const SizedBox(width: NotionSpace.sm),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          if (verified) ...[
                            Icon(
                              Icons.verified,
                              color: tokens.colors.accent,
                              size: NotionSize.iconSm,
                            ),
                            const SizedBox(width: NotionSpace.xxs),
                          ],
                          Flexible(
                            child: Text(
                              user.calcDisplayname(),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: tokens.typography.body,
                            ),
                          ),
                        ],
                      ),
                      if (subtitle != null)
                        Text(
                          subtitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: tokens.typography.footnoteMuted,
                        ),
                    ],
                  ),
                ),
                if (role != null) ...[
                  const SizedBox(width: NotionSpace.xs),
                  _Tag(label: role),
                ],
                if (membership != null) ...[
                  const SizedBox(width: NotionSpace.xs),
                  _Tag(label: membership),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Tag extends StatelessWidget {
  final String label;
  const _Tag({required this.label});

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: tokens.colors.surface,
        borderRadius: NotionRadius.pillAll,
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: NotionSpace.xs,
          vertical: NotionSpace.xxs / 2,
        ),
        child: Text(label, style: tokens.typography.captionMuted),
      ),
    );
  }
}
