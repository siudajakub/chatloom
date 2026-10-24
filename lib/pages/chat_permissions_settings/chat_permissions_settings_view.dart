// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat_permissions_settings/chat_permissions_settings.dart';
import 'package:chatloom/pages/chat_permissions_settings/permission_list_tile.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class ChatPermissionsSettingsView extends StatelessWidget {
  final ChatPermissionsSettingsController controller;

  const ChatPermissionsSettingsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    return StreamBuilder(
      stream: controller.onChanged,
      builder: (context, _) {
        final roomId = controller.roomId;
        final room = roomId == null
            ? null
            : Matrix.of(context).client.getRoomById(roomId);
        if (room == null) {
          return NotionScaffold(
            title: l10n.chatPermissions,
            onBack: () => Navigator.of(context).maybePop(),
            body: NotionEmptyState(
              icon: Icons.forum_outlined,
              title: l10n.noRoomsFound,
            ),
          );
        }
        final powerLevelsContent = Map<String, Object?>.from(
          room.getState(EventTypes.RoomPowerLevels)?.content ?? {},
        );
        final powerLevels = Map<String, dynamic>.from(powerLevelsContent)
          ..removeWhere((k, v) => v is! int);
        final eventsPowerLevels = Map<String, int?>.from(
          powerLevelsContent.tryGetMap<String, int?>('events') ?? {},
        )..removeWhere((k, v) => v is! int);
        const notificationsKey = 'rooms';
        final notificationsLevel =
            powerLevelsContent
                .tryGetMap<String, Object?>('notifications')
                ?.tryGet<int>(notificationsKey) ??
            0;
        return NotionScaffold(
          title: l10n.chatPermissions,
          onBack: () => Navigator.of(context).maybePop(),
          children: [
            // Rows rise in once after the push (first screenful only).
            NotionSettingsBody.staggered(
              Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: NotionSpace.xs),
                    child: Text(
                      l10n.chatPermissionsDescription,
                      style: context.notion.typography.footnoteMuted,
                    ),
                  ),
                  NotionSectionHeader(title: l10n.chatPermissions),
                  for (final entry in powerLevels.entries)
                    PermissionsListTile(
                      permissionKey: entry.key,
                      permission: entry.value,
                      onChanged: (level) => controller.editPowerLevel(
                        context,
                        entry.key,
                        entry.value,
                        newLevel: level,
                      ),
                      canEdit: room.canChangePowerLevel,
                    ),
                  NotionSectionHeader(title: l10n.notifications),
                  PermissionsListTile(
                    permissionKey: notificationsKey,
                    permission: notificationsLevel,
                    category: 'notifications',
                    canEdit: room.canChangePowerLevel,
                    onChanged: (level) => controller.editPowerLevel(
                      context,
                      notificationsKey,
                      notificationsLevel,
                      newLevel: level,
                      category: 'notifications',
                    ),
                  ),
                  NotionSectionHeader(title: l10n.configureChat),
                  for (final entry in eventsPowerLevels.entries)
                    PermissionsListTile(
                      permissionKey: entry.key,
                      category: 'events',
                      permission: entry.value ?? 0,
                      canEdit: room.canChangePowerLevel,
                      onChanged: (level) => controller.editPowerLevel(
                        context,
                        entry.key,
                        entry.value ?? 0,
                        newLevel: level,
                        category: 'events',
                      ),
                    ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
