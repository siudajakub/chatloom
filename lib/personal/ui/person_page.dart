// SPDX-License-Identifier: AGPL-3.0-or-later
// The one page of a merged person (FT-22): name, photo, chats with their
// network, status and default, how messages are sent, notifications,
// shared content, pin/archive/visibility and unmerge. Everything here is
// private, end-to-end encrypted metadata; no network room, membership or
// account setting changes. Native per-chat pages are never opened for
// notifications or mute.
import 'dart:async';

import 'package:chatloom/pages/chat_list/chat_list_item.dart'
    show personalConversationAvatar;
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/organization_page.dart'
    show pickAndUploadPrivateAvatar, showChatThemeDialog;
import 'package:chatloom/personal/person_location.dart';
import 'package:chatloom/personal/person_merge.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/private_avatar.dart';
import 'package:chatloom/personal/ui/chat_preferences_page.dart';
import 'package:chatloom/personal/ui/notion_chat_details_content.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart'
    show NotionNetworkGlyph;
import 'package:chatloom/personal/ui/notion_settings_body.dart'
    show NotionSettingsToggle;
import 'package:chatloom/personal/ui/notion_settings_load.dart';
import 'package:chatloom/personal/ui/person_sheets.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/widgets/adaptive_dialogs/user_dialog.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// Opens the person page of [group] (from the merged chat header, its
/// "Chat details" action or People settings).
Future<void> showPersonPage(
  BuildContext context, {
  required PersonalClient personal,
  required PersonGroup group,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => PersonPage(personal: personal, group: group),
  ),
);

class PersonPage extends StatefulWidget {
  final PersonalClient personal;

  /// The person as it was opened; the page follows its saved state.
  final PersonGroup group;
  const PersonPage({super.key, required this.personal, required this.group});
  @override
  State<PersonPage> createState() => _PersonPageState();
}

class _PersonPageState extends State<PersonPage> {
  PersonalClient get personal => widget.personal;
  late final StreamSubscription<SyncUpdate> _sync;
  Set<String> _roomIds = {};

  @override
  void initState() {
    super.initState();
    _roomIds = {for (final m in widget.group.members) m.roomId};
    personal.addListener(_changed);
    // Membership and names of the person's chats (left, joined, renamed).
    _sync = personal.client.onSync.stream
        .where(
          (update) => [
            update.rooms?.join,
            update.rooms?.invite,
            update.rooms?.leave,
          ].any((rooms) => rooms?.keys.any(_roomIds.contains) == true),
        )
        .listen((_) => _changed());
    PersonalPageLoad.request(context, personal);
  }

