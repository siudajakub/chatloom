// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/developer_options.dart';
import 'package:chatloom/personal/personal_hub.dart' show personalText;
import 'package:chatloom/personal/push_registration.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/personal/ui/notion_settings_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/background_push.dart';
import 'package:chatloom/utils/beautify_string_extension.dart';
import 'package:chatloom/utils/personal_secure_storage.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/settings_switch_list_tile.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Label of a key-sharing policy, in the words of the policy itself.
String shareKeysWithLabel(ShareKeysWith value, L10n l10n) => switch (value) {
  ShareKeysWith.all => l10n.allDevices,
  ShareKeysWith.crossVerifiedIfEnabled => l10n.crossVerifiedDevicesIfEnabled,
  ShareKeysWith.crossVerified => l10n.crossVerifiedDevices,
  ShareKeysWith.directlyVerifiedOnly => l10n.verifiedDevicesOnly,
};

/// Settings › Advanced › Developer. Everything here was moved, not removed,
/// out of the everyday settings (wave 5, CS-02): logs and the configuration
/// editor, manual push gateway setup with its secrets, registration
/// details, the account's server notification rules, the key sharing policy
/// and identity keys, and technical message display options. Reachable only
/// while [DeveloperOptions] is on.
class DeveloperSettingsPage extends StatefulWidget {
  const DeveloperSettingsPage({super.key});

  @override
  State<DeveloperSettingsPage> createState() => _DeveloperSettingsPageState();
}

class _DeveloperSettingsPageState extends State<DeveloperSettingsPage> {
  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _guard(Future<void> Function() action) async {
    try {
      await action();
    } catch (_) {
      _snack('Couldn’t save this change. Try again.');
    }
  }

