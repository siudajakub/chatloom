// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/report_policy.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/permission_slider_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'adaptive_dialogs/show_text_input_dialog.dart';
import 'adaptive_dialogs/user_dialog.dart';
import 'avatar.dart';
import 'future_loading_dialog.dart';

Future<void> showMemberActionsPopupMenu({
  required BuildContext context,
  required User user,
  void Function()? onMention,
}) async {
  final l10n = L10n.of(context);
  final scaffoldMessenger = ScaffoldMessenger.of(context);
  final displayname = user.calcDisplayname();
  final isMe = user.room.client.userID == user.id;
  // The bridge carries these to the network (BR-09): Telegram groups have
  // no kick, WhatsApp and Messenger DMs no member actions at all.
  final networkKicks = RoomCapabilities.memberActionAllowed(user.room, 'kick');
  final networkBans = RoomCapabilities.memberActionAllowed(user.room, 'ban');

  const defaultPowerLevels = {0, 50, 100, 9007199254740991};

  // ChatLoom: the glass Notion menu, anchored to the tapped avatar/row.
  final action = await showNotionMenu<_MemberActions>(
    context,
    semanticLabel: displayname,
    keyPrefix: 'member-menu',
    entries: [
      NotionMenuEntry(
        value: _MemberActions.info,
        label: displayname,
        leading: Avatar(
          name: displayname,
          size: NotionSize.iconMd,
          mxContent: user.avatarUrl,
        ),
      ),
      const NotionMenuEntry.divider(),
      if (onMention != null)
        NotionMenuEntry(
          value: _MemberActions.mention,
          label: l10n.mention,
          icon: Icons.alternate_email_outlined,
        ),
      if (user.membership == Membership.knock)
        NotionMenuEntry(
          value: _MemberActions.approve,
          label: l10n.approve,
          icon: Icons.how_to_reg_outlined,
        ),
      if (user.canChangeUserPowerLevel) ...[
        if (user.powerLevel.level < 100)
          NotionMenuEntry(
            value: _MemberActions.makeAdmin,
            label: l10n.makeAdmin,
            icon: Icons.admin_panel_settings_outlined,
          ),
        if (user.powerLevel.level < 50)
          NotionMenuEntry(
            value: _MemberActions.makeModerator,
            label: l10n.makeModerator,
            icon: Icons.add_moderator_outlined,
          ),
        if (user.powerLevel.role == PowerLevelRole.admin)
          NotionMenuEntry(
            value: _MemberActions.removeAdmin,
            label: l10n.removeAdminRights,
            icon: Icons.remove_moderator_outlined,
          )
        else if (user.powerLevel.role == PowerLevelRole.moderator)
          NotionMenuEntry(
            value: _MemberActions.removeModerator,
            label: l10n.removeModeratorRights,
            icon: Icons.remove_moderator_outlined,
          ),
      ],
      if (user.canChangeUserPowerLevel ||
          !defaultPowerLevels.contains(user.powerLevel.level))
        NotionMenuEntry(
          value: _MemberActions.setPowerLevel,
          enabled: user.canChangeUserPowerLevel,
          label: user.canChangeUserPowerLevel
              ? l10n.setPowerLevel
              : l10n.powerLevel,
          subtitle: defaultPowerLevels.contains(user.powerLevel.level)
              ? null
              : '${user.powerLevel}',
          icon: Icons.manage_accounts_outlined,
        ),
      if (user.canKick && networkKicks)
        NotionMenuEntry(
          value: _MemberActions.kick,
          label: l10n.kickFromChat,
          icon: Icons.person_remove_outlined,
          destructive: true,
        ),
      if (user.canBan && networkBans && user.membership != Membership.ban)
        NotionMenuEntry(
          value: _MemberActions.ban,
          label: l10n.banFromChat,
          icon: Icons.block_outlined,
          destructive: true,
        ),
      if (user.canBan && user.membership == Membership.ban)
        NotionMenuEntry(
          value: _MemberActions.unban,
          label: l10n.unbanFromChat,
          icon: Icons.warning_amber_outlined,
        ),
      // Native Matrix only: a bridged report reaches Beeper (CS-24).
      if (!isMe && canReportUser(user.room.client, user.id, room: user.room))
        NotionMenuEntry(
          value: _MemberActions.report,
          label: l10n.reportUser,
          icon: Icons.gavel_outlined,
          destructive: true,
        ),
    ],
  );
  if (action == null) return;
  if (!context.mounted) return;

  switch (action) {
    case _MemberActions.mention:
      onMention?.call();
      return;
    case _MemberActions.setPowerLevel:
      final power = await showPermissionChooser(
        context,
        currentLevel: user.powerLevel.level,
        maxLevel: user.room.ownPowerLevel.level,
      );
      if (power == null) return;
      if (!context.mounted) return;
      if (power >= 100) {
        final consent = await showOkCancelAlertDialog(
          context: context,
          title: L10n.of(context).areYouSure,
          message: L10n.of(context).makeAdminDescription,
        );
        if (consent != OkCancelResult.ok) return;
        if (!context.mounted) return;
      }
      await showFutureLoadingDialog(
        context: context,
        future: () => user.setPower(power),
      );
      return;
    case _MemberActions.approve:
      await showFutureLoadingDialog(
        context: context,
        future: () => user.room.invite(user.id),
      );
      return;
    case _MemberActions.kick:
      if (await showOkCancelAlertDialog(
            context: context,
            title: l10n.areYouSure,
            okLabel: l10n.yes,
            cancelLabel: l10n.no,
            message: l10n.kickUserDescription,
          ) ==
          OkCancelResult.ok) {
        if (!context.mounted) return;
        await showFutureLoadingDialog(
          context: context,
          future: () => user.kick(),
        );
      }
      return;
    case _MemberActions.ban:
      if (await showOkCancelAlertDialog(
            context: context,
            title: l10n.areYouSure,
            okLabel: l10n.yes,
            cancelLabel: l10n.no,
            message: l10n.banUserDescription,
          ) ==
          OkCancelResult.ok) {
        if (!context.mounted) return;
        await showFutureLoadingDialog(
          context: context,
          future: () => user.ban(),
        );
      }
      return;
    case _MemberActions.report:
      final reason = await showTextInputDialog(
        context: context,
        title: l10n.whyDoYouWantToReportThis,
        okLabel: l10n.report,
        cancelLabel: l10n.cancel,
        hintText: l10n.reason,
      );
      if (reason == null || reason.isEmpty) return;
      if (!context.mounted) return;

      final result = await showFutureLoadingDialog(
        context: context,
        future: () => user.room.client.reportUser(user.id, reason),
      );
      if (result.error != null) return;
      if (!context.mounted) return;
      scaffoldMessenger.showSnackBar(
        SnackBar(content: Text(l10n.contentHasBeenReported)),
      );
      return;
    case _MemberActions.info:
      await UserDialog.show(
        context: context,
        profile: Profile(
          userId: user.id,
          displayName: user.displayName,
          avatarUrl: user.avatarUrl,
        ),
      );
      return;
    case _MemberActions.unban:
      if (await showOkCancelAlertDialog(
            context: context,
            title: l10n.areYouSure,
            okLabel: l10n.yes,
            cancelLabel: l10n.no,
            message: l10n.unbanUserDescription,
          ) ==
          OkCancelResult.ok) {
        if (!context.mounted) return;
        await showFutureLoadingDialog(
          context: context,
          future: () => user.unban(),
        );
      }
    case _MemberActions.makeAdmin:
      if (user.room.ownPowerLevel.level <= 100) {
        final consent = await showOkCancelAlertDialog(
          context: context,
          title: L10n.of(context).areYouSure,
          message: L10n.of(context).makeAdminDescription,
        );
        if (consent != OkCancelResult.ok) return;
        if (!context.mounted) return;
      }
      await showFutureLoadingDialog(
        context: context,
        future: () => user.setPower(100),
      );
    case _MemberActions.makeModerator:
      await showFutureLoadingDialog(
        context: context,
        future: () => user.setPower(50),
      );
    case _MemberActions.removeAdmin:
    case _MemberActions.removeModerator:
      final defaultUserLevel =
          user.room
              .getState(EventTypes.RoomPowerLevels)
              ?.content
              .tryGet<int>('users_default') ??
          0;
      await showFutureLoadingDialog(
        context: context,
        future: () => user.setPower(defaultUserLevel),
      );
  }
}

enum _MemberActions {
  info,
  mention,
  setPowerLevel,
  makeAdmin,
  makeModerator,
  removeAdmin,
  removeModerator,
  kick,
  ban,
  approve,
  unban,
  report,
}
