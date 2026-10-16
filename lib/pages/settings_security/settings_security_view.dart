// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/personal/ui/notion_privacy_preferences.dart';
import 'package:fluffychat/personal/ui/notion_settings_body.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/beautify_string_extension.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/app_lock.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/settings_switch_list_tile.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'settings_security.dart';

class SettingsSecurityView extends StatelessWidget {
  final SettingsSecurityController controller;
  const SettingsSecurityView(this.controller, {super.key});
  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final publicMasterKey =
        client.userDeviceKeys[client.userID]?.masterKey?.publicKey;
    return NotionSettingsScaffold(
      title: 'Privacy & security',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NotionSettingsSection('Privacy on this device'),
          NotionPrivacyPreferences(
            incognito: AppSettings.personalIncognito.value,
            typing: AppSettings.sendTypingNotifications.value,
            receipts: AppSettings.sendPublicReadReceipts.value,
            pending: controller.privacyPending,
            error: controller.privacyError,
            onIncognito: controller.setPrivacy,
            onTyping: (value) => controller.setPrivacy(
              value,
              setting: AppSettings.sendTypingNotifications,
            ),
            onReceipts: (value) => controller.setPrivacy(
              value,
              setting: AppSettings.sendPublicReadReceipts,
            ),
          ),
          SettingsSwitchListTile.adaptive(
            title: L10n.of(context).shareCrashReports,
            subtitle: L10n.of(context).shareCrashReportsDescription,
            setting: AppSettings.autoSendErrorReports,
            defaultValue: false,
          ),
          NotionListRow(
            leading: const Icon(Icons.block_outlined),
            title: 'Blocked users',
            subtitle: '${client.ignoredUsers.length} blocked',
            onTap: () => context.push('/rooms/settings/security/ignorelist'),
          ),
          if (PlatformInfos.supportsAppLock) ...[
            const NotionSettingsSection('App lock'),
            NotionSettingsToggle(
              value: AppLock.of(context).isActive,
              title: L10n.of(context).useAppLock,
              subtitle: L10n.of(context).appLockDescription,
              onChanged: (active) => active
                  ? controller.setAppLockAction()
                  : controller.disableAppLockAction(),
            ),
            if (AppLock.of(context).isActive) ...[
              FutureBuilder<bool>(
                future: LocalAuthentication().canCheckBiometrics,
                builder: (context, snapshot) => snapshot.data != true
                    ? const SizedBox.shrink()
                    : NotionSettingsToggle(
                        value: AppLock.of(context).useBiometrics,
                        title: L10n.of(context).unlockWithBiometrics,
                        onChanged: (_) => controller.toggleBiometrics(),
                      ),
              ),
              NotionListRow(
                title: 'Change PIN',
                onTap: controller.setAppLockAction,
              ),
            ],
          ],
          const NotionSettingsSection('Encryption'),
          NotionListRow(
            leading: const Icon(Icons.devices_outlined),
            title: 'Devices & keys',
            subtitle: 'Review and verify your sessions',
            onTap: () => context.push('/rooms/settings/devices'),
          ),
          NotionListRow(
            leading: const Icon(Icons.backup_outlined),
            title: 'Encryption & recovery',
            subtitle: 'Review or set up encrypted key backup',
            onTap: () => context.push('/rooms/settings/recovery'),
          ),
          const NotionSettingsSection('Key sharing'),
          Text(L10n.of(context).shareKeysWithDescription),
          const SizedBox(height: 8),
          DropdownButtonFormField<ShareKeysWith>(
            key: ValueKey(client),
            initialValue: client.shareKeysWith,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Share keys with'),
            items: ShareKeysWith.values
                .map(
                  (share) => DropdownMenuItem(
                    value: share,
                    child: Text(share.localized(L10n.of(context))),
                  ),
                )
                .toList(),
            onChanged: controller.changeShareKeysWith,
          ),
          const NotionSettingsSection('Identity keys'),
          if (publicMasterKey != null)
            ListTile(
              title: Text(L10n.of(context).yourPublicKey),
              subtitle: SelectableText(publicMasterKey.beautified),
            ),
          ListTile(
            title: Text(L10n.of(context).deviceIdentityKey),
            subtitle: SelectableText(client.fingerprintKey.beautified),
          ),
        ],
      ),
    );
  }
}

extension on ShareKeysWith {
  String localized(L10n l10n) => switch (this) {
    ShareKeysWith.all => l10n.allDevices,
    ShareKeysWith.crossVerifiedIfEnabled => l10n.crossVerifiedDevicesIfEnabled,
    ShareKeysWith.crossVerified => l10n.crossVerifiedDevices,
    ShareKeysWith.directlyVerifiedOnly => l10n.verifiedDevicesOnly,
  };
}
