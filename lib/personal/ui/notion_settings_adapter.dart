// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/pages/settings/settings.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/personal_hub.dart';
import 'package:fluffychat/personal/privacy.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_page.dart';
import 'package:fluffychat/personal/ui/notion_settings_page.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/fluffy_share.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/widgets/app_lock.dart';
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
  bool _privacyPending = false;
  bool _profileFailed = false;
  String? _status;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final next = PersonalClient.of(Matrix.of(context).client);
    if (_personal != next) {
      _personal?.removeListener(_refresh);
      _personal = next..addListener(_refresh);
      _accountManage = _managementUrl(next.client);
      next.load();
    }
  }

  Future<Uri?> _managementUrl(Client client) async {
    try {
      return (await client.getAuthMetadata()).accountManagementUri;
    } catch (_) {
      return null;
    }
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _personal?.removeListener(_refresh);
    super.dispose();
  }

  Future<void> _privacy(bool value) async {
    if (_privacyPending) return;
    setState(() {
      _privacyPending = true;
      _status = null;
    });
    try {
      await PersonalPrivacy.setIncognito(
        value,
        Matrix.of(context).widget.clients,
      );
    } catch (_) {
      if (mounted)
        setState(
          () => _status =
              'Could not finish updating privacy. The current device policy is shown; try again.',
        );
    } finally {
      if (mounted) setState(() => _privacyPending = false);
    }
  }

  Future<void> _hub() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => PersonalHub(client: Matrix.of(context).client),
      ),
    );
    _refresh();
  }

  Future<void> _route(String path) async {
    await context.push(path);
    _refresh();
  }

  Future<void> _profile() {
    if (_profileFailed) widget.controller.updateProfile();
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height * .8,
          ),
          child: SingleChildScrollView(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Text('Edit profile', style: NotionTokens.heading),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Your network profile is visible to other people on this account.',
                  ),
                  NotionListRow(
                    leading: const Icon(Icons.edit_outlined),
                    title: 'Change display name',
                    onTap: () {
                      Navigator.pop(context);
                      widget.controller.setDisplaynameAction();
                    },
                  ),
                  NotionListRow(
                    leading: const Icon(Icons.photo_camera_outlined),
                    title: 'Change profile photo',
                    onTap: () {
                      Navigator.pop(context);
                      widget.controller.setAvatarAction();
                    },
                  ),
                  NotionListRow(
                    leading: const Icon(Icons.share_outlined),
                    title: 'Share account address',
                    onTap: () {
                      Navigator.pop(context);
                      final id = Matrix.of(this.context).client.userID;
                      if (id != null) FluffyShare.share(id, this.context);
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _overflow() => showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('More settings', style: NotionTokens.heading),
              NotionListRow(
                leading: const Icon(Icons.backup_outlined),
                title: 'Encryption & recovery',
                subtitle: widget.controller.cryptoIdentityConnected == null
                    ? 'Checking recovery status'
                    : widget.controller.cryptoIdentityConnected!
                    ? 'Recovery connected'
                    : 'Set up recovery',
                onTap: () {
                  Navigator.pop(context);
                  widget.controller.firstRunBootstrapAction();
                },
              ),
              NotionListRow(
                leading: const Icon(Icons.tune_outlined),
                title: 'Personal tools',
                subtitle:
                    'Worker, conflicts, merge, organization, bookmarks, schedules & reminders',
                onTap: () {
                  Navigator.pop(context);
                  _hub();
                },
              ),
              NotionListRow(
                leading: const Icon(Icons.forum_outlined),
                title: 'Chat preferences',
                onTap: () {
                  Navigator.pop(context);
                  _route('/rooms/settings/chat');
                },
              ),
              NotionListRow(
                leading: const Icon(Icons.shield_outlined),
                title: 'Security & privacy',
                onTap: () {
                  Navigator.pop(context);
                  _route('/rooms/settings/security');
                },
              ),
              NotionListRow(
                leading: const Icon(Icons.person_add_outlined),
                title: 'Add account',
                onTap: () {
                  Navigator.pop(context);
                  _route('/rooms/settings/addaccount');
                },
              ),
              FutureBuilder<Uri?>(
                future: _accountManage,
                builder: (context, snapshot) => snapshot.data == null
                    ? const SizedBox.shrink()
                    : NotionListRow(
                        leading: const Icon(Icons.manage_accounts_outlined),
                        title: 'Manage account',
                        onTap: () {
                          Navigator.pop(context);
                          launchUrl(
                            snapshot.data!,
                            mode: LaunchMode.inAppBrowserView,
                          );
                        },
                      ),
              ),
              NotionListRow(
                leading: const Icon(Icons.dns_outlined),
                title: 'Homeserver',
                onTap: () {
                  Navigator.pop(context);
                  _route('/rooms/settings/homeserver');
                },
              ),
              NotionListRow(
                leading: const Icon(Icons.privacy_tip_outlined),
                title: 'Privacy policy',
                onTap: () {
                  Navigator.pop(context);
                  launchUrlString(AppSettings.privacyPolicy.value);
                },
              ),
              const NotionDetailsSection(),
              NotionListRow(
                leading: const Icon(Icons.logout_outlined),
                title: 'Log out',
                onTap: () {
                  Navigator.pop(context);
                  widget.controller.logoutAction();
                },
              ),
            ],
          ),
        ),
      ),
    ),
  );
  @override
  Widget build(BuildContext context) {
    final personal = _personal!;
    String appLock;
    try {
      appLock = AppLock.of(context).isActive ? 'On' : 'Off';
    } catch (_) {
      appLock = 'Unknown';
    }
    final appearance = switch (ThemeController.of(context).themeMode) {
      ThemeMode.dark => 'Dark',
      ThemeMode.light => 'Light',
      ThemeMode.system => 'System',
    };
    return FutureBuilder<Profile>(
      future: widget.controller.profileFuture,
      builder: (context, snapshot) {
        _profileFailed = snapshot.hasError;
        final profile = snapshot.data;
        final name =
            profile?.displayName ??
            Matrix.of(context).client.userID?.localpart ??
            'Account';
        return NotionSettingsPage(
          data: NotionSettingsData(
            name: name,
            avatar: Avatar(mxContent: profile?.avatarUrl, name: name, size: 44),
            incognito: AppSettings.personalIncognito.value,
            privacyPending: _privacyPending,
            appLock: appLock,
            appearance: appearance,
            privateSync: personal.ready
                ? personal.pending.isEmpty
                      ? 'Connected'
                      : 'Changes awaiting synchronization'
                : 'Not connected',
            status:
                _status ??
                (snapshot.hasError
                    ? 'Your profile could not load. Open Edit profile to retry.'
                    : null),
          ),
          actions: NotionSettingsActions(
            back: () => context.go('/rooms'),
            overflow: _overflow,
            editProfile: _profile,
            incognito: _privacy,
            appLock: () => _route('/rooms/settings/security'),
            devices: () => _route('/rooms/settings/devices'),
            notifications: () => _route('/rooms/settings/notifications'),
            appearance: () => _route('/rooms/settings/style'),
            transcriptions: _hub,
            privateSync: _hub,
            about: () => PlatformInfos.showDialog(context),
          ),
        );
      },
    );
  }
}
