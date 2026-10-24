// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/ui/notion_privacy_preferences.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/app_lock.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:go_router/go_router.dart';
import 'package:local_auth/local_auth.dart';
import 'package:material_ui/material_ui.dart';
import 'settings_security.dart';

class SettingsSecurityView extends StatelessWidget {
  final SettingsSecurityController controller;
  const SettingsSecurityView(this.controller, {super.key});
  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
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
          NotionListRow(
            // The Matrix ignore list, not a network block (FX-01): blocking
            // on WhatsApp/Telegram/Instagram lives on the contact.
            leading: const Icon(Icons.visibility_off_outlined),
            title: 'Ignored people',
            subtitle: client.ignoredUsers.isEmpty
                ? 'Hidden in ChatLoom and other Beeper apps. To block someone '
                      'on their network, open their contact.'
                : '${client.ignoredUsers.length} hidden in ChatLoom and other '
                      'Beeper apps · not blocked on their networks',
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
          // Key sharing and identity keys: Settings › Advanced › Developer.
        ],
      ),
    );
  }
}
