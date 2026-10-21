// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/config/themes.dart';
import 'package:chatloom/pages/settings/settings.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/sync_changes.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/personal/ui/notion_settings_load.dart';
import 'package:chatloom/personal/ui/notion_settings_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/chatloom_share.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/theme_builder.dart';
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
  String? _personalSummary;
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
      _personal?.removeListener(_personalChanged);
      _personal = next..addListener(_personalChanged);
      _personalSummary = SyncChanges.settingsSummary(next);
      _accountManage = null;
      _passwordAvailable = null;
      // Revalidating private sync is not needed to draw this page; do it
      // after the page slid in, and not again within a few seconds.
      PersonalPageLoad.request(context, next);
    }
  }

  Future<Uri?> _managementUrl({bool force = false}) =>
      widget.controller.accountCache.loadManagement(force: force);

  /// Leaves settings. On phones this pops the settings shell (with the page
  /// transition and predictive back); in two-column mode, or when settings
  /// was opened without a page below, it navigates to the chats.
  void _back() {
    if (!ChatLoomThemes.isColumnMode(context) && context.canPop()) {
      context.pop();
    } else {
      context.go('/rooms');
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  void _personalChanged() {
    final personal = _personal;
    if (personal == null) return;
    final summary = SyncChanges.settingsSummary(personal);
    if (summary == _personalSummary) return;
    _personalSummary = summary;
    _refresh();
  }

  @override
  void dispose() {
    _personal?.removeListener(_personalChanged);
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
            NotionSizeReveal(
              visible: connected == null,
              child: NotionListRow(
                title: 'Check recovery status',
                onTap: widget.controller.checkBootstrap,
              ),
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
      initialData: widget.controller.cachedProfile,
      builder: (context, snapshot) {
        final profile = snapshot.data ?? widget.controller.cachedProfile;
        final name =
            profile?.displayName ?? client.userID?.localpart ?? 'Account';
        final avatar = Avatar(
          mxContent: profile?.avatarUrl,
          name: name,
          size: 44,
        );
        if (surface == SettingsSurface.account) {
          final cache = widget.controller.accountCache;
          _accountManage ??= _managementUrl();
          _passwordAvailable ??= cache.loadPasswordChange();
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
                NotionSizeReveal(
                  visible: snapshot.hasError,
                  child: NotionListRow(
                    title: 'Profile could not load',
                    subtitle: 'Retry without changing your account.',
                    onTap: widget.controller.updateProfile,
                  ),
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
                    if (id != null) ChatLoomShare.share(id, context);
                  },
                ),
                const NotionSettingsSection('Account management'),
                FutureBuilder<Uri?>(
                  key: ValueKey(client),
                  future: _accountManage,
                  initialData: cache.management?.uri,
                  builder: (context, snapshot) {
                    final known =
                        snapshot.connectionState == ConnectionState.done ||
                        cache.management != null;
                    final uri = snapshot.data ?? cache.management?.uri;
                    return NotionListRow(
                      leading: const Icon(Icons.manage_accounts_outlined),
                      title: 'Manage account',
                      subtitle: snapshot.hasError
                          ? 'Could not check account management. Retry.'
                          : !known
                          ? 'Checking account management availability…'
                          : uri == null
                          ? 'This server does not provide an account management page.'
                          : 'Open the account management page',
                      onTap: snapshot.hasError
                          ? () => setState(
                              () =>
                                  _accountManage = _managementUrl(force: true),
                            )
                          : uri == null
                          ? null
                          : () => launchUrl(
                              uri,
                              mode: LaunchMode.inAppBrowserView,
                            ),
                    );
                  },
                ),
                NotionListRow(
                  leading: const Icon(Icons.person_add_outlined),
                  title: 'Add account',
                  onTap: () => _route('/rooms/settings/addaccount'),
                ),
                FutureBuilder<bool>(
                  future: _passwordAvailable,
                  initialData: cache.passwordChange,
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
            notificationsAvailable: PlatformInfos.supportsSystemNotifications,
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
              NotionSettingsCategory.sync: SyncChanges.settingsSummary(
                personal,
              ),
            },
            status: snapshot.hasError
                ? 'Profile unavailable. Open Account to retry.'
                : null,
          ),
          actions: NotionSettingsActions(back: _back, open: _route),
        );
      },
    );
  }
}
