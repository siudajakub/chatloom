// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/pages/settings/settings.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/ui/notion_settings_body.dart';
import 'package:fluffychat/personal/ui/notion_settings_page.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/fluffy_share.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/theme_builder.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:url_launcher/url_launcher_string.dart';

class NotionSettingsAdapter extends StatefulWidget {
  final SettingsController controller;
  const NotionSettingsAdapter({super.key, required this.controller});
  @override
  State<NotionSettingsAdapter> createState() => _NotionSettingsAdapterState();
}

class _NotionSettingsAdapterState extends State<NotionSettingsAdapter> {
  PersonalClient? _personal;
  Future<Uri?>? _accountManage;
  Future<bool>? _passwordAvailable;
  @override
  void initState() {
    super.initState();
    notionSettingsRevision.addListener(_refresh);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _bindClient(Matrix.of(context).client);
  }

  void _bindClient(Client client) {
    final next = PersonalClient.of(client);
    if (_personal != next) {
      _personal?.removeListener(_refresh);
      _personal = next..addListener(_refresh);
      _accountManage = null;
      _passwordAvailable = null;
      next.load();
    }
  }

  Future<Uri?> _managementUrl(Client client) async =>
      (await client.getAuthMetadata().timeout(
        const Duration(seconds: 10),
      )).accountManagementUri;

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _personal?.removeListener(_refresh);
    notionSettingsRevision.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _route(String path) async {
    if (MediaQuery.sizeOf(context).width > 840) {
      context.go(path);
    } else {
      await context.push(path);
    }
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    final client = Matrix.of(context).client;
    _bindClient(client);
    final personal = _personal!;
    final surface = widget.controller.widget.surface;
    if (surface == SettingsSurface.about) {
      return NotionSettingsScaffold(
        title: 'About & help',
        child: Column(
          children: [
            NotionListRow(
              leading: const Icon(Icons.info_outline),
              title: 'App information',
              subtitle: 'Version and licenses',
              onTap: () => PlatformInfos.showDialog(context),
            ),
            NotionListRow(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: 'Privacy policy',
              onTap: () => launchUrlString(AppSettings.privacyPolicy.value),
            ),
            NotionListRow(
              leading: const Icon(Icons.dns_outlined),
              title: 'Homeserver',
              onTap: () => _route('/rooms/settings/homeserver'),
            ),
          ],
        ),
      );
    }
    if (surface == SettingsSurface.recovery) {
      final connected = widget.controller.cryptoIdentityConnected;
      return NotionSettingsScaffold(
        title: 'Encryption & recovery',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NotionListRow(
              leading: const Icon(Icons.backup_outlined),
              title: 'Key backup',
              subtitle: connected == null
                  ? 'Recovery status is not confirmed. Check it when connected.'
                  : connected
                  ? 'Recovery connected'
                  : 'Recovery is not set up',
            ),
            if (connected == null)
              NotionListRow(
                title: 'Check recovery status',
                onTap: widget.controller.checkBootstrap,
              ),
            NotionListRow(
              title: connected == true ? 'Manage recovery' : 'Set up recovery',
              subtitle: 'Uses the existing encrypted key backup flow.',
              onTap: widget.controller.firstRunBootstrapAction,
            ),
          ],
        ),
      );
    }
    return FutureBuilder<Profile>(
      key: ValueKey(client),
      future: widget.controller.profileFuture,
      builder: (context, snapshot) {
        final profile = snapshot.data;
        final name =
            profile?.displayName ?? client.userID?.localpart ?? 'Account';
        final avatar = Avatar(
          mxContent: profile?.avatarUrl,
          name: name,
          size: 44,
        );
        if (surface == SettingsSurface.account) {
          _accountManage ??= _managementUrl(client);
          _passwordAvailable ??= client
              .getCapabilities()
              .timeout(const Duration(seconds: 10))
              .then((caps) => caps.mChangePassword?.enabled != false);
          return NotionSettingsScaffold(
            title: 'Account',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    avatar,
                    const SizedBox(width: 16),
                    Expanded(child: Text(name, style: NotionTokens.heading)),
                  ],
                ),
                const SizedBox(height: 12),
                const Text(
                  'Your network profile is visible to other people on this account.',
                ),
                if (snapshot.hasError)
                  NotionListRow(
                    title: 'Profile could not load',
                    subtitle: 'Retry without changing your account.',
                    onTap: widget.controller.updateProfile,
                  ),
                const NotionSettingsSection('Profile'),
                NotionListRow(
                  leading: const Icon(Icons.edit_outlined),
                  title: 'Change display name',
                  onTap: widget.controller.setDisplaynameAction,
                ),
                NotionListRow(
                  leading: const Icon(Icons.photo_camera_outlined),
                  title: 'Change profile photo',
                  onTap: widget.controller.setAvatarAction,
                ),
                NotionListRow(
                  leading: const Icon(Icons.share_outlined),
                  title: 'Share account address',
                  onTap: () {
                    final id = client.userID;
                    if (id != null) FluffyShare.share(id, context);
                  },
                ),
                const NotionSettingsSection('Account management'),
                FutureBuilder<Uri?>(
                  key: ValueKey(client),
                  future: _accountManage,
                  builder: (context, snapshot) => NotionListRow(
                    leading: const Icon(Icons.manage_accounts_outlined),
                    title: 'Manage account',
                    subtitle: snapshot.hasError
                        ? 'Could not check account management. Retry.'
                        : snapshot.connectionState != ConnectionState.done
                        ? 'Checking account management availability…'
                        : snapshot.data == null
                        ? 'This server does not provide an account management page.'
                        : 'Open the account management page',
                    onTap: snapshot.hasError
                        ? () => setState(
                            () => _accountManage = _managementUrl(client),
                          )
                        : snapshot.data == null
                        ? null
                        : () => launchUrl(
                            snapshot.data!,
                            mode: LaunchMode.inAppBrowserView,
                          ),
                  ),
                ),
                NotionListRow(
                  leading: const Icon(Icons.person_add_outlined),
                  title: 'Add account',
                  onTap: () => _route('/rooms/settings/addaccount'),
                ),
                FutureBuilder<bool>(
                  future: _passwordAvailable,
                  builder: (context, snapshot) => NotionListRow(
                    leading: const Icon(Icons.password_outlined),
                    title: 'Change password',
                    subtitle: snapshot.data == false
                        ? 'Password changes are not supported by this account.'
                        : snapshot.hasError
                        ? 'Availability could not be checked. Open to continue.'
                        : null,
                    onTap: snapshot.data == false
                        ? null
                        : () => _route('/rooms/settings/security/password'),
                  ),
                ),
                const NotionSettingsSection('Account actions'),
                NotionListRow(
                  leading: const Icon(Icons.logout_outlined),
                  title: 'Log out',
                  onTap: widget.controller.logoutAction,
                ),
                NotionListRow(
                  leading: const Icon(Icons.cloud_upload_outlined),
                  title: 'Export session and wipe device',
                  subtitle:
                      'Export a local session backup and remove this session from the device. Keep the backup private.',
                  onTap: widget.controller.dehydrateAction,
                ),
                NotionListRow(
                  leading: Icon(
                    Icons.delete_outline,
                    color: Theme.of(context).colorScheme.error,
                  ),
                  title: 'Delete account',
                  subtitle: 'Permanently deactivate this account.',
                  onTap: widget.controller.deleteAccountAction,
                ),
              ],
            ),
          );
        }
        final appearance = switch (ThemeController.of(context).themeMode) {
          ThemeMode.dark => 'Dark',
          ThemeMode.light => 'Light',
          ThemeMode.system => 'System',
        };
        return NotionSettingsPage(
          data: NotionSettingsData(
            name: name,
            avatar: avatar,
            selectedPath: GoRouterState.of(context).uri.path,
            summaries: {
              NotionSettingsCategory.account:
                  'Account · Profile and account management',
              NotionSettingsCategory.security:
                  AppSettings.personalIncognito.value
                  ? 'Incognito on · App lock, devices and recovery'
                  : 'Incognito off · App lock, devices and recovery',
              NotionSettingsCategory.appearance:
                  '$appearance · Text size and wallpaper',
              NotionSettingsCategory.sync: personal.ready
                  ? (personal.pending.isEmpty
                        ? 'Private sync configured · Services and transcriptions'
                        : '${personal.pending.length} changes awaiting confirmation')
                  : 'Private sync not connected',
            },
            status: snapshot.hasError
                ? 'Profile unavailable. Open Account to retry.'
                : null,
          ),
          actions: NotionSettingsActions(
            back: () => context.go('/rooms'),
            open: _route,
          ),
        );
      },
    );
  }
}
