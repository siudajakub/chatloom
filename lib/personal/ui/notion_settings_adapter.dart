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
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/theme_builder.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

class NotionSettingsAdapter extends StatefulWidget {
  final SettingsController controller;
  const NotionSettingsAdapter({super.key, required this.controller});
  @override
  State<NotionSettingsAdapter> createState() => _NotionSettingsAdapterState();
}

class _NotionSettingsAdapterState extends State<NotionSettingsAdapter> {
  PersonalClient? _personal;
  String? _personalSummary;
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
      // Revalidating private sync is not needed to draw this page; do it
      // after the page slid in, and not again within a few seconds.
      PersonalPageLoad.request(context, next);
    }
  }

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
    if (surface == SettingsSurface.advanced) {
      return NotionSettingsScaffold(
        title: 'Advanced',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            NotionListRow(
              leading: const Icon(Icons.sync_outlined),
              title: 'Private sync',
              subtitle: SyncChanges.settingsSummary(personal),
              onTap: () => _route('/rooms/settings/sync'),
            ),
            NotionListRow(
              leading: const Icon(Icons.info_outline),
              title: 'App information',
              subtitle: 'Version and licenses',
              onTap: () => PlatformInfos.showDialog(context),
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
          return NotionSettingsScaffold(
            title: 'Account',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    avatar,
                    const SizedBox(width: NotionSpace.md),
                    Expanded(child: Text(name, style: NotionType.heading)),
                  ],
                ),
                const SizedBox(height: NotionSpace.sm),
                const Text(
                  'Your name and photo are visible to people you chat with where the network shows them.',
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
                const NotionSettingsSection('Session'),
                NotionListRow(
                  leading: const Icon(Icons.logout_outlined),
                  title: 'Log out',
                  subtitle: 'Sign out of this device',
                  onTap: widget.controller.logoutAction,
                ),
                const SizedBox(height: NotionSpace.md),
                Text(
                  'Email, password and account deletion are managed in your Beeper account.',
                  style: context.notion.typography.footnoteMuted,
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
              NotionSettingsCategory.account: 'Profile and sign out',
              NotionSettingsCategory.security:
                  AppSettings.personalIncognito.value
                  ? 'Incognito on · App lock, devices and recovery'
                  : 'Incognito off · App lock, devices and recovery',
              NotionSettingsCategory.appearance:
                  '$appearance · Colours and wallpaper',
              NotionSettingsCategory.advanced: SyncChanges.settingsSummary(
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
