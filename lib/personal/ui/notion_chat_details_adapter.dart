// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/pages/chat_details/chat_details.dart';
import 'package:fluffychat/pages/chat_details/participant_list_item.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/organization_page.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/personal_hub.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_content.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_notifications.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_page.dart';
import 'package:fluffychat/ui/notion/metadata_actions.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/user_dialog.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:fluffychat/widgets/mxc_image_viewer.dart';
import 'package:fluffychat/widgets/qr_code_viewer.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

Future<void> showNotionMergedChatDetails(
  BuildContext context, {
  required PersonalClient personal,
  required PersonGroup group,
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (_) => NotionLiveChatDetails(personal: personal, group: group),
  ),
);

String notionNotificationLabel(PushRuleState state) => switch (state) {
  PushRuleState.notify => 'All messages',
  PushRuleState.mentionsOnly => 'Mentions only',
  PushRuleState.dontNotify => 'Muted',
};
String? _text(Object? value) => value is String ? value : null;
String notionNetworkName(String network) => switch (network.toLowerCase()) {
  'whatsapp' => 'WhatsApp',
  'telegram' => 'Telegram',
  'slack' => 'Slack',
  'discord' => 'Discord',
  'signal' => 'Signal',
  'instagram' => 'Instagram',
  'facebook' || 'messenger' => 'Messenger',
  'matrix' => 'Matrix',
  'unknown' => 'Unknown network',
  _ =>
    network.isEmpty
        ? 'Unknown network'
        : '${network[0].toUpperCase()}${network.substring(1)}',
};

/// Source and person scopes are explicit. A merged page never runs a native
/// room action on its representative room on behalf of the person.
class NotionLiveChatDetails extends StatefulWidget {
  final PersonalClient personal;
  final Room? room;
  final PersonGroup? group;
  final ChatDetailsController? controller;
  const NotionLiveChatDetails({
    super.key,
    required this.personal,
    this.room,
    this.group,
    this.controller,
  }) : assert((room == null) != (group == null));
  @override
  State<NotionLiveChatDetails> createState() => _NotionLiveChatDetailsState();
}

class _NotionLiveChatDetailsState extends State<NotionLiveChatDetails> {
  bool _busy = false;
  NotionNotificationBinding<PushRuleState>? _native;
  String? _status;
  late final StreamSubscription _sync;
  late final StreamSubscription _roomState;
  PersonalClient get personal => widget.personal;
  InboxProjection get projection => InboxProjection(personal);
  String get entity => widget.group == null
      ? projection.entityFor(widget.room!)
      : 'person:${widget.group!.id}';
  PersonGroup? get currentGroup {
    final original = widget.group;
    if (original == null) return null;
    for (final member in original.members) {
      final room = personal.client.getRoomById(member.roomId);
      if (room == null) continue;
      final current = projection.groupFor(room);
      if (current?.id == original.id) return current;
    }
    return null;
  }

  List<Room> get sources => widget.group == null
      ? [widget.room!]
      : (currentGroup ?? widget.group!).members
            .map((member) => personal.client.getRoomById(member.roomId))
            .whereType<Room>()
            .where((room) => room.membership == Membership.join)
            .toList();
  @override
  void initState() {
    super.initState();
    final room = widget.room;
    if (room != null) {
      _native = NotionNotificationBinding(
        read: () => room.pushRuleState,
        write: room.setPushRuleState,
      )..addListener(_refresh);
    }
    personal.addListener(_refresh);
    _sync = personal.client.onSync.stream.listen((_) => _refresh());
    _roomState = personal.client.onRoomState.stream.listen((_) => _refresh());
    personal.load();
  }

  void _refresh() {
    _native?.refresh();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    personal.removeListener(_refresh);
    _sync.cancel();
    _roomState.cancel();
    _native?.removeListener(_refresh);
    _native?.dispose();
    super.dispose();
  }

