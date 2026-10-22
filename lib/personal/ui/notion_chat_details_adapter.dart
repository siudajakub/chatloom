// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat_details/chat_details.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/organization_page.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/round_video/round_availability.dart';
import 'package:chatloom/personal/ui/chat_preferences_page.dart';
import 'package:chatloom/personal/ui/notion_chat_details_content.dart';
import 'package:chatloom/personal/ui/notion_chat_details_notifications.dart';
import 'package:chatloom/personal/ui/notion_chat_details_page.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:chatloom/personal/ui/notion_settings_load.dart';
import 'package:chatloom/personal/ui/person_page.dart';
import 'package:chatloom/ui/notion/metadata_actions.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_text_input_dialog.dart';
import 'package:chatloom/widgets/adaptive_dialogs/user_dialog.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:chatloom/widgets/mxc_image_viewer.dart';
import 'package:chatloom/widgets/qr_code_viewer.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// Details of a merged person: the one person page (name, photo, chats,
/// routing, notifications, unmerge), never native per-source pages.
Future<void> showNotionMergedChatDetails(
  BuildContext context, {
  required PersonalClient personal,
  required PersonGroup group,
}) => showPersonPage(context, personal: personal, group: group);

String notionNotificationLabel(PushRuleState state) => switch (state) {
  PushRuleState.notify => 'All messages',
  PushRuleState.mentionsOnly => 'Mentions only',
  PushRuleState.dontNotify => 'Muted',
};
String? _text(Object? value) => value is String ? value : null;
String notionNetworkName(String network) => notionNetworkLabel(network);

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
  Timer? _refreshTimer;
  Set<String> _observedSourceIds = {};
  PersonalClient get personal => widget.personal;
  InboxProjection get projection => InboxProjection(personal);
  String get entity => widget.group == null
      ? projection.entityFor(widget.room!)
      : 'person:${widget.group!.id}';
  PersonGroup? get currentGroup => _currentGroup(projection);
  PersonGroup? _currentGroup(InboxProjection projection) {
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
    _observedSourceIds = {
      if (widget.room != null) widget.room!.id,
      ...?widget.group?.members.map((member) => member.roomId),
    };
    final room = widget.room;
    if (room != null) {
      _native = NotionNotificationBinding(
        read: () => room.pushRuleState,
        write: room.setPushRuleState,
      )..addListener(_refresh);
    }
    personal.addListener(_refresh);
    _sync = personal.client.onSync.stream
        .where(_affectsDetails)
        .listen((_) => _refresh());
    _roomState = personal.client.onRoomState.stream
        .where((update) => _observedSourceIds.contains(update.roomId))
        .listen((_) => _refresh());
    // The profile renders from local state; revalidate private sync after
    // the page slid in, and not again right after another page did.
    PersonalPageLoad.request(context, personal);
  }

  void _refresh() {
    _native?.refresh();
    if (!mounted || _refreshTimer != null) return;
    // Matrix emits one room-state event per state key during a sync. Coalesce
    // that burst, rather than rebuilding the complete profile for each event.
    _refreshTimer = Timer(const Duration(milliseconds: 16), () {
      _refreshTimer = null;
      if (mounted) setState(() {});
    });
  }

  bool _affectsDetails(SyncUpdate update) {
    if (update.accountData?.any(
          (event) => event.type == 'm.push_rules' || event.type == 'm.direct',
        ) ==
        true)
      return true;
    final ids = _observedSourceIds;
    return [
      update.rooms?.join,
      update.rooms?.invite,
      update.rooms?.leave,
    ].any((rooms) => rooms?.keys.any(ids.contains) == true);
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
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

  /// Whether round videos can be recorded here, and why not.
  Widget _roundVideoRow(Room room) {
    final availability = RoundAvailability.of(room);
    final reason = availability.reason;
    final hint = availability.hint;
    return NotionListRow(
      leading: const Icon(Icons.radio_button_checked_outlined),
      title: 'Round video',
      subtitle: [reason ?? 'Available', ?hint].join(' · '),
    );
  }

  Future<void> _hub() async {
    await context.push('/rooms/settings/sync');
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

  /// Archiving is private and reversible: it applies at once with Undo in a
  /// snackbar (no confirmation, CS-16).
  Future<void> _archive() async {
    final archiveEntity = entity;
    final archiveSources = sources;
    final messenger = ScaffoldMessenger.of(context);
    var archived = false;
    await _run(
      () async {
        if (entity != archiveEntity ||
            (widget.group != null && currentGroup == null) ||
            !NotionMetadataActions.canEdit(personal, archiveEntity)) {
          throw StateError(
            'Conversation scope changed or private changes pending',
          );
        }
        await NotionMetadataActions.setArchived(
          personal,
          archiveEntity,
          true,
          sources: archiveSources,
        );
        archived = true;
      },
      failure: 'Could not archive this chat. Check private sync and try again.',
    );
    if (!archived) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: const Text('Chat archived'),
          action: SnackBarAction(
            label: 'Undo',
            onPressed: () => NotionMetadataActions.setArchived(
              personal,
              archiveEntity,
              false,
              sources: archiveSources,
            ).catchError((Object _) {
              messenger.showSnackBar(
                const SnackBar(
                  content: Text(
                    'Couldn’t move the chat back. Check private sync and try again.',
                  ),
                ),
              );
            }),
          ),
        ),
      );
  }

  Future<void> _privatePreferences() async {
    final available = sources;
    if (available.isEmpty ||
        !identical(Matrix.of(context).client, personal.client))
      return;
    await Navigator.of(context).push<void>(
      MaterialPageRoute(
        builder: (_) =>
            ChatPreferencesPage(personal: personal, room: available.first),
      ),
    );
  }

  Future<void> _notifications(Room room) async {
    final state = await showNotionCustomDialog<PushRuleState>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Account notifications · Beeper / Matrix'),
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
    final id = room.directChatMatrixIDForDisplay;
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
    sheetAnimationStyle: NotionMotion.sheetStyleOf(context),
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
              children: NotionEntrance.stagger(afterRoute: false, [
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
                    title: notionNetworkName(
                      projection.classifier.classify(source).network,
                    ),
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
              ]),
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
      sheetAnimationStyle: NotionMotion.sheetStyleOf(context),
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: NotionEntrance.stagger(afterRoute: false, [
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
                // Only a native Matrix chat has an address worth sharing; a
                // bridged DM's ID is the network's ghost account (CS-25).
                if (widget.room != null &&
                    projection.classifier.classify(widget.room!).network ==
                        'matrix') ...[
                  if (widget.room!.canonicalAlias.isNotEmpty ||
                      widget.room!.directChatMatrixIDForDisplay != null)
                    NotionListRow(
                      leading: const Icon(Icons.qr_code_outlined),
                      title: 'Share contact',
                      onTap: () {
                        Navigator.pop(context);
                        showQrCodeViewer(
                          this.context,
                          widget.room!.canonicalAlias.isNotEmpty
                              ? widget.room!.canonicalAlias
                              : widget.room!.directChatMatrixIDForDisplay!,
                        );
                      },
                    ),
                ],
              ]),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _leave(Room room) async {
    final confirmed = await showOkCancelAlertDialog(
      context: context,
      title: 'Leave this chat?',
      message:
          'You leave it on the network too. To only hide it here, archive it instead.',
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
    // One synchronous presentation pass; action callbacks retain live getters.
    final projection = InboxProjection.snapshot(personal);
    final activeGroup = _currentGroup(projection);
    final group = activeGroup ?? widget.group;
    final entity = widget.group == null
        ? projection.entityFor(room!)
        : 'person:${widget.group!.id}';
    final sourceRooms = room != null
        ? [room]
        : group!.members
              .map((member) => personal.client.getRoomById(member.roomId))
              .whereType<Room>()
              .where((source) => source.membership == Membership.join)
              .toList();
    _observedSourceIds = {
      if (room != null) room.id,
      ...?group?.members.map((member) => member.roomId),
    };
    final metadata = projection.metadataForEntity(entity);
    final waiting = personal.pending.values.any(
      (op) => op.entityId == 'org:$entity' || op.entityId == 'nickname:$entity',
    );
    final mergedValid = widget.group == null || activeGroup != null;
    final canEdit =
        mergedValid &&
        !_busy &&
        !waiting &&
        NotionMetadataActions.canEdit(personal, entity);
    final name =
        metadata.nickname ??
        _text(personal.values['nickname:$entity']?['name']) ??
        group?.name ??
        room!.getLocalizedDisplayname();
    final network = group == null
        ? notionNetworkName(projection.classifier.classify(room!).network)
        : sourceRooms
              .map(
                (source) => notionNetworkName(
                  projection.classifier.classify(source).network,
                ),
              )
              .toSet()
              .join(' · ');
    final sourceRows = <Widget>[
      if (group != null) ...[
        const Text(
          'Each source has its own notifications, encryption and membership.',
          style: TextStyle(fontSize: 13),
        ),
        for (final source in sourceRooms)
          NotionListRow(
            leading: const Icon(Icons.language_outlined),
            title: notionNetworkName(
              projection.classifier.classify(source).network,
            ),
            subtitle:
                '${source.getLocalizedDisplayname()} · ${notionNotificationLabel(source.pushRuleState)}',
            onTap: () => _sourceDetails(source),
          ),
        if (sourceRooms.length != group.members.length)
          const Text(
            'Some sources are unavailable. Their settings cannot be changed.',
          ),
      ],
      if (room != null) ...[
        NotionListRow(
          leading: const Icon(Icons.notifications_outlined),
          title: 'Account notifications · Beeper / Matrix',
          subtitle:
              '${notionNotificationLabel(room.pushRuleState)} · changes affect other clients',
          onTap: _native?.canEdit == true ? () => _notifications(room) : null,
        ),
        NotionListRow(
          leading: const Icon(Icons.info_outline),
          title: 'Conversation capabilities',
          onTap: () => showNotionCustomDialog<void>(
            context: context,
            builder: (context) => AlertDialog(
              title: const Text('Conversation capabilities'),
              content: SizedBox(
                width: 460,
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final feature in BridgeFeature.values)
                      ListTile(
                        title: Text(feature.name),
                        subtitle: Text(
                          RoomCapabilities.forFeature(feature, room).reason,
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Close'),
                ),
              ],
            ),
          ),
        ),
        if (PlatformInfos.isAndroid &&
            PersonalClient.networkOf(room) == 'telegram')
          _roundVideoRow(room),
        NotionListRow(
          leading: const Icon(Icons.lock_outline),
          title: 'Encryption & recovery',
          subtitle: room.encrypted
              ? 'Encrypted up to Beeper · the network has its own security'
              : 'Not encrypted up to Beeper · the network has its own security',
          onTap: () => context.push('/rooms/${room.id}/encryption'),
        ),
        if (!room.isDirectChatForDisplay) ...[
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
              title: 'Invite to this chat',
              onTap: () => context.push('/rooms/${room.id}/invite'),
            ),
        ],
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
        if (!room.isDirectChatForDisplay &&
            room.canChangeStateEvent(EventTypes.RoomName))
          NotionListRow(
            leading: const Icon(Icons.edit_outlined),
            title: 'Rename group',
            subtitle: 'Changes the name for everyone on the network',
            onTap: widget.controller?.setDisplaynameAction,
          ),
        if (!room.isDirectChatForDisplay &&
            room.canChangeStateEvent(EventTypes.RoomAvatar))
          NotionListRow(
            leading: const Icon(Icons.photo_camera_outlined),
            title: 'Change group photo',
            subtitle: 'Visible to everyone on the network',
            onTap: widget.controller?.setAvatarAction,
          ),
        NotionListRow(
          leading: const Icon(Icons.people_outline),
          title: 'Participants',
          onTap: () => context.push('/rooms/${room.id}/details/members'),
        ),
        const Divider(),
        NotionListRow(
          leading: const Icon(Icons.logout_outlined),
          title: 'Leave chat',
          subtitle: 'You also leave it on the network',
          onTap: () => _leave(room),
        ),
      ],
    ];
    final networkAvatar = room != null
        ? projection.avatarFor(room)
        : projection.avatarForGroup(group!);
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
            mxContent: networkAvatar,
            name: name,
            size: 64,
            onTap: networkAvatar == null
                ? null
                : () => showNotionCustomDialog(
                    context: context,
                    builder: (_) => MxcImageViewer(networkAvatar),
                  ),
          ),
        ),
        nickname: metadata.nickname,
        notifications: room == null
            ? 'Choose a source'
            : privateNotificationLabel(projection.notificationModeFor(room)),
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
        sharedContent: NotionLocalSharedPreview(rooms: sourceRooms),
        sourceRows: sourceRows,
      ),
      actions: NotionConversationDetailsActions(
        search: () => Navigator.of(context).push<void>(
          MaterialPageRoute(
            builder: (_) =>
                NotionConversationContentPage(rooms: sources, name: name),
          ),
        ),
        // A single chat's Notifications row opens the same page.
        preferences: room != null || sourceRooms.isEmpty
            ? null
            : _privatePreferences,
        mute: room == null ? _sources : _privatePreferences,
        notifications: room == null ? _sources : _privatePreferences,
        pin: canEdit
            ? (value) => _run(
                () => NotionMetadataActions.setPinned(personal, entity, value),
                failure:
                    'Could not change the pin. Check private sync and try again.',
              )
            : null,
        // Incognito is global: open Privacy & security, where it lives.
        privacy: () async {
          await context.push('/rooms/settings/security');
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
