// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

final notionSettingsRevision = ValueNotifier<int>(0);

/// One navigation catalogue for both the mobile index and desktop sidebar.
///
/// Order is the order on screen: the account row, the everyday settings,
/// the ChatLoom tools, then Advanced (private sync, push setup, diagnostics
/// and app information) last.
enum NotionSettingsCategory {
  account('Account', Icons.person_outline, 'account', 'Profile and sign out'),
  appearance(
    'Appearance',
    Icons.palette_outlined,
    'style',
    'Theme, colours and wallpaper',
  ),
  notifications(
    'Notifications',
    Icons.notifications_none_outlined,
    'notifications',
    'Previews, push setup and diagnostics',
  ),
  security(
    'Privacy & security',
    Icons.shield_outlined,
    'security',
    'Incognito, app lock, devices and recovery',
  ),
  chats(
    'Chats & media',
    Icons.forum_outlined,
    'chat',
    'Messages, gestures, voice and merged chats',
  ),
  networks(
    'Networks',
    Icons.hub_outlined,
    'networks',
    'Connection status, groups and notifications',
  ),
  transcription(
    'Transcription',
    Icons.subtitles_outlined,
    'transcriptions',
    'Automatic transcripts, language and limits',
  ),
  reminders(
    'Reminders',
    Icons.alarm_outlined,
    'reminders',
    'Bring chats back at the right time',
  ),
  scheduled(
    'Scheduled messages',
    Icons.schedule_outlined,
    'scheduled',
    'Messages waiting to be sent',
  ),
  bookmarks(
    'Bookmarks',
    Icons.bookmarks_outlined,
    'bookmarks',
    'Find your saved messages',
  ),
  advanced(
    'Advanced',
    Icons.tune,
    'advanced',
    'Private sync, push setup, diagnostics and app info',
  );

  final String title, path, summary;
  final IconData icon;
  const NotionSettingsCategory(this.title, this.icon, this.path, this.summary);
  String get route => '/rooms/settings/$path';
  bool get isTool => index >= reminders.index && index <= bookmarks.index;

  static NotionSettingsCategory forPath(String path) {
    final parts = Uri.parse(path).path.split('/').skip(3).toList();
    final leaf = parts.firstOrNull;
    return switch (leaf) {
      'devices' || 'recovery' => security,
      'people' => chats,
      'sync' => advanced,
      'push' => notifications,
      _ =>
        values.where((category) => category.path == leaf).firstOrNull ??
            account,
    };
  }
}

class NotionSettingsData {
  final String name;
  final Widget avatar;
  final String selectedPath;
  final Map<NotionSettingsCategory, String> summaries;
  final String? status;
  final bool notificationsAvailable;
  const NotionSettingsData({
    required this.name,
    required this.avatar,
    this.selectedPath = '/rooms/settings',
    this.summaries = const {},
    this.status,
    this.notificationsAvailable = true,
  });
}

class NotionSettingsActions {
  final VoidCallback? back;
  final ValueChanged<String>? open;
  const NotionSettingsActions({this.back, this.open});
}

class NotionSettingsPage extends StatelessWidget {
  final NotionSettingsData data;
  final NotionSettingsActions actions;
  const NotionSettingsPage({
    super.key,
    required this.data,
    required this.actions,
  });

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 840;
    final selected = NotionSettingsCategory.forPath(data.selectedPath);
    Widget row(NotionSettingsCategory category) {
      final active = wide && category == selected;
      return Semantics(
        selected: active,
        // The selected background eases between rows in the sidebar.
        child: AnimatedContainer(
          duration: NotionMotion.of(context, NotionMotion.quick),
          curve: NotionMotion.standard,
          decoration: BoxDecoration(
            color: active
                ? Theme.of(context).colorScheme.surfaceContainerHighest
                : Colors.transparent,
            borderRadius: BorderRadius.circular(NotionTokens.radius),
          ),
          child: Material(
            type: MaterialType.transparency,
            borderRadius: BorderRadius.circular(NotionTokens.radius),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: NotionListRow(
                leading: category == NotionSettingsCategory.account
                    ? SizedBox.square(
                        dimension: 24,
                        child: ClipRRect(
                          borderRadius: NotionRadius.avatarAll,
                          child: FittedBox(
                            fit: BoxFit.cover,
                            child: SizedBox.square(
                              dimension: 44,
                              child: data.avatar,
                            ),
                          ),
                        ),
                      )
                    : Icon(category.icon),
                title: category == NotionSettingsCategory.account
                    ? data.name
                    : category.title,
                subtitle: data.summaries[category] ?? category.summary,
                onTap: actions.open == null
                    ? null
                    : () => actions.open!(category.route),
              ),
            ),
          ),
        ),
      );
    }

    // Rows scroll under the glass header, like every list page
    // (DESIGN.md "Glass").
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        toolbarHeight: NotionTokens.headerHeight,
        backgroundColor: Colors.transparent,
        flexibleSpace: const NotionGlassBar(),
        leading: NotionIconButton(
          icon: Icons.chevron_left,
          label: 'Back to chats',
          onPressed: actions.back,
        ),
        title: const Text('Settings'),
        centerTitle: false,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          // Rows rise in once after the push; rows built later by
          // scrolling appear without animation.
          child: NotionEntranceScope(
            // Inside the Scaffold the top padding includes the header.
            child: Builder(
              builder: (context) => ListView(
                key: const PageStorageKey('notion-settings'),
                padding: EdgeInsets.fromLTRB(
                  8,
                  8 + MediaQuery.paddingOf(context).top,
                  8,
                  32,
                ),
                children: NotionEntrance.stagger([
                  row(NotionSettingsCategory.account),
                  NotionSizeReveal(
                    visible: data.status != null,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Semantics(
                        liveRegion: true,
                        child: NotionFadeThrough(
                          child: Text(
                            data.status ?? '',
                            key: ValueKey(data.status),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Divider(),
                  ),
                  for (final category in NotionSettingsCategory.values.where(
                    (c) =>
                        c.index < NotionSettingsCategory.reminders.index &&
                        c != NotionSettingsCategory.account &&
                        (data.notificationsAvailable ||
                            c != NotionSettingsCategory.notifications),
                  ))
                    row(category),
                  const Padding(
                    padding: EdgeInsets.fromLTRB(
                      NotionSpace.sm,
                      NotionSpace.xl,
                      NotionSpace.sm,
                      NotionSpace.xxs,
                    ),
                    child: NotionSettingsGroupLabel('Tools'),
                  ),
                  for (final category in NotionSettingsCategory.values.where(
                    (c) => c.isTool,
                  ))
                    row(category),
                  const Padding(
                    padding: EdgeInsets.symmetric(
                      horizontal: NotionSpace.sm,
                      vertical: NotionSpace.xs,
                    ),
                    child: Divider(),
                  ),
                  row(NotionSettingsCategory.advanced),
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Muted group label on the settings index ("Tools").
class NotionSettingsGroupLabel extends StatelessWidget {
  final String text;
  const NotionSettingsGroupLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Semantics(
    header: true,
    child: Text(text, style: context.notion.typography.sectionLabel),
  );
}