  @override
  void dispose() {
    personal.removeListener(_changed);
    _sync.cancel();
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  /// The saved person; null once it was unmerged.
  PersonGroup? get _saved {
    for (final group in personal.groups) {
      if (group.id == widget.group.id) return group;
    }
    return null;
  }

  bool get _current =>
      mounted && identical(Matrix.of(context).client, personal.client);

  Future<void> _change(
    Future<void> Function() change, {
    String failure =
        'The change was not saved. Check private sync and try again.',
  }) async {
    if (!mounted || !_current) return;
    await runPersonChange(context, change, failure: failure);
  }

  // ---------------------------------------------------------------------
  // Name and photo.

  Future<void> _name(PersonGroup group) async {
    final projection = InboxProjection(personal);
    final entity = 'person:${group.id}';
    final nickname = projection.metadataForEntity(entity).nickname;
    final source = projection.preferencesFor(group.id).nameRoomId;
    final active = projection
        .sourcesOf(group)
        .where((s) => s.status == PersonSourceStatus.active);
    final picked = await showPersonChoiceSheet<String>(
      context,
      title: 'Name',
      message: 'Only you see this name. The chats keep their network names.',
      choices: [
        PersonChoice(
          value: 'custom',
          title: nickname == null ? 'Custom name…' : 'Edit custom name…',
          subtitle: nickname,
          leading: const Icon(Icons.edit_outlined),
          selected: nickname != null,
        ),
        for (final chat in active)
          PersonChoice(
            value: chat.member.roomId,
            title: 'Use ${personNetworkLabel(chat)} name',
            subtitle: chat.room!.getLocalizedDisplayname(),
            leading: NotionNetworkGlyph(
              network: chat.member.network,
              size: NotionSize.iconLg,
            ),
            selected: nickname == null && source == chat.member.roomId,
          ),
        PersonChoice(
          value: 'saved',
          title: 'Name saved with the merge',
          subtitle: group.name,
          leading: const Icon(Icons.bookmark_border),
          selected: nickname == null && source == null,
        ),
      ],
    );
    if (picked == null || !mounted || !_current) return;
    switch (picked) {
      case 'custom':
        final value = await showPersonTextDialog(
          context,
          title: 'Custom name',
          message: 'Leave it empty to use a network name again.',
          initial: nickname ?? projection.personName(group),
          confirmLabel: 'Save',
        );
        if (value == null || !mounted || !_current) return;
        await _change(() => setPersonNickname(personal, group, value));
      case 'saved':
        await _change(() => usePersonSavedName(personal, group));
      default:
        await _change(() => usePersonSourceName(personal, group, picked));
    }
  }

  Future<void> _photo(PersonGroup group) async {
    final projection = InboxProjection(personal);
    final entity = 'person:${group.id}';
    final chosen = personAvatarSource(
      projection.metadataForEntity(entity).avatarAsset,
    );
    final private = personal.values.containsKey(privateAvatarKey(entity));
    final photos = [
      for (final chat in projection.sourcesOf(group))
        if (chat.room?.avatar != null) chat,
    ];
    final picked = await showPersonChoiceSheet<String>(
      context,
      title: 'Photo',
      message: 'Only you see this photo. Network photos stay unchanged.',
      choices: [
        PersonChoice(
          value: 'auto',
          title: 'Automatic',
          subtitle: private
              ? 'Your own photo'
              : 'The photo of the default chat',
          leading: const Icon(Icons.auto_awesome_outlined),
          selected: chosen == null,
        ),
        for (final chat in photos)
          PersonChoice(
            value: '$personAvatarSourcePrefix${chat.member.roomId}',
            title: 'Use ${personNetworkLabel(chat)} photo',
            subtitle: chat.room!.getLocalizedDisplayname(),
            leading: Avatar(
              client: personal.client,
              mxContent: chat.room!.avatar,
              name: chat.room!.getLocalizedDisplayname(),
              size: NotionSize.iconLg,
            ),
            selected: chosen == chat.member.roomId,
          ),
        PersonChoice(
          value: 'upload',
          title: private ? 'Replace your photo…' : 'Upload your own photo…',
          subtitle:
              'Private and end-to-end encrypted. PNG, JPEG or WebP, up to 2 MB.',
          leading: const Icon(Icons.add_photo_alternate_outlined),
        ),
        if (private)
          const PersonChoice(
            value: 'remove',
            title: 'Remove your photo',
            leading: Icon(Icons.hide_image_outlined),
            destructive: true,
          ),
      ],
    );
    if (picked == null || !mounted || !_current) return;
    switch (picked) {
      case 'auto':
        await _change(() => setPersonAvatarSource(personal, group, null));
      case 'upload':
        await _change(
          () async {
            final uploaded = await pickAndUploadPrivateAvatar(personal, entity);
            if (uploaded && chosen != null) {
              await setPersonAvatarSource(personal, group, null);
            }
          },
          failure:
              'The photo was not saved. Use a PNG, JPEG or WebP image up to 2 MB and check private sync.',
        );
      case 'remove':
        await _change(() => personal.delete(privateAvatarKey(entity)));
      default:
        final roomId = personAvatarSource(picked);
        if (roomId != null) {
          await _change(() => setPersonAvatarSource(personal, group, roomId));
        }
    }
  }

  // ---------------------------------------------------------------------
  // Chats.

  Future<void> _sendVia(PersonGroup group) async {
    final projection = InboxProjection(personal);
    final routing = projection.preferencesFor(group.id).routing;
    final active = projection
        .sourcesOf(group)
        .where((s) => s.status == PersonSourceStatus.active)
        .toList();
    final fallback = active
        .where((s) => s.member.roomId == group.defaultRoomId)
        .firstOrNull;
    final picked = await showPersonChoiceSheet<String>(
      context,
      title: 'Send messages via',
      message:
          'A reply always goes back to its network. You can still pick the network of one message in the composer.',
      choices: [
        PersonChoice(
          value: 'auto',
          title: 'Automatic',
          subtitle: fallback == null
              ? 'Where they last wrote'
              : 'Where they last wrote, otherwise ${personNetworkLabel(fallback)}',
          leading: const Icon(Icons.alt_route),
          selected: routing == PersonRouting.automatic,
        ),
        for (final chat in active)
          PersonChoice(
            value: chat.member.roomId,
            title: 'Always ${personNetworkLabel(chat)}',
            subtitle: chat.room!.getLocalizedDisplayname(),
            leading: NotionNetworkGlyph(
              network: chat.member.network,
              size: NotionSize.iconLg,
            ),
            selected:
                routing == PersonRouting.fixed &&
                group.defaultRoomId == chat.member.roomId,
          ),
      ],
    );
    if (picked == null || !mounted || !_current) return;
    await _change(
      () => picked == 'auto'
          ? setPersonRouting(personal, group, PersonRouting.automatic)
          : setPersonRouting(
              personal,
              group,
              PersonRouting.fixed,
              defaultRoomId: picked,
            ),
    );
  }

  String _statusText(PersonSource chat, InboxProjection projection) =>
      switch (chat.status) {
        PersonSourceStatus.active => '',
        PersonSourceStatus.inactive =>
          chat.invited ? 'Invitation pending' : 'Left or deleted',
        PersonSourceStatus.elsewhere =>
          'Also in ${projection.personName(chat.owner!)}',
        PersonSourceStatus.unsafe => 'Now a group chat',
      };

  Future<void> _chat(PersonGroup group, PersonSource chat) async {
    final projection = InboxProjection(personal);
    final room = chat.room;
    final isDefault = group.defaultRoomId == chat.member.roomId;
    final network = personNetworkLabel(chat);
    final message = switch (chat.status) {
      PersonSourceStatus.active =>
        isDefault
            ? 'The default chat of this person.'
            : 'Messages from this chat appear in the merged chat.',
      PersonSourceStatus.inactive =>
        'This chat was left or deleted, or its network connection was set up again. It stays here and comes back when it is joined again.',
      PersonSourceStatus.elsewhere =>
        'This chat is also in ${projection.personName(chat.owner!)}, which shows it. Choose where it belongs.',
      PersonSourceStatus.unsafe =>
        'This chat is now a group chat, so this person is not shown merged. Remove it to merge the other chats again.',
    };
    final picked = await showPersonChoiceSheet<String>(
      context,
      title: room == null
          ? '$network chat'
          : '$network · ${room.getLocalizedDisplayname()}',
      message: message,
      choices: [
        if (room != null &&
            (chat.status == PersonSourceStatus.active ||
                chat.status == PersonSourceStatus.unsafe))
          const PersonChoice(
            value: 'open',
            title: 'Open chat',
            leading: Icon(Icons.chat_bubble_outline),
          ),
        if (chat.status == PersonSourceStatus.active && !isDefault)
          const PersonChoice(
            value: 'default',
            title: 'Make default',
            subtitle: 'New messages go here when nothing else decides',
            leading: Icon(Icons.star_outline),
          ),
        if (chat.status == PersonSourceStatus.active &&
            _partner(room!) != null)
          const PersonChoice(
            value: 'profile',
            title: 'View profile',
            leading: Icon(Icons.person_outline),
          ),
        if (chat.status == PersonSourceStatus.inactive)
          const PersonChoice(
            value: 'replace',
            title: 'Replace with another chat…',
            subtitle: 'For example the new chat of the same contact',
            leading: Icon(Icons.swap_horiz),
          ),
        if (chat.status == PersonSourceStatus.elsewhere)
          const PersonChoice(
            value: 'move',
            title: 'Keep it here only',
            subtitle: 'Removes it from the other merged chat',
            leading: Icon(Icons.move_down),
          ),
        PersonChoice(
          value: 'remove',
          title: chat.status == PersonSourceStatus.elsewhere
              ? 'Keep it there only'
              : 'Remove from merged chat',
          subtitle: group.members.length <= 2
              ? 'Unmerges this person; the chats stay'
              : 'The chat and its messages stay',
          leading: const Icon(Icons.remove_circle_outline),
          destructive: true,
        ),
      ],
    );
    if (picked == null || !mounted || !_current) return;
    switch (picked) {
      case 'open':
        _openChat(group, room!);
      case 'default':
        await _change(
          () => setPersonDefaultSource(personal, group, chat.member.roomId),
        );
      case 'profile':
        final profile = _partner(room!);
        if (profile != null) {
          await UserDialog.show(context: context, profile: profile);
        }
      case 'replace':
        await replacePersonSource(
          context,
          personal: personal,
          group: group,
          roomId: chat.member.roomId,
        );
      case 'move':
        await removeChatFromPerson(
          context,
          personal: personal,
          group: chat.owner!,
          roomId: chat.member.roomId,
        );
      case 'remove':
        await removeChatFromPerson(
          context,
          personal: personal,
          group: group,
          roomId: chat.member.roomId,
          onUnmerged: _leaveAfterUnmerge,
        );
    }
  }

  Profile? _partner(Room room) {
    final id = room.directChatMatrixIDForDisplay;
    if (id == null) return null;
    final user = room.getParticipants().where((u) => u.id == id).firstOrNull;
    if (user == null) return null;
    return Profile(
      userId: user.id,
      displayName: user.displayName,
      avatarUrl: user.avatarUrl,
    );
  }

  void _openChat(PersonGroup group, Room room) {
    final router = GoRouter.maybeOf(context);
    Navigator.of(context).maybePop();
    router?.go(personSourceChatLocation(group.id, room.id));
  }

  void _leaveAfterUnmerge() {
    if (!mounted) return;
    GoRouter.maybeOf(context)?.go('/rooms');
  }

  Future<void> _unmerge(PersonGroup group) async {
    if (!_current || !personal.ready) return;
    await unmergePerson(context, personal: personal, group: group);
    _leaveAfterUnmerge();
  }

  // ---------------------------------------------------------------------
  // Notifications.

  Future<void> _override(PersonGroup group, PersonSource chat) async {
    final projection = InboxProjection(personal);
    final current = projection
        .metadataForEntity(chat.member.roomId)
        .notificationMode;
    final picked = await showPersonChoiceSheet<String>(
      context,
      title: 'Notifications on ${personNetworkLabel(chat)}',
      message: 'Overrides the person’s setting for this network only.',
      choices: personNotificationChoices(
        current,
        inheritLabel: 'Same as this person',
      ),
    );
    if (picked == null || !mounted || !_current) return;
    final mode = preferenceEnum(PersonalNotificationMode.values, picked);
    if (mode == current) return;
    await _change(
      () => setPersonSourceNotificationMode(personal, chat.member.roomId, mode),
    );
  }

  String _accountRule(Room room) => switch (room.pushRuleState) {
    PushRuleState.notify => '',
    PushRuleState.mentionsOnly => 'Your Beeper account allows only mentions',
    PushRuleState.dontNotify => 'Muted in your Beeper account',
  };

  // ---------------------------------------------------------------------
  // Chat.

  Future<void> _archive(PersonGroup group, bool archived) async {
    final messenger = ScaffoldMessenger.of(context);
    final saved = await runPersonChange(
      context,
      () => setPersonArchived(personal, group, archived),
      failure: archived
          ? 'The chat was not archived. Check private sync and try again.'
          : 'The chat was not unarchived. Check private sync and try again.',
    );
    if (!saved || !archived) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Chat archived'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => unawaited(
              setPersonArchived(
                personal,
                group,
                false,
              ).catchError((Object _) {}),
            ),
          ),
        ),
      );
  }

  Future<void> _colors(PersonGroup group, ConversationMetadata metadata) async {
    final theme = await showChatThemeDialog(context, metadata.theme);
    if (theme == null || !mounted || !_current) return;
    await _change(
      () => updatePersonMetadata(
        personal,
        group,
        (current) => current.setTheme(theme),
      ),
    );
  }

  // ---------------------------------------------------------------------
  // Build.

  @override
  Widget build(BuildContext context) {
    final group = _saved;
    if (group == null) {
      return NotionScaffold(
        title: 'Person',
        onBack: () => Navigator.maybePop(context),
        body: NotionEmptyState(
          icon: Icons.call_split,
          title: 'These chats are no longer merged',
          message: 'They are back in the inbox as separate chats.',
          action: NotionButton(
            label: 'Back to chats',
            onPressed: () => context.go('/rooms'),
          ),
        ),
      );
    }
    _roomIds = {for (final m in group.members) m.roomId};
    final tokens = context.notion;
    final projection = InboxProjection.snapshot(personal);
    final entity = 'person:${group.id}';
    final sources = projection.sourcesOf(group);
    final active = [
      for (final chat in sources)
        if (chat.status == PersonSourceStatus.active) chat,
    ];
    final activeRooms = [for (final chat in active) chat.room!];
    final name = projection.personName(group);
    final metadata = projection.metadataForEntity(entity);
    final prefs = projection.preferencesFor(group.id);
    final ready = personal.ready;
    final keys = {
      'person:${group.id}',
      'org:$entity',
      'nickname:$entity',
      privateAvatarKey(entity),
      personPreferencesKey(group.id),
      for (final m in group.members) 'org:${m.roomId}',
    };
    // Changes are optimistic: an unconfirmed one is not announced (it
    // syncs in the background); only a conflict or no private sync is.
    final conflicted = keys.any(personal.conflicts.containsKey);
    final editable = ready && !conflicted;
    final defaultChat = sources
        .where((s) => s.member.roomId == group.defaultRoomId)
        .firstOrNull;
    final issue = sources
        .where((s) => s.status != PersonSourceStatus.active)
        .firstOrNull;
    final status = !ready
        ? 'Private sync is not connected. These settings can’t be changed right now.'
        : conflicted
        ? 'Changed on another device too. Resolve it in Settings › Sync.'
        : null;
    final personMode = metadata.notificationMode;
    final effective = activeRooms.isEmpty
        ? null
        : projection.notificationModeFor(
            activeRooms.firstWhere(
              (room) => room.id == group.defaultRoomId,
              orElse: () => activeRooms.first,
            ),
          );
    final overrides = [
      for (final chat in active)
        (chat, projection.metadataForEntity(chat.member.roomId).notificationMode),
    ];
    final avatar = personalConversationAvatar(
      personal,
      entityId: entity,
      avatar: projection.avatarForGroup(group),
      name: name,
      size: NotionSize.avatarLg,
    );

    final header = Padding(
      padding: const EdgeInsets.only(top: NotionSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            button: editable,
            label: 'Photo',
            child: GestureDetector(
              onTap: editable ? () => _photo(group) : null,
              child: SizedBox.square(
                dimension: NotionSize.avatarLg,
                child: avatar,
              ),
            ),
          ),
          const SizedBox(width: NotionSpace.md),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Semantics(
                  header: true,
                  child: Text(name, style: tokens.typography.heading),
                ),
                const SizedBox(height: NotionSpace.xxs),
                Wrap(
                  spacing: NotionSpace.xs,
                  runSpacing: NotionSpace.xxs,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    for (final chat in active)
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          NotionNetworkGlyph(
                            network: chat.member.network,
                            size: NotionSize.iconSm,
                          ),
                          const SizedBox(width: NotionSpace.xxs),
                          Text(
                            personNetworkLabel(chat),
                            style: tokens.typography.footnoteMuted,
                          ),
                        ],
                      ),
                    if (active.isEmpty)
                      Text(
                        'No chat is available right now',
                        style: tokens.typography.footnoteMuted,
                      ),
                  ],
                ),
                NotionSizeReveal(
                  visible: status != null,
                  child: Padding(
                    padding: const EdgeInsets.only(top: NotionSpace.xs),
                    child: Semantics(
                      liveRegion: true,
                      child: NotionFadeThrough(
                        child: Text(
                          status ?? '',
                          key: ValueKey(status),
                          style: tokens.typography.captionMuted,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    final callout = NotionSizeReveal(
      visible: issue != null,
      child: issue == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.only(top: NotionSpace.md),
              child: NotionCallout(
                icon: Icons.info_outline,
                tone: NotionCalloutTone.warning,
                title: switch (issue.status) {
                  PersonSourceStatus.inactive =>
                    'The ${personNetworkLabel(issue)} chat is no longer available',
                  PersonSourceStatus.elsewhere =>
                    'The ${personNetworkLabel(issue)} chat is in two merged chats',
                  _ =>
                    'The ${personNetworkLabel(issue)} chat is now a group chat',
                },
                message: switch (issue.status) {
                  PersonSourceStatus.inactive =>
                    'It was left or deleted. The other chats keep working. Remove it, or replace it with the new chat of this contact.',
                  PersonSourceStatus.elsewhere =>
                    'It is shown in ${projection.personName(issue.owner!)}. This can happen when two devices merge at the same time.',
                  _ =>
                    'A group chat can’t be part of a person, so these chats are shown separately until it is removed.',
                },
                actionLabel: editable ? 'Review' : null,
                onAction: editable ? () => _chat(group, issue) : null,
              ),
            ),
    );

    final chats = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NotionSectionHeader(title: 'Chats'),
        for (final chat in sources)
          NotionListRow(
            key: ValueKey(('chat', chat.member.roomId)),
            leading: NotionNetworkGlyph(
              network: chat.member.network,
              size: NotionSize.iconLg,
            ),
            title: personNetworkLabel(chat),
            subtitle: [
              chat.room?.getLocalizedDisplayname() ?? 'Chat no longer available',
              if (chat.status == PersonSourceStatus.active && chat.room != null)
                ?personSourceActivity(context, chat.room!),
            ].join(' · '),
            trailing: chat.status != PersonSourceStatus.active
                ? NotionStatusPill(
                    label: _statusText(chat, projection),
                    tone: NotionStatusTone.warning,
                  )
                : chat.member.roomId == group.defaultRoomId
                ? const NotionStatusPill(label: 'Default')
                : null,
            onTap: editable ? () => _chat(group, chat) : null,
          ),
        NotionListRow(
          leading: const Icon(Icons.add),
          title: 'Add chat…',
          subtitle: 'Another network of this person',
          onTap: editable
              ? () => addChatsToPerson(
                  context,
                  personal: personal,
                  group: group,
                )
              : null,
        ),
        NotionListRow(
          leading: const Icon(Icons.alt_route),
          title: 'Send messages via',
          subtitle: prefs.routing == PersonRouting.automatic
              ? defaultChat == null
                    ? 'Automatic · where they last wrote'
                    : 'Automatic · where they last wrote, otherwise ${personNetworkLabel(defaultChat)}'
              : defaultChat == null
              ? 'The default chat'
              : 'Always ${personNetworkLabel(defaultChat)}',
          onTap: editable && active.isNotEmpty ? () => _sendVia(group) : null,
        ),
      ],
    );

    final identity = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NotionSectionHeader(title: 'Name and photo'),
        NotionListRow(
          leading: const Icon(Icons.badge_outlined),
          title: 'Name',
          subtitle: metadata.nickname != null
              ? 'Custom · $name'
              : prefs.nameRoomId != null &&
                    group.members.any((m) => m.roomId == prefs.nameRoomId)
              ? 'From ${notionNetworkLabel(group.members.firstWhere((m) => m.roomId == prefs.nameRoomId).network)} · $name'
              : 'Saved with the merge · $name',
          onTap: editable ? () => _name(group) : null,
        ),
        NotionListRow(
          leading: const Icon(Icons.account_circle_outlined),
          title: 'Photo',
          subtitle: switch (personAvatarSource(metadata.avatarAsset)) {
            final String roomId
                when group.members.any((m) => m.roomId == roomId) =>
              'From ${notionNetworkLabel(group.members.firstWhere((m) => m.roomId == roomId).network)}',
            _ when privateAvatarShown(personal, entity) => 'Your own photo',
            _ => 'Automatic',
          },
          onTap: editable ? () => _photo(group) : null,
        ),
      ],
    );

    final notifications = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NotionSectionHeader(title: 'Notifications'),
        NotionListRow(
          leading: const Icon(Icons.notifications_none_outlined),
          title: 'Notifications',
          subtitle: personMode != null
              ? '${privateNotificationLabel(personMode)} · every network'
              : effective == null
              ? 'Network default'
              : 'Network default · ${privateNotificationLabel(effective)}',
          onTap: editable
              ? () => showPersonNotificationsSheet(
                  context,
                  personal: personal,
                  group: group,
                )
              : null,
        ),
        if (active.length > 1 || overrides.any((o) => o.$2 != null))
          for (final (chat, mode) in overrides)
            NotionListRow(
              key: ValueKey(('override', chat.member.roomId)),
              leading: NotionNetworkGlyph(
                network: chat.member.network,
                size: NotionSize.iconMd,
              ),
              title: 'On ${personNetworkLabel(chat)}',
              subtitle: [
                mode == null
                    ? 'Same as this person'
                    : 'Override · ${privateNotificationLabel(mode)}',
                if (_accountRule(chat.room!).isNotEmpty)
                  _accountRule(chat.room!),
              ].join(' · '),
              onTap: editable ? () => _override(group, chat) : null,
            ),
        if (activeRooms.isNotEmpty)
          NotionListRow(
            leading: const Icon(Icons.tune),
            title: 'Transcription and other rules',
            subtitle: 'Per network',
            onTap: () => Navigator.of(context).push<void>(
              MaterialPageRoute(
                builder: (_) => ChatPreferencesPage(
                  personal: personal,
                  room: activeRooms.first,
                ),
              ),
            ),
          ),
      ],
    );

    final shared = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NotionSectionHeader(title: 'Shared content'),
        NotionListRow(
          leading: const Icon(Icons.search_outlined),
          title: 'Search messages',
          subtitle: 'Across every network of this person',
          onTap: activeRooms.isEmpty
              ? null
              : () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => NotionConversationContentPage(
                      rooms: activeRooms,
                      name: name,
                    ),
                  ),
                ),
        ),
        NotionListRow(
          leading: const Icon(Icons.image_outlined),
          title: 'Media, files & links',
          onTap: activeRooms.isEmpty
              ? null
              : () => Navigator.of(context).push<void>(
                  MaterialPageRoute(
                    builder: (_) => NotionConversationContentPage(
                      rooms: activeRooms,
                      name: name,
                      initialMedia: true,
                    ),
                  ),
                ),
        ),
        if (activeRooms.isNotEmpty) NotionLocalSharedPreview(rooms: activeRooms),
      ],
    );

    final chat = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const NotionSectionHeader(title: 'Chat'),
        NotionSettingsToggle(
          title: 'Pin chat',
          value: metadata.isPinned,
          onChanged: editable
              ? (value) => _change(() => setPersonPinned(personal, group, value))
              : null,
        ),
        NotionSettingsToggle(
          title: 'Low priority',
          subtitle:
              'Outside the inbox. Mentions and thread replies may still notify.',
          value: metadata.lowPriority,
          onChanged: editable
              ? (value) => _change(
                  () => updatePersonMetadata(
                    personal,
                    group,
                    (current) => current.setLowPriority(value),
                  ),
                )
              : null,
        ),
        NotionSettingsToggle(
          title: 'Ignore chat',
          subtitle: 'Only in Ignored. No notifications, including mentions.',
          value: metadata.ignored || metadata.placement == ChatPlacement.ignored,
          onChanged: editable
              ? (value) => _change(
                  () => updatePersonMetadata(
                    personal,
                    group,
                    (current) => value
                        ? current.setIgnored(true)
                        : current.restoreIgnored(),
                  ),
                )
              : null,
        ),
        NotionListRow(
          leading: const Icon(Icons.archive_outlined),
          title: metadata.archived ? 'Unarchive chat' : 'Archive chat',
          subtitle: 'Private archive · new activity brings it back',
          onTap: editable ? () => _archive(group, !metadata.archived) : null,
        ),
        NotionListRow(
          leading: const Icon(Icons.palette_outlined),
          title: 'Chat colors',
          subtitle: metadata.theme == null ? 'App colors' : 'Custom colors',
          onTap: editable ? () => _colors(group, metadata) : null,
        ),
        if (metadata.theme != null)
          NotionListRow(
            leading: const Icon(Icons.format_color_reset_outlined),
            title: 'Restore default colors',
            onTap: editable
                ? () => _change(
                    () => updatePersonMetadata(
                      personal,
                      group,
                      (current) => current.setTheme(null),
                    ),
                  )
                : null,
          ),
        const SizedBox(height: NotionSpace.md),
        NotionListRow(
          leading: Icon(Icons.call_split, color: tokens.colors.danger),
          title: 'Unmerge',
          subtitle:
              'The chats return to the inbox separately. Messages are kept.',
          onTap: ready ? () => _unmerge(group) : null,
        ),
      ],
    );

    return NotionScaffold(
      title: 'Person',
      onBack: () => Navigator.maybePop(context),
      scrollKey: const PageStorageKey('person-page'),
      children: NotionEntrance.stagger([
        header,
        callout,
        chats,
        identity,
        notifications,
        shared,
        chat,
      ]),
    );
  }
}
