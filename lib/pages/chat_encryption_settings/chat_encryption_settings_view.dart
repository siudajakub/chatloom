// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat_encryption_settings/chat_encryption_settings.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/beautify_string_extension.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class ChatEncryptionSettingsView extends StatelessWidget {
  final ChatEncryptionSettingsController controller;

  const ChatEncryptionSettingsView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final room = controller.room;
    return StreamBuilder<Object>(
      stream: room.client.onSync.stream.where(
        (s) => s.rooms?.join?[room.id] != null || s.deviceLists != null,
      ),
      builder: (context, _) => NotionScaffold(
        title: l10n.encryption,
        onBack: () => context.go('/rooms/${controller.roomId!}'),
        backLabel: l10n.close,
        children: [
          NotionSettingsBody.staggered(
            Column(
              mainAxisSize: .min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                NotionSettingsToggle(
                  title: l10n.encryptThisChat,
                  value: room.encrypted,
                  onChanged: controller.enableEncryption,
                ),
                if (room.isDirectChat && room.encrypted) ...[
                  NotionSectionHeader(title: l10n.interactiveVerification),
                  Text(
                    l10n.interactiveVerificationDescription,
                    style: context.notion.typography.footnoteMuted,
                  ),
                  const SizedBox(height: NotionSpace.sm),
                  NotionButton(
                    expand: true,
                    icon: Icons.verified_outlined,
                    label: l10n.verifyStart,
                    onPressed: controller.startVerification,
                  ),
                ],
                if (room.encrypted) ...[
                  const NotionSectionHeader(title: 'Participants'),
                  SelectionArea(
                    child: FutureBuilder(
                      future: room.requestParticipants(),
                      builder: (context, snapshot) {
                        final users = snapshot.data;
                        if (users == null) {
                          return NotionSkeleton(
                            child: Column(
                              children: [
                                for (var i = 0; i < 3; i++)
                                  const NotionSkeletonRow(),
                              ],
                            ),
                          );
                        }
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            for (final user in users)
                              _ParticipantKeys(
                                controller: controller,
                                user: user,
                              ),
                          ],
                        );
                      },
                    ),
                  ),
                ] else
                  NotionEmptyState(
                    icon: Icons.lock_open_outlined,
                    title: l10n.encryptionNotEnabled,
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// One participant's key state; expands to their devices. Status colours
/// tint only the icon (DESIGN.md "status only, never decoration").
class _ParticipantKeys extends StatelessWidget {
  final ChatEncryptionSettingsController controller;
  final User user;
  const _ParticipantKeys({required this.controller, required this.user});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final colors = context.notion.colors;
    final userDeviceKeys = controller.room.client.userDeviceKeys[user.id];
    final masterKey = userDeviceKeys?.masterKey;
    final tofuSince = masterKey?.trustOnFirstUseSince;
    final expanded = controller.uncollapsedUserId == user.id;
    final (icon, tone, status) = masterKey == null
        ? (Icons.key_off_outlined, colors.warning, l10n.noUserKeyFound)
        : masterKey.verified == true
        ? (Icons.verified_user_outlined, colors.success, l10n.verified)
        : tofuSince != null
        ? (
            Icons.shield_outlined,
            colors.textSecondary,
            l10n.knownSince(tofuSince.localizedTime(context)),
          )
        : (Icons.gpp_maybe_outlined, colors.warning, l10n.unverified);
    final devices = userDeviceKeys?.deviceKeys.length ?? 0;
    return Column(
      mainAxisSize: .min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        NotionListRow(
          leading: Icon(icon, color: tone, size: NotionSize.iconMd),
          title: user.calcDisplayname(),
          subtitle:
              '$status · ${devices == 1 ? '1 device' : '$devices devices'}',
          trailing: Icon(
            expanded
                ? Icons.keyboard_arrow_up_outlined
                : Icons.keyboard_arrow_down_outlined,
            size: NotionSize.iconMd,
          ),
          onTap: () => controller.uncollapse(user.id),
        ),
        if (expanded && userDeviceKeys != null)
          Padding(
            padding: const EdgeInsetsDirectional.only(start: NotionSpace.xl),
            child: Column(
              mainAxisSize: .min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final device in userDeviceKeys.deviceKeys.values)
                  _DeviceKeyRow(controller: controller, device: device),
              ],
            ),
          ),
      ],
    );
  }
}

class _DeviceKeyRow extends StatelessWidget {
  final ChatEncryptionSettingsController controller;
  final DeviceKeys device;
  const _DeviceKeyRow({required this.controller, required this.device});

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    final colors = context.notion.colors;
    final signedDevice = device.hasValidSignatureChain(
      verifiedOnly: false,
      verifiedByTheirMasterKey: true,
    );
    final (icon, tone, status) = device.verified
        ? (Icons.verified_outlined, colors.success, l10n.verified)
        : device.blocked
        ? (Icons.block_outlined, colors.danger, l10n.blocked)
        : !signedDevice
        ? (Icons.gpp_maybe_outlined, colors.warning, l10n.unsignedDevice)
        : (Icons.devices_outlined, colors.textSecondary, l10n.signedDevice);
    return NotionListRow(
      leading: Icon(icon, color: tone, size: NotionSize.icon),
      title: status,
      subtitle: device.curve25519Key?.beautified ?? l10n.noCurve25519KeyFound,
      trailing: NotionIconButton(
        icon: Icons.block_outlined,
        selected: device.blocked,
        label: device.blocked ? l10n.unblockDevice : l10n.blockDevice,
        onPressed: () => controller.toggleBlocked(device),
      ),
    );
  }
}
