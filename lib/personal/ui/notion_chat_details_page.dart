// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// The same presentation is used by ordinary and merged conversation adapters.
/// Every value and action is supplied by the live source; this widget stores no
/// private preference or native notification state.
class NotionChatDetailsPage extends StatelessWidget {
  final NotionConversationDetailsData data;
  final NotionConversationDetailsActions actions;
  final Widget? leading;
  const NotionChatDetailsPage({
    super.key,
    required this.data,
    required this.actions,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    final secondary = Theme.of(context).colorScheme.onSurfaceVariant;
    final pending = data.pending;
    return Scaffold(
      // The header is glass and the rows scroll under it (UI-05).
      extendBodyBehindAppBar: true,
      appBar: notionGlassAppBar(
        leading:
            leading ??
            NotionIconButton(
              icon: Icons.chevron_left,
              label: 'Back',
              onPressed: () => Navigator.maybePop(context),
            ),
        title: const Text('Chat details'),
        actions: [
          if (actions.overflowFrom != null)
            Builder(
              builder: (context) => NotionIconButton(
                icon: Icons.more_horiz,
                label: 'More chat actions',
                onPressed: () => actions.overflowFrom!(context),
              ),
            )
          else if (actions.overflow != null)
            NotionIconButton(
              icon: Icons.more_horiz,
              label: 'More chat actions',
              onPressed: actions.overflow,
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: NotionSize.contentMaxWidth,
          ),
          // The header settles in first (avatar grows, name rises), then the
          // first screenful of sections follows; rows built later by
          // scrolling never animate.
          child: NotionEntranceScope(
            child: Builder(
              // Under the Scaffold, the top inset includes the glass header.
              builder: (context) => ListView(
                key: const PageStorageKey('notion-chat-details'),
                padding: EdgeInsets.fromLTRB(
                  20,
                  24 + MediaQuery.paddingOf(context).top,
                  20,
                  32,
                ),
                children: _entering([
                  LayoutBuilder(
                    builder: (context, constraints) {
                      final stacked =
                          constraints.maxWidth < 440 &&
                          MediaQuery.textScalerOf(context).scale(16) > 24;
                      final avatar = NotionEntrance(
                        index: 0,
                        rise: 0,
                        scale: NotionMotion.dialogFrom,
                        alignment: AlignmentDirectional.topStart.resolve(
                          Directionality.maybeOf(context),
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(
                            NotionTokens.avatarRadius,
                          ),
                          child: SizedBox.square(
                            dimension: 64,
                            child: data.avatar,
                          ),
                        ),
                      );
                      final identity = NotionEntrance(
                        index: 1,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              data.name,
                              style: stacked
                                  ? NotionTokens.title.copyWith(fontSize: 22)
                                  : NotionTokens.title,
                            ),
                            const SizedBox(height: 8),
                            NotionValueTag(
                              data.network,
                              icon: Icons.language_outlined,
                            ),
                          ],
                        ),
                      );
                      return stacked
                          ? Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                avatar,
                                const SizedBox(height: 16),
                                identity,
                              ],
                            )
                          : Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                avatar,
                                const SizedBox(width: 18),
                                Expanded(child: identity),
                              ],
                            );
                    },
                  ),
                  const SizedBox(height: 18),
                  Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 12,
                    children: [
                      NotionPressable(
                        enabled: actions.search != null,
                        child: TextButton.icon(
                          onPressed: actions.search,
                          icon: const Icon(Icons.search_outlined, size: 22),
                          label: const Text('Search messages'),
                        ),
                      ),
                    ],
                  ),
                  NotionSizeReveal(
                    visible: data.status != null,
                    child: Padding(
                      padding: const EdgeInsets.only(top: 8),
                      child: Semantics(
                        liveRegion: true,
                        child: NotionFadeThrough(
                          child: Text(
                            data.status ?? '',
                            key: ValueKey(data.status),
                            style: TextStyle(fontSize: 13, color: secondary),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const NotionDetailsSection(title: 'Shared content'),
                  NotionListRow(
                    leading: const Icon(Icons.image_outlined),
                    title: 'Media, files & links',
                    onTap: actions.media,
                    trailing: actions.media == null
                        ? Text(
                            'Choose a source',
                            style: TextStyle(fontSize: 12, color: secondary),
                          )
                        : null,
                  ),
                  if (data.sharedContent != null) data.sharedContent!,
                  const NotionDetailsSection(title: 'Conversation'),
                  NotionPropertyRow(
                    label: 'Nickname',
                    value: Text(
                      data.nickname ?? 'Name from the network',
                      style: NotionTokens.body,
                    ),
                    onTap: pending ? null : actions.nickname,
                  ),
                  Text(
                    'Your nickname is private.',
                    style: TextStyle(fontSize: 12, color: secondary),
                  ),
                  // One row per page: for a single chat, Notifications opens
                  // the same page as the visibility rules, so the adapter
                  // passes no separate [preferences] action (CS-06).
                  if (actions.preferences != null)
                    NotionListRow(
                      leading: const Icon(Icons.tune),
                      title: 'Visibility',
                      subtitle: 'Where this chat appears, or ignore it',
                      onTap: actions.preferences,
                    ),
                  NotionListRow(
                    leading: const Icon(Icons.notifications_none_outlined),
                    title: 'Notifications',
                    subtitle: data.notifications == 'Choose a source'
                        ? 'Set for each network'
                        : actions.preferences == null
                        ? 'Also where this chat appears'
                        : null,
                    trailing: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 130),
                      child: NotionFadeThrough(
                        alignment: AlignmentDirectional.centerEnd,
                        child: NotionValueTag(
                          data.notifications,
                          key: ValueKey(data.notifications),
                        ),
                      ),
                    ),
                    onTap: actions.notifications,
                  ),
                  // Telegram's "Mute for 1 hour / 8 hours / 1 week / until I
                  // unmute" in the profile (FX-07); the end of a timed mute
                  // stays visible here.
                  if (actions.muteFrom != null || data.mute != null)
                    Builder(
                      builder: (context) => NotionListRow(
                        key: const ValueKey('details-mute'),
                        leading: Icon(
                          data.mute == null
                              ? Icons.notifications_off_outlined
                              : Icons.notifications_active_outlined,
                        ),
                        title: data.mute == null ? 'Mute…' : 'Unmute',
                        subtitle:
                            data.mute ??
                            (actions.muteFrom == null
                                ? 'Connect private sync to edit'
                                : null),
                        trailing: const SizedBox.shrink(),
                        onTap: pending || actions.muteFrom == null
                            ? null
                            : () => actions.muteFrom!(context),
                      ),
                    ),
                  if (data.disappearing != null)
                    NotionListRow(
                      key: const ValueKey('details-disappearing'),
                      leading: const Icon(Icons.timer_outlined),
                      title: 'Disappearing messages',
                      subtitle:
                          'New messages disappear after this time. Set on the '
                          'network.',
                      trailing: NotionValueTag(data.disappearing!),
                    ),
                  NotionListRow(
                    leading: const Icon(Icons.push_pin_outlined),
                    title: 'Pin chat',
                    subtitle: pending
                        ? 'Awaiting private sync'
                        : actions.pin == null
                        ? 'Connect private sync to edit'
                        : null,
                    trailing: Switch(
                      value: data.pinned,
                      onChanged: pending ? null : actions.pin,
                    ),
                  ),
                  NotionListRow(
                    leading: const Icon(Icons.visibility_off_outlined),
                    title: 'Incognito',
                    subtitle: 'For all chats on this device',
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        NotionFadeThrough(
                          alignment: AlignmentDirectional.centerEnd,
                          child: NotionValueTag(
                            data.incognito ? 'On' : 'Off',
                            key: ValueKey(data.incognito),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.chevron_right, size: 22),
                      ],
                    ),
                    onTap: actions.privacy,
                  ),
                  NotionListRow(
                    leading: const Icon(Icons.palette_outlined),
                    title: 'Colours & avatar',
                    subtitle: actions.appearance == null
                        ? 'Connect private sync to edit'
                        : null,
                    onTap: pending ? null : actions.appearance,
                  ),
                  const NotionDetailsSection(),
                  NotionListRow(
                    key: const ValueKey('details-archive'),
                    leading: Icon(
                      data.archived
                          ? Icons.unarchive_outlined
                          : Icons.archive_outlined,
                    ),
                    title: data.archived ? 'Unarchive chat' : 'Archive chat',
                    subtitle: actions.archive == null
                        ? 'Connect private sync to edit'
                        : data.archived
                        ? 'Back to your chats'
                        : 'Private archive · keeps your history',
                    onTap: pending ? null : actions.archive,
                  ),
                  // A group's people are under Participants (FX-09).
                  if (actions.contact != null)
                    NotionListRow(
                      leading: const Icon(Icons.person_outline),
                      title: 'View contact',
                      onTap: actions.contact,
                    ),
                  if (data.sourceRows.isNotEmpty) ...[
                    const NotionDetailsSection(title: 'Network & security'),
                    ...data.sourceRows,
                  ],
                ]),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Section entrances after the two header slots (avatar 0, name 1).
  static List<Widget> _entering(List<Widget> children) => [
    children.first,
    for (var i = 1; i < children.length; i++)
      NotionEntrance(
        index: i + 1,
        rise: NotionMotion.riseList,
        child: children[i],
      ),
  ];
}

class NotionDetailsSection extends StatelessWidget {
  final String? title;
  const NotionDetailsSection({super.key, this.title});
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 16),
        child: Divider(
          height: 1,
          thickness: 1,
          color: Theme.of(context).dividerColor,
        ),
      ),
      if (title != null) ...[
        Text(title!, style: NotionTokens.heading),
        const SizedBox(height: 8),
      ],
    ],
  );
}

