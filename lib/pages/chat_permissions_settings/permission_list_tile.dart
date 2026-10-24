// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class PermissionsListTile extends StatelessWidget {
  final String permissionKey;
  final int permission;
  final String? category;
  final void Function(int? level)? onChanged;
  final bool canEdit;

  const PermissionsListTile({
    super.key,
    required this.permissionKey,
    required this.permission,
    this.category,
    required this.onChanged,
    required this.canEdit,
  });

  String getLocalizedPowerLevelString(BuildContext context) {
    if (category == null) {
      switch (permissionKey) {
        case 'users_default':
          return L10n.of(context).defaultPermissionLevel;
        case 'events_default':
          return L10n.of(context).sendMessages;
        case 'state_default':
          return L10n.of(context).changeGeneralChatSettings;
        case 'ban':
          return L10n.of(context).banFromChat;
        case 'kick':
          return L10n.of(context).kickFromChat;
        case 'redact':
          return L10n.of(context).deleteMessage;
        case 'invite':
          return L10n.of(context).inviteOtherUsers;
      }
    } else if (category == 'notifications') {
      switch (permissionKey) {
        case 'rooms':
          return L10n.of(context).sendRoomNotifications;
      }
    } else if (category == 'events') {
      switch (permissionKey) {
        case EventTypes.RoomName:
          return L10n.of(context).changeTheNameOfTheGroup;
        case EventTypes.RoomTopic:
          return L10n.of(context).changeTheDescriptionOfTheGroup;
        case EventTypes.RoomPowerLevels:
          return L10n.of(context).changeTheChatPermissions;
        case EventTypes.HistoryVisibility:
          return L10n.of(context).changeTheVisibilityOfChatHistory;
        case EventTypes.RoomCanonicalAlias:
          return L10n.of(context).changeTheCanonicalRoomAlias;
        case EventTypes.RoomAvatar:
          return L10n.of(context).editRoomAvatar;
        case EventTypes.RoomTombstone:
          return L10n.of(context).replaceRoomWithNewerVersion;
        case EventTypes.Encryption:
          return L10n.of(context).enableEncryption;
        case 'm.room.server_acl':
          return L10n.of(context).editBlockedServers;
        // Group calls are not supported; an existing level stays readable.
        case 'org.matrix.msc3401.call.member':
          return 'Create or join a group call';
      }
    }
    return permissionKey;
  }

  /// The three standard levels around [permission]: a custom value stays
  /// in its band, so "Moderator (60)" is shown and kept as such.
  List<(int, String)> _levels(L10n l10n) {
    final user = permission < 50 ? permission : 0;
    final moderator = permission < 100 && permission >= 50 ? permission : 50;
    final admin = permission >= 100 ? permission : 100;
    return [
      (user, l10n.userLevel(user)),
      (moderator, l10n.moderatorLevel(moderator)),
      (admin, l10n.adminLevel(admin)),
    ];
  }

  Future<void> _choose(BuildContext context) async {
    final l10n = L10n.of(context);
    final levels = _levels(l10n);
    // A record so "Custom" (null level) differs from a dismissed sheet.
    final choice = await showNotionSheet<({int? level})>(
      context: context,
      title: getLocalizedPowerLevelString(context),
      builder: (context) => SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final (level, label) in levels)
              NotionChoiceRow(
                title: label,
                selected: level == permission,
                onTap: () => Navigator.of(context).pop((level: level)),
              ),
            NotionChoiceRow(
              title: l10n.custom,
              selected: false,
              onTap: () => Navigator.of(context).pop((level: null)),
            ),
          ],
        ),
      ),
    );
    if (choice == null || choice.level == permission) return;
    onChanged?.call(choice.level);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final current = _levels(
      l10n,
    ).firstWhere((entry) => entry.$1 == permission).$2;
    return NotionListRow(
      title: getLocalizedPowerLevelString(context),
      subtitle: current,
      onTap: canEdit && onChanged != null ? () => _choose(context) : null,
    );
  }
}
