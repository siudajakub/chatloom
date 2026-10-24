// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../utils/date_time_extension.dart';
import '../../utils/matrix_sdk_extensions/device_extension.dart';
import '../../widgets/matrix.dart';

enum UserDeviceListItemAction { rename, remove, verify, block, unblock }

class UserDeviceListItem extends StatelessWidget {
  final Device userDevice;
  final void Function(Device) remove;
  final void Function(Device) rename;
  final void Function(Device) verify;
  final void Function(Device) block;
  final void Function(Device) unblock;

  /// The ChatLoom worker's session: labelled, so it is not mistaken for an
  /// old device and signed out.
  final bool isWorker;

  const UserDeviceListItem(
    this.userDevice, {
    this.isWorker = false,
    required this.remove,
    required this.rename,
    required this.verify,
    required this.block,
    required this.unblock,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final keys = client
        .userDeviceKeys[Matrix.of(context).client.userID]
        ?.deviceKeys[userDevice.deviceId];
    final isOwnDevice = userDevice.deviceId == client.deviceID;

    final colors = context.notion.colors;
    final status = keys == null
        ? null
        : keys.blocked
        ? (L10n.of(context).blocked, NotionStatusTone.danger)
        : keys.verified
        ? (L10n.of(context).verified, NotionStatusTone.success)
        : (L10n.of(context).unverified, NotionStatusTone.warning);
    // A neutral device glyph and a status pill, not FluffyChat's red, green
    // and orange avatars and labels.
    return NotionListRow(
      leading: Icon(
        userDevice.icon,
        size: NotionSize.iconLg,
        color: colors.textSecondary,
      ),
      title: userDevice.displayname,
      subtitle: [
        if (isWorker) 'ChatLoom worker · transcription and reminders',
        L10n.of(context).lastActiveAgo(
          DateTime.fromMillisecondsSinceEpoch(
            userDevice.lastSeenTs ?? 0,
          ).localizedTimeShort(context),
        ),
      ].join('\n'),
      trailing: status == null
          ? const SizedBox.shrink()
          : NotionStatusPill(label: status.$1, tone: status.$2),
      onTap: () async {
        final action = await showModalActionPopup<UserDeviceListItemAction>(
          context: context,
          title: '${userDevice.displayName} (${userDevice.deviceId})',
          cancelLabel: L10n.of(context).cancel,
          actions: [
            AdaptiveModalAction(
              value: UserDeviceListItemAction.rename,
              icon: const Icon(Icons.edit_outlined),
              label: L10n.of(context).changeDeviceName,
            ),
            if (!isOwnDevice && keys != null) ...{
              AdaptiveModalAction(
                value: UserDeviceListItemAction.verify,
                icon: const Icon(Icons.verified_outlined),
                label: L10n.of(context).verifyStart,
              ),
              if (!keys.blocked)
                AdaptiveModalAction(
                  value: UserDeviceListItemAction.block,
                  icon: const Icon(Icons.block_outlined),
                  label: L10n.of(context).blockDevice,
                  isDestructive: true,
                ),
              if (keys.blocked)
                AdaptiveModalAction(
                  value: UserDeviceListItemAction.unblock,
                  icon: const Icon(Icons.block),
                  label: L10n.of(context).unblockDevice,
                  isDestructive: true,
                ),
            },
            if (!isOwnDevice)
              AdaptiveModalAction(
                value: UserDeviceListItemAction.remove,
                icon: const Icon(Icons.logout_outlined),
                label: 'Sign out',
                isDestructive: true,
              ),
          ],
        );
        if (action == null) return;
        switch (action) {
          case UserDeviceListItemAction.rename:
            rename(userDevice);
            break;
          case UserDeviceListItemAction.remove:
            remove(userDevice);
            break;
          case UserDeviceListItemAction.verify:
            verify(userDevice);
            break;
          case UserDeviceListItemAction.block:
            block(userDevice);
            break;
          case UserDeviceListItemAction.unblock:
            unblock(userDevice);
            break;
        }
      },
    );
  }
}