  Future<void> _configurePush() async {
    final account = Matrix.of(context).client;
    final owner = account.userID, device = account.deviceID;
    bool current() =>
        mounted &&
        identical(Matrix.of(context).client, account) &&
        account.userID == owner &&
        account.deviceID == device &&
        account.isLogged();
    final url = await personalText(
      context,
      'Notification gateway HTTPS address',
      initial: AppSettings.pushNotificationsGatewayUrl.value,
    );
    if (url == null || !mounted || !current()) return;
    final uri = Uri.tryParse(url.trim());
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.query.isNotEmpty ||
        uri.fragment.isNotEmpty) {
      _snack(
        'Enter a full HTTPS address without credentials, query parameters or a fragment.',
      );
      return;
    }
    final nonceController = TextEditingController();
    final form = GlobalKey<FormState>();
    String? nonce;
    try {
      nonce = await showNotionDialog<String>(
        context: context,
        title: 'Private device key',
        message:
            'Paste the random key also saved in your gateway configuration. Use 43–128 base64url characters and keep it private.',
        content: Form(
          key: form,
          child: TextFormField(
            controller: nonceController,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: 'Device key'),
            validator: (value) => validGatewayNonce(value)
                ? null
                : 'Use 43–128 random letters, digits, underscores or hyphens.',
          ),
        ),
        actions: (context) => [
          NotionButton.ghost(
            label: 'Cancel',
            onPressed: () => Navigator.pop(context),
          ),
          NotionButton(
            label: 'Save & register',
            onPressed: () {
              if (form.currentState?.validate() == true) {
                Navigator.pop(context, nonceController.text);
              }
            },
          ),
        ],
      );
    } finally {
      nonceController.dispose();
    }
    if (nonce == null || !mounted || !current()) return;
    final push = BackgroundPush(Matrix.of(context));
    push.beginRegistrationUpdate();
    try {
      await personalSecureStorage.write(
        key: 'personal_gateway_nonce',
        value: nonce,
      );
      if (!current()) return;
      await AppSettings.pushNotificationsGatewayUrl.setItem(uri.toString());
    } finally {
      push.endRegistrationUpdate();
    }
    if (!mounted || !current()) return;
    await push.setupPush(context);
    if (mounted && current()) {
      _snack(
        'Settings saved. Notifications require the same device key in the gateway configuration.',
      );
    }
  }

  Future<void> _copyPushRegistration() async {
    final account = Matrix.of(context).client;
    final owner = account.userID;
    final push = BackgroundPush(Matrix.of(context));
    final token = push.fcmToken;
    final revision = push.registrationRevision;
    final device = account.deviceID;
    final nonce = await personalSecureStorage.read(
      key: 'personal_gateway_nonce',
    );
    if (!mounted ||
        !identical(Matrix.of(context).client, account) ||
        account.userID != owner ||
        account.deviceID != device ||
        !account.isLogged() ||
        push.fcmToken != token ||
        push.registrationRevision != revision) {
      return;
    }
    if (token == null ||
        token.isEmpty ||
        device == null ||
        device.isEmpty ||
        nonce == null ||
        !validGatewayNonce(nonce)) {
      _snack(
        'Save the configuration and register notifications first. A token or valid device key is missing.',
      );
      return;
    }
    var appId = '${AppConfig.pushNotificationsAppId}.$device';
    if (appId.length > 64) appId = appId.substring(0, 64);
    await Clipboard.setData(
      ClipboardData(
        text: jsonEncode({'app_id': appId, 'pushkey': token, 'nonce': nonce}),
      ),
    );
    _snack(
      'Registration secrets copied. Paste them only into your private gateway configuration.',
    );
  }

  Future<void> _chooseShareKeys(Client client) async {
    final l10n = L10n.of(context);
    final choice = await showNotionSheet<ShareKeysWith>(
      context: context,
      title: 'Share keys with',
      builder: (context) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.shareKeysWithDescription),
          const SizedBox(height: NotionSpace.xs),
          for (final value in ShareKeysWith.values)
            NotionListRow(
              title: shareKeysWithLabel(value, l10n),
              trailing: value == client.shareKeysWith
                  ? const Icon(Icons.check)
                  : const SizedBox.shrink(),
              onTap: () => Navigator.pop(context, value),
            ),
        ],
      ),
    );
    if (choice == null || !mounted) return;
    if (!identical(Matrix.of(context).client, client)) return;
    await _guard(() async {
      await AppSettings.shareKeysWith.setItem(choice.name);
      client.shareKeysWith = choice;
    });
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    final l10n = L10n.of(context);
    final publicMasterKey =
        client.userDeviceKeys[client.userID]?.masterKey?.publicKey;
    return NotionSettingsScaffold(
      title: 'Developer',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Technical tools for troubleshooting. Message menus also show '
            'Message info with the message source while developer options '
            'are on.',
            style: context.notion.typography.footnoteMuted,
          ),
          const NotionSettingsSection('Diagnostics'),
          NotionListRow(
            leading: const Icon(Icons.list_outlined),
            title: 'Logs',
            subtitle: 'Recent app log on this device',
            onTap: () => context.push('/logs'),
          ),
          NotionListRow(
            leading: const Icon(Icons.settings_applications_outlined),
            title: 'App configuration',
            subtitle: 'Every stored app setting',
            onTap: () => context.push('/configs'),
          ),
          const NotionSettingsSection('Messages'),
          SettingsSwitchListTile.adaptive(
            title: 'Formatted messages',
            subtitle: 'Show bold, italics, lists and links',
            setting: AppSettings.renderHtml,
          ),
          SettingsSwitchListTile.adaptive(
            title: 'Hide unknown message types',
            subtitle: 'Technical events the app can’t display',
            setting: AppSettings.hideUnknownEvents,
          ),
          if (PlatformInfos.supportsSystemNotifications) ...[
            const NotionSettingsSection('Notifications'),
            NotionListRow(
              leading: const Icon(Icons.dns_outlined),
              title: 'Configure a gateway manually',
              subtitle: 'For a private push gateway',
              onTap: kIsWeb ? null : () => _guard(_configurePush),
            ),
            NotionListRow(
              leading: const Icon(Icons.copy_outlined),
              title: 'Copy push registration (secrets)',
              subtitle: 'Only for manual gateway configuration',
              onTap: kIsWeb ? null : () => _guard(_copyPushRegistration),
            ),
            NotionListRow(
              leading: const Icon(Icons.phonelink_setup_outlined),
              title: 'Registration details',
              subtitle: 'Registered devices and push providers',
              onTap: () =>
                  context.push('/rooms/settings/notifications/registration'),
            ),
            NotionListRow(
              leading: const Icon(Icons.rule_outlined),
              title: 'Server notification rules',
              subtitle: 'Account rules shared by all your apps',
              onTap: () => context.push('/rooms/settings/notifications/rules'),
            ),
          ],
          const NotionSettingsSection('Encryption'),
          NotionListRow(
            key: ValueKey(client),
            leading: const Icon(Icons.key_outlined),
            title: 'Share keys with',
            subtitle: shareKeysWithLabel(client.shareKeysWith, l10n),
            onTap: () => _chooseShareKeys(client),
          ),
          if (publicMasterKey != null)
            NotionListRow(
              title: l10n.yourPublicKey,
              subtitle: publicMasterKey.beautified,
              trailing: const Icon(Icons.copy_outlined, size: 20),
              onTap: () =>
                  Clipboard.setData(ClipboardData(text: publicMasterKey)),
            ),
          NotionListRow(
            title: l10n.deviceIdentityKey,
            subtitle: client.fingerprintKey.beautified,
            trailing: const Icon(Icons.copy_outlined, size: 20),
            onTap: () =>
                Clipboard.setData(ClipboardData(text: client.fingerprintKey)),
          ),
        ],
      ),
    );
  }
}

/// The "Developer options" switch and, while it is on, the link to the
/// developer page. Sits last on Settings › Advanced.
class DeveloperOptionsSection extends StatelessWidget {
  const DeveloperOptionsSection({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: DeveloperOptions.changes,
    builder: (context, _, _) {
      final enabled = DeveloperOptions.enabled;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NotionSettingsSection('Developer'),
          NotionSettingsToggle(
            key: const ValueKey('developer-options'),
            title: 'Developer options',
            subtitle: 'Show logs, app configuration, manual push setup and '
                'message source',
            value: enabled,
            onChanged: (value) async {
              try {
                await DeveloperOptions.setEnabled(value);
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Couldn’t save this setting. Try again.'),
                    ),
                  );
                }
              }
              notionSettingsRevision.value++;
            },
          ),
          NotionSizeReveal(
            visible: enabled,
            child: NotionListRow(
              leading: const Icon(Icons.developer_mode_outlined),
              title: 'Developer tools',
              subtitle: 'Logs, configuration, push gateway and keys',
              onTap: enabled ? () => context.push(DeveloperOptions.route) : null,
            ),
          ),
        ],
      );
    },
  );
}
