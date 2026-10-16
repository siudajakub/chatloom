// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/ui/notion/notion.dart';
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
      appBar: AppBar(
        toolbarHeight: NotionTokens.headerHeight,
        leading:
            leading ??
            NotionIconButton(
              icon: Icons.chevron_left,
              label: 'Back',
              onPressed: () => Navigator.maybePop(context),
            ),
        titleSpacing: 0,
        title: Row(
          children: [
            Container(
              width: 1,
              height: 22,
              color: Theme.of(context).dividerColor,
            ),
            const SizedBox(width: 12),
            const Flexible(
              child: Text('Chat details', style: TextStyle(fontSize: 17)),
            ),
          ],
        ),
        actions: [
          if (actions.overflow != null)
            NotionIconButton(
              icon: Icons.more_horiz,
              label: 'More chat actions',
              onPressed: actions.overflow,
            ),
        ],
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 640),
          child: ListView(
            key: const PageStorageKey('notion-chat-details'),
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 32),
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  final stacked =
                      constraints.maxWidth < 440 &&
                      MediaQuery.textScalerOf(context).scale(16) > 24;
                  final avatar = ClipRRect(
                    borderRadius: BorderRadius.circular(
                      NotionTokens.avatarRadius,
                    ),
                    child: SizedBox.square(dimension: 64, child: data.avatar),
                  );
                  final identity = Column(
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
                  TextButton.icon(
                    onPressed: actions.search,
                    icon: const Icon(Icons.search_outlined, size: 22),
                    label: const Text('Search'),
                  ),
                  Container(
                    height: 22,
                    width: 1,
                    color: Theme.of(context).dividerColor,
                  ),
                  TextButton.icon(
                    onPressed: actions.media,
                    icon: const Icon(Icons.photo_library_outlined, size: 22),
                    label: const Text('Shared content'),
                  ),
                  TextButton.icon(
                    onPressed: actions.mute,
                    icon: const Icon(
                      Icons.notifications_none_outlined,
                      size: 22,
                    ),
                    label: Text(
                      data.notifications == 'Choose a source'
                          ? 'Choose a source'
                          : 'Notifications',
                    ),
                  ),
                ],
              ),
              if (data.status != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Semantics(
                    liveRegion: true,
                    child: Text(
                      data.status!,
                      style: TextStyle(fontSize: 13, color: secondary),
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
                  data.nickname ?? 'Source network name',
                  style: NotionTokens.body,
                ),
                onTap: pending ? null : actions.nickname,
              ),
              Text(
                'Your nickname is private.',
                style: TextStyle(fontSize: 12, color: secondary),
              ),
              if (actions.preferences != null)
                NotionListRow(
                  leading: const Icon(Icons.tune),
                  title: 'Visibility & notifications',
                  subtitle: 'Ignore, restore or override network rules',
                  onTap: actions.preferences,
                ),
              NotionListRow(
                leading: const Icon(Icons.notifications_none_outlined),
                title: 'Notifications',
                subtitle: data.notifications == 'Choose a source'
                    ? 'Managed separately for each source'
                    : null,
                trailing: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 130),
                  child: NotionValueTag(data.notifications),
                ),
                onTap: actions.notifications,
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
                title: 'Incognito mode',
                subtitle: 'Applies to this device',
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    NotionValueTag(data.incognito ? 'On' : 'Off'),
                    const SizedBox(width: 8),
                    const Icon(Icons.chevron_right, size: 22),
                  ],
                ),
                onTap: actions.privacy,
              ),
              NotionListRow(
                leading: const Icon(Icons.palette_outlined),
                title: 'Chat appearance',
                subtitle: actions.appearance == null
                    ? 'Connect private sync to edit'
                    : null,
                onTap: pending ? null : actions.appearance,
              ),
              const NotionDetailsSection(),
              NotionListRow(
                leading: const Icon(Icons.archive_outlined),
                title: 'Archive chat',
                subtitle: actions.archive == null
                    ? 'Connect private sync to edit'
                    : 'Private archive · keeps your history',
                onTap: pending ? null : actions.archive,
              ),
              NotionListRow(
                leading: const Icon(Icons.person_outline),
                title: 'View contact',
                onTap: actions.contact,
              ),
              if (data.sourceRows.isNotEmpty) ...[
                const NotionDetailsSection(title: 'Network & security'),
                ...data.sourceRows,
              ],
            ],
          ),
        ),
      ),
    );
  }
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
    child: InkWell(
      onTap: onTap,
      child: Container(
        width: thumbnail != null ? 144 : 88,
        height: 92,
        decoration: BoxDecoration(
          border: Border.all(color: Theme.of(context).dividerColor),
          borderRadius: BorderRadius.circular(6),
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
      borderRadius: BorderRadius.circular(4),
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