/// Shared-content presentation used by actual events and fictional captures.
/// The event adapter owns all source, privacy and media-opening decisions.
class NotionSharedContentBlock extends StatelessWidget {
  final String label;
  final Widget? thumbnail;
  final bool audio;
  final bool video;
  final VoidCallback? onTap;
  const NotionSharedContentBlock({
    super.key,
    required this.label,
    this.thumbnail,
    this.audio = false,
    this.video = false,
    this.onTap,
  });
  @override
  Widget build(BuildContext context) => Semantics(
    button: onTap != null,
    label:
        '${onTap == null ? 'Shared' : 'Open shared'} ${video
            ? 'video'
            : thumbnail != null
            ? 'photo'
            : audio
            ? 'audio'
            : video
            ? 'video'
            : 'file'}, $label',
    child: NotionPressable(
      enabled: onTap != null,
      child: InkWell(
        onTap: onTap,
        borderRadius: NotionRadius.smAll,
        child: Container(
          width: thumbnail != null ? 144 : 88,
          height: 92,
          decoration: BoxDecoration(
            border: Border.all(color: Theme.of(context).dividerColor),
            borderRadius: NotionRadius.smAll,
          ),
          clipBehavior: Clip.antiAlias,
          child:
              thumbnail ??
              Padding(
                padding: const EdgeInsets.all(10),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      audio
                          ? Icons.audio_file_outlined
                          : video
                          ? Icons.videocam_outlined
                          : Icons.description_outlined,
                      size: 25,
                    ),
                    const SizedBox(height: 6),
                    Flexible(
                      child: Text(
                        label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
        ),
      ),
    ),
  );
}

class NotionValueTag extends StatelessWidget {
  final String value;
  final IconData? icon;
  const NotionValueTag(this.value, {super.key, this.icon});
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
    decoration: BoxDecoration(
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      borderRadius: NotionRadius.pillAll,
    ),
    child: Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      children: [
        if (icon != null) Icon(icon, size: 16),
        Text(value, style: const TextStyle(fontSize: 13), softWrap: true),
      ],
    ),
  );
}