  Future<void> _run(
    Future<void> Function() action, {
    String failure =
        'Could not save the change. Check the connection and try again.',
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = null;
    });
    try {
      await action();
    } catch (_) {
      if (mounted) setState(() => _status = failure);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _hub() async {
    await Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => PersonalHub(client: personal.client)),
    );
    _refresh();
  }

  Future<void> _organize() async {
    final room = sources.firstOrNull;
    if (room == null) return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) => OrganizationPage(personal: personal, room: room),
      ),
    );
    _refresh();
  }

  Future<void> _nickname() async {
    final metadata = projection.metadataForEntity(entity);
    final editEntity = entity;
    final input = await showTextInputDialog(
      context: context,
      title: 'Private nickname',
      message:
          'Only your private preferences change. The network room name stays the same. Leave blank to restore its name.',
      initialText:
          metadata.nickname ??
          _text(personal.values['nickname:$entity']?['name']) ??
          '',
      okLabel: 'Save',
      cancelLabel: 'Cancel',
    );
    if (input == null || !mounted) return;
    await _run(
      () async {
        if (entity != editEntity ||
            (widget.group != null && currentGroup == null) ||
            !NotionMetadataActions.canEdit(personal, editEntity))
          throw StateError(
            'Conversation scope changed or private changes pending',
          );
        final value = input.trim().isEmpty ? null : input.trim();
        final current = projection.metadataForEntity(entity);
        await personal.put(
          'org:$entity',
          {
            ...?personal.values['org:$entity'],
            ...current.setNickname(value).toJson(),
          }.cast<String, dynamic>(),
        );
        await personal.put('nickname:$entity', {'name': value ?? ''});
      },
      failure:
          'Could not save the private nickname. Check private sync and try again.',
    );
  }

  Future<void> _archive() async {
    final archiveEntity = entity;
    final confirmed = await showOkCancelAlertDialog(
      context: context,
      title: 'Archive this chat?',
      message:
          'This hides it from your private inbox and keeps the conversation history. New activity can reopen it.',
      okLabel: 'Archive',
      cancelLabel: 'Cancel',
    );
    if (confirmed != OkCancelResult.ok || !mounted) return;
    await _run(
      () async {
        if (entity != archiveEntity ||
            (widget.group != null && currentGroup == null) ||
            !NotionMetadataActions.canEdit(personal, archiveEntity))
          throw StateError(
            'Conversation scope changed or private changes pending',
          );
        final metadata = projection.metadataForEntity(entity).setArchived(true);
        await personal.put(
          'org:$entity',
          {
            ...?personal.values['org:$entity'],
            ...metadata.toJson(),
            'archivedAt': DateTime.now().toUtc().toIso8601String(),
            'archiveSources': {
              for (final room in sources) room.id: room.lastEvent?.eventId,
            },
          }.cast<String, dynamic>(),
        );
      },
      failure: 'Could not archive this chat. Check private sync and try again.',
    );
  }

  Future<void> _notifications(Room room) async {
    final state = await showDialog<PushRuleState>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Notifications for this source'),
        children: [
          for (final value in PushRuleState.values)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, value),
              child: Row(
                children: [
                  Expanded(child: Text(notionNotificationLabel(value))),
                  if (value == room.pushRuleState)
                    const Icon(Icons.check, size: 20),
                ],
              ),
            ),
        ],
      ),
    );
    if (state == null || !mounted) return;
    await _writeNotifications(room, state);
  }

  Future<void> _writeNotifications(Room room, PushRuleState value) async {
    await _native?.set(value);
  }

  Future<void> _contact(Room room) async {
    if (Matrix.of(context).client.userID != room.client.userID) {
      await _sourceDetails(room);
      return;
    }
    final id = room.directChatMatrixID;
    if (id == null) {
      await context.push('/rooms/${room.id}/details/members');
      return;
    }
    final user = room.getParticipants().where((u) => u.id == id).firstOrNull;
    if (user == null) {
      await context.push('/rooms/${room.id}/details/members');
      return;
    }
    await UserDialog.show(
      context: context,
      profile: Profile(
        userId: user.id,
        displayName: user.displayName,
        avatarUrl: user.avatarUrl,
      ),
    );
  }

  Future<void> _sources({bool contact = false}) => showModalBottomSheet<void>(
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
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Choose a source', style: NotionTokens.heading),
                const SizedBox(height: 8),
                const Text(
                  'Network settings apply only to the selected source.',
                ),
                if (sources.isEmpty)
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      'No current sources are available. Their network settings cannot be changed.',
                    ),
                  ),
                for (final source in sources)
                  NotionListRow(
                    leading: const Icon(Icons.language_outlined),
                    title: notionNetworkName(PersonalClient.networkOf(source)),
                    subtitle: source.getLocalizedDisplayname(),
                    onTap: () {
                      Navigator.pop(context);
                      if (contact) {
                        _contact(source);
                      } else {
                        _sourceDetails(source);
                      }
                    },
                  ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
  Future<void> _sourceDetails(Room source) => Navigator.of(context).push<void>(
    MaterialPageRoute(builder: (_) => _SourceDetailsPage(room: source)),
  );
  Future<void> _overflow() async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                NotionListRow(
                  leading: const Icon(Icons.tune_outlined),
                  title: 'Private organization & avatar',
                  subtitle: 'Labels, private appearance and archive',
                  onTap: () {
                    Navigator.pop(context);
                    _organize();
                  },
                ),
                NotionListRow(
                  leading: const Icon(Icons.sync_outlined),
                  title: 'Private tools & sync',
                  onTap: () {
                    Navigator.pop(context);
                    _hub();
                  },
                ),
                if (widget.group != null)
                  NotionListRow(
                    leading: const Icon(Icons.language_outlined),
                    title: 'Source settings',
                    onTap: () {
                      Navigator.pop(context);
                      _sources();
                    },
                  ),
                if (widget.room != null) ...[
                  if (widget.room!.canonicalAlias.isNotEmpty ||
                      widget.room!.directChatMatrixID != null)
                    NotionListRow(
                      leading: const Icon(Icons.qr_code_outlined),
                      title: 'Share contact',
                      onTap: () {
                        Navigator.pop(context);
                        showQrCodeViewer(
                          this.context,
                          widget.room!.canonicalAlias.isNotEmpty
                              ? widget.room!.canonicalAlias
                              : widget.room!.directChatMatrixID!,
                        );
                      },
                    ),
                  NotionListRow(
                    leading: const Icon(Icons.logout_outlined),
                    title: 'Leave this source',
                    subtitle: 'Changes your membership on the network',
                    onTap: () {
                      Navigator.pop(context);
                      _leave(widget.room!);
                    },
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _leave(Room room) async {
    final confirmed = await showOkCancelAlertDialog(
      context: context,
      title: 'Leave this source?',
      message:
          'This changes your membership on this network. Private archive does not leave the room.',
      isDestructive: true,
      okLabel: 'Leave',
      cancelLabel: 'Cancel',
    );
    if (confirmed != OkCancelResult.ok || !mounted) return;
    await _run(() async {
      await room.leave();
      if (mounted) context.go('/rooms');
    });
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final group = currentGroup ?? widget.group;
    final metadata = projection.metadataForEntity(entity);
    final waiting = personal.pending.values.any(
      (op) => op.entityId == 'org:$entity' || op.entityId == 'nickname:$entity',
    );
    final mergedValid = widget.group == null || currentGroup != null;
    final canEdit =
        mergedValid &&
        !_busy &&
        !waiting &&
        NotionMetadataActions.canEdit(personal, entity);
    final labelKeys = room == null
        ? metadata.labelIds
        : projection.labelsFor(room);
    final labels = labelKeys
        .map((key) => personal.values[key]?['name'])
        .whereType<String>()
        .toList();
    final name =
        metadata.nickname ??
        _text(personal.values['nickname:$entity']?['name']) ??
        group?.name ??
        room!.getLocalizedDisplayname();
    final network = group == null
        ? notionNetworkName(PersonalClient.networkOf(room!))
        : group.members
              .map((m) => notionNetworkName(m.network))
              .toSet()
              .join(' · ');
    final sourceRows = <Widget>[
      if (group != null) ...[
        const Text(
          'Each source has its own notifications, encryption and membership.',
          style: TextStyle(fontSize: 13),
        ),
        for (final source in sources)
          NotionListRow(
            leading: const Icon(Icons.language_outlined),
            title: notionNetworkName(PersonalClient.networkOf(source)),
            subtitle:
                '${source.getLocalizedDisplayname()} · ${notionNotificationLabel(source.pushRuleState)}',
            onTap: () => _sourceDetails(source),
          ),
        if (sources.length != group.members.length)
          const Text(
            'Some sources are unavailable. Their settings cannot be changed.',
          ),
      ],
      if (room != null) ...[
        NotionListRow(
          leading: const Icon(Icons.lock_outline),
          title: 'Encryption & recovery',
          subtitle: room.encrypted
              ? 'Matrix transport encrypted · the source-network hop has its own security'
              : 'Matrix transport is not encrypted · the source-network hop has its own security',
          onTap: () => context.push('/rooms/${room.id}/encryption'),
        ),
        if (!room.isDirectChat) ...[
          NotionListRow(
            leading: const Icon(Icons.visibility_outlined),
            title: 'Access & visibility',
            onTap: () => context.push('/rooms/${room.id}/details/access'),
          ),
          NotionListRow(
            leading: const Icon(Icons.admin_panel_settings_outlined),
            title: 'Permissions',
            onTap: () => context.push('/rooms/${room.id}/details/permissions'),
          ),
          if (room.canInvite)
            NotionListRow(
              leading: const Icon(Icons.person_add_outlined),
              title: 'Invite to this source',
              onTap: () => context.push('/rooms/${room.id}/invite'),
            ),
        ],
        NotionListRow(
          leading: const Icon(Icons.emoji_emotions_outlined),
          title: 'Stickers & emotes',
          onTap: () => context.push('/rooms/${room.id}/details/emotes'),
        ),
        if (room.topic.isNotEmpty ||
            room.canChangeStateEvent(EventTypes.RoomTopic))
          NotionListRow(
            leading: const Icon(Icons.description_outlined),
            title: 'Network description',
            subtitle: room.topic.isEmpty ? 'No description' : room.topic,
            onTap: room.canChangeStateEvent(EventTypes.RoomTopic)
                ? widget.controller?.setTopicAction
                : null,
          ),
        if (!room.isDirectChat && room.canChangeStateEvent(EventTypes.RoomName))
          NotionListRow(
            leading: const Icon(Icons.edit_outlined),
            title: 'Rename network room',
            subtitle: 'Changes the name for everyone on this source',
            onTap: widget.controller?.setDisplaynameAction,
          ),
        if (!room.isDirectChat &&
            room.canChangeStateEvent(EventTypes.RoomAvatar))
          NotionListRow(
            leading: const Icon(Icons.photo_camera_outlined),
            title: 'Change network room avatar',
            subtitle: 'Visible to everyone on this source',
            onTap: widget.controller?.setAvatarAction,
          ),
        NotionListRow(
          leading: const Icon(Icons.people_outline),
          title: 'Participants',
          onTap: () => context.push('/rooms/${room.id}/details/members'),
        ),
        ...room.getParticipants().take(10).map(ParticipantListItem.new),
      ],
    ];
    return NotionChatDetailsPage(
      leading: widget.controller?.widget.embeddedCloseButton,
      data: NotionConversationDetailsData(
        name: name.trim().isEmpty
            ? group?.name ?? room?.getLocalizedDisplayname() ?? 'Conversation'
            : name,
        network: network,
        avatar: PrivateAvatarPreview(
          personal: personal,
          entityId: entity,
          radius: 32,
          fallback: Avatar(
            client: personal.client,
            mxContent: room?.avatar,
            name: name,
            size: 64,
            onTap: room?.avatar == null
                ? null
                : () => showDialog(
                    context: context,
                    builder: (_) => MxcImageViewer(room!.avatar!),
                  ),
          ),
        ),
        label: labels.isEmpty ? null : labels.join(', '),
        nickname: metadata.nickname,
        notifications: room == null
            ? 'Choose a source'
            : notionNotificationLabel(room.pushRuleState),
        pinned: metadata.pinOrder != null,
        incognito: AppSettings.personalIncognito.value,
        pending: _busy || waiting,
        status:
            _native?.status ??
            _status ??
            (!mergedValid
                ? 'These merged sources have changed. Private edits are unavailable; review each current source.'
                : waiting
                ? 'Private changes are awaiting synchronization.'
                : !personal.ready
                ? 'Private sync is not connected. Network settings remain available.'
                : null),
        sharedContent: NotionLocalSharedPreview(rooms: sources),
        sourceRows: sourceRows,
      ),
      actions: NotionConversationDetailsActions(
        search: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) =>
                NotionConversationContentPage(rooms: sources, name: name),
          ),
        ),
        mute: room == null
            ? _sources
            : _native?.canEdit != true
            ? null
            : () => _writeNotifications(
                room,
                room.pushRuleState == PushRuleState.dontNotify
                    ? PushRuleState.notify
                    : PushRuleState.dontNotify,
              ),
        notifications: room == null
            ? _sources
            : _native?.canEdit != true
            ? null
            : () => _notifications(room),
        pin: canEdit
            ? (value) => _run(
                () => NotionMetadataActions.setPinned(personal, entity, value),
                failure:
                    'Could not change the pin. Check private sync and try again.',
              )
            : null,
        privacy: () async {
          await context.push('/rooms/settings');
          _refresh();
        },
        appearance: canEdit ? _organize : null,
        nickname: canEdit ? _nickname : null,
        media: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) => NotionConversationContentPage(
              rooms: sources,
              name: name,
              initialMedia: true,
            ),
          ),
        ),
        archive: canEdit ? _archive : null,
        contact: room == null
            ? () => _sources(contact: true)
            : () => _contact(room),
        overflow: _overflow,
      ),
    );
  }
}

/// Ties source details to the originating account after an account switch.
class _SourceDetailsPage extends StatelessWidget {
  final Room room;
  const _SourceDetailsPage({required this.room});
  @override
  Widget build(BuildContext context) {
    final active = Matrix.of(context).client;
    if (room.client.userID != null &&
        active.userID == room.client.userID &&
        active.getRoomById(room.id) != null)
      return ChatDetails(roomId: room.id);
    return Scaffold(
      appBar: AppBar(title: const Text('Source settings')),
      body: const Center(
        child: Padding(
          padding: EdgeInsets.all(20),
          child: Text(
            'This source is unavailable in the current account. Its network settings have not been changed.',
          ),
        ),
      ),
    );
  }
}
