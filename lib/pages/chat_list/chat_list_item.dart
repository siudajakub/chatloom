// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/delivery_ticks.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/conversation_activity.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/organization_page.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/private_avatar.dart';
import 'package:chatloom/personal/ui/notion_inbox_network_badge.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/personal/ui/notion_network_adapter.dart';
import 'package:chatloom/personal/ui/conversation_activity_widgets.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:chatloom/widgets/avatar.dart';
import 'package:chatloom/widgets/future_loading_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

Widget notionInboxAvatar(
  PersonalClient personal,
  InboxProjection projection,
  Room room, {
  double size = 40,
}) => personalConversationAvatar(
  personal,
  entityId: projection.entityFor(room),
  avatar: projection.avatarFor(room),
  name: projection.displayName(room),
  client: room.client,
  size: size,
);

/// Private avatar when set (network avatar while it loads or if it fails),
/// otherwise the network avatar, otherwise initials.
Widget personalConversationAvatar(
  PersonalClient personal, {
  required String entityId,
  required Uri? avatar,
  required String name,
  Client? client,
  double size = 40,
  VoidCallback? onTap,
}) {
  final network = Avatar(
    client: client ?? personal.client,
    mxContent: avatar,
    name: name,
    size: size,
    onTap: onTap,
    borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
    shapeBorder: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
    ),
  );
  // Avatar clips itself (superellipse Material); only the private preview
  // needs an explicit clip.
  if (!privateAvatarShown(personal, entityId)) return network;
  return ClipRRect(
    borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
    child: PrivateAvatarPreview(
      personal: personal,
      entityId: entityId,
      radius: size / 2,
      fallback: network,
    ),
  );
}

/// Rooms whose events make up [room]'s inbox row: a merged person's source
/// chats, otherwise the room.
List<Room> _rowSources(InboxProjection projection, Room room) {
  final group = projection.groupFor(room);
  return group == null
      ? [room]
      : group.members
            .map((member) => room.client.getRoomById(member.roomId))
            .whereType<Room>()
            .toList();
}

/// Everything a [ChatListItem] reads that can change without a new inbox
/// [projection] (a sync of one room reuses it; every private change builds
/// a new one). The inbox keeps a built row while this stays equal, so a
/// publish rebuilds only rows that changed (Telegram's per-cell update
/// mask). Keep it in step with [_ChatListItemState.build].
List<Object?> chatListItemSignature(
  Room room,
  InboxProjection projection, {
  bool activeChat = false,
  int flash = 0,
  bool showNetworks = false,
}) {
  final now = DateTime.now();
  final own = room.client.userID;
  return [
    room,
    projection,
    activeChat,
    flash,
    showNetworks,
    // Day of the time labels ("12:30" becomes "Mon").
    DateTime(now.year, now.month, now.day),
    room.membership,
    projection.displayName(room),
    projection.avatarFor(room),
    for (final source in _rowSources(projection, room)) ...[
      source.id,
      source.notificationCount,
      source.highlightCount,
      source.markedUnread,
      source.pushRuleState,
      source.membership,
      source.typingUsers
          .where((user) => user.id != own)
          .map((user) => user.id)
          .join(' '),
      if (source.lastEvent case final event?) ...[
        event,
        event.eventId,
        event.status,
        event.redacted,
        event.content['body'],
        event.content['m.new_content'],
        inboxDeliveryProgress(source, event),
      ] else
        null,
    ],
  ];
}

class ChatListItem extends StatefulWidget {
  final Room room;
  final InboxProjection? projection;
  final bool activeChat;
  final void Function(BuildContext context)? onLongPress;
  final void Function()? onForget;
  final void Function() onTap;
  final String? filter;

  /// Changes when a merge, unmerge or undo just produced this row: it
  /// flashes once ([flashOnMount] when the row is new).
  final int flash;
  final bool flashOnMount;

  /// Mark the row's network(s) on its avatar: the list shows all networks
  /// (UX-17, FT-12). Off in a single-network view.
  final bool showNetworks;
  const ChatListItem(
    this.room, {
    this.projection,
    this.flash = 0,
    this.flashOnMount = false,
    this.showNetworks = false,
    this.activeChat = false,
    required this.onTap,
    this.onLongPress,
    this.onForget,
    this.filter,
    super.key,
  });

  @override
  State<ChatListItem> createState() => _ChatListItemState();
}

class _ChatListItemState extends State<ChatListItem> {
  String? _senderRequested;
  final _previewRepairs = <String, String>{};

  void _repairPreview(Room room) {
    final event = room.lastEvent;
    if (event == null ||
        room.client.roomPreviewLastEvents.contains(event.type) ||
        event.type == EventTypes.refreshingLastEvent ||
        _previewRepairs[room.id] == event.eventId) {
      return;
    }
    _previewRepairs[room.id] = event.eventId;
    room.refreshLastEvent().then((_) {
      if (mounted) setState(() {});
    }, onError: (_) {});
  }

  /// Newest incoming event seen by this row; when a newer one arrives the
  /// row flashes once (it usually just moved to the top). Starts with the
  /// event present at first build, so scrolling never flashes.
  String? _incomingId;
  int _incomingTs = 0;
  int _highlight = 0;

  void _trackIncoming(Event? event, bool own) {
    if (event == null || own || event.status.isSending) return;
    final ts = event.originServerTs.millisecondsSinceEpoch;
    if (_incomingId == null) {
      _incomingId = event.eventId;
      _incomingTs = ts;
      return;
    }
    if (event.eventId == _incomingId || ts <= _incomingTs) return;
    _incomingId = event.eventId;
    _incomingTs = ts;
    _highlight++;
  }

  /// Loads a missing sender member once per event (group "Name: …"
  /// prefixes); the preview itself is computed synchronously every build.
  void _requestSender(Event event) {
    if (_senderRequested == event.eventId) return;
    _senderRequested = event.eventId;
    event.fetchSenderUser().then((user) {
      if (mounted && user != null) setState(() {});
    }, onError: (_) {});
  }

  @override
  Widget build(BuildContext context) {
    final room = widget.room;
    final personal = PersonalClient.of(room.client);
    final supplied = widget.projection;
    final projection =
        supplied != null && identical(supplied.personal, personal)
        ? supplied
        : InboxProjection.snapshot(personal);
    final sources = _rowSources(projection, room);
    return ConversationActivityBuilder(
      client: room.client,
      rooms: sources,
      builder: (context, activity) =>
          _buildRow(context, personal, projection, sources, activity),
    );
  }

  Widget _buildRow(
    BuildContext context,
    PersonalClient personal,
    InboxProjection projection,
    List<Room> sources,
    ConversationActivity activity,
  ) {
    final room = widget.room;
    final metadata = projection.metadataFor(room);
    for (final source in sources) {
      _repairPreview(source);
    }
    final events =
        sources.map((source) => source.lastEvent).whereType<Event>().toList()
          ..sort((a, b) => b.originServerTs.compareTo(a.originServerTs));
    final lastEvent = events.firstOrNull;
    final name = projection.displayName(room);
    final typingText = conversationTypingText(
      context,
      activity,
      sourceLabels: projection.groupFor(room) != null,
    );
    final draftValues = [
      personal.values['draft:${projection.entityFor(room)}'],
      ...sources.map((source) => personal.values['draft:${source.id}']),
    ];
    final draft = draftValues
        .map((value) => value?['text'])
        .whereType<String>()
        .where((text) => text.isNotEmpty)
        .firstOrNull;
    final conflict =
        personal.conflicts.containsKey('draft:${projection.entityFor(room)}') ||
        sources.any(
          (source) => personal.conflicts.containsKey('draft:${source.id}'),
        );
    final l10n = L10n.of(context);
    final nativeRules = sources.map((source) => source.pushRuleState).toSet();
    final nativeLimited = nativeRules.any(
      (rule) => rule != PushRuleState.notify,
    );
    final notificationLabel = !nativeLimited && metadata.muted
        ? 'Marked muted in private preferences'
        : nativeRules.length > 1
        ? 'Notification rules vary by source'
        : nativeRules.firstOrNull == PushRuleState.dontNotify
        ? 'Muted on this source'
        : 'Mentions only on this source';
    String? lastPreview;
    var failed = false;
    var delivery = DeliveryProgress.none;
    if (lastEvent != null) {
      final own = OwnSenderResolver.of(room.client).isOwnEvent(lastEvent);
      // Telegram and Messenger mark a chat whose last own message failed.
      failed =
          lastEvent.status.isError &&
          (own || lastEvent.senderId == room.client.userID);
      // Ticks before the time (Telegram's dialog list).
      delivery = inboxDeliveryProgress(lastEvent.room, lastEvent);
      // A network rejection is marked like a send failure.
      failed |= delivery == DeliveryProgress.failed;
      if (delivery == DeliveryProgress.sent) {
        BridgeDeliveryLedger.of(room.client).lookUp(lastEvent.room, lastEvent);
      }
      _trackIncoming(lastEvent, own);
      final showsSender = personalPreviewShowsSender(lastEvent);
      if (!own &&
          showsSender &&
          lastEvent.room.getState(EventTypes.RoomMember, lastEvent.senderId) ==
              null) {
        _requestSender(lastEvent);
      }
      lastPreview = personalPreview(
        lastEvent,
        own: own,
        group: showsSender,
        i18n: MatrixLocals(l10n),
      );
    }
    final invite = room.membership == Membership.invite;
    final showsTyping =
        !invite && !conflict && draft == null && typingText.isNotEmpty;
    final showsFailed = failed && !invite && !conflict && draft == null;
    final preview = invite
        ? room
                  .getState(EventTypes.RoomMember, room.client.userID!)
                  ?.content
                  .tryGet<String>('reason') ??
              (room.isDirectChatForDisplay
                  ? l10n.newChatRequest
                  : l10n.inviteGroupChat)
        : conflict
        ? 'Draft conflict — review in chat'
        : draft != null
        ? 'Draft: $draft'
        : showsTyping
        ? typingText
        : lastPreview == null || lastPreview.isEmpty
        ? l10n.noMessagesYet
        : lastPreview;
    return Semantics(
      label: activity.presences.any((presence) => presence.online)
          ? l10n.currentlyActive
          : null,
      child: NotionInboxRow(
        avatar: ConversationActivityAvatar(
          activity: activity,
          child: notionInboxAvatar(
            personal,
            projection,
            room,
            size: NotionSize.avatarLg,
          ),
        ),
        networks: widget.showNetworks
            ? notionBadgeNetworks(notionRoomNetworks(projection, room))
            : const [],
        name: name,
        preview: preview,
        time: lastEvent?.originServerTs.localizedTimeShort(context),
        unreadCount: projection.unreadCount(room),
        unread: sources.any((source) => source.isUnread),
        mentioned:
            !invite && sources.any((source) => source.highlightCount > 0),
        muted: metadata.muted || nativeLimited,
        notificationLabel: notificationLabel,
        selected: widget.activeChat,
        draft: draft != null || conflict,
        redacted: lastEvent?.redacted == true && draft == null && !showsTyping,
        typing: showsTyping,
        pinned: metadata.isPinned,
        failed: showsFailed && !showsTyping,
        // Sending keeps its delayed spinner; a failure its danger mark.
        delivery: invite || conflict || draft != null
            ? null
            : switch (delivery) {
                DeliveryProgress.sent ||
                DeliveryProgress.delivered ||
                DeliveryProgress.read => delivery.tick,
                _ => null,
              },
        previewLeading: showsFailed && !showsTyping
            ? null
            : lastEvent?.status.isSending == true
            // Only a send that takes noticeably long shows a spinner.
            ? const NotionDelayedSpinner(size: 12, strokeWidth: 1.5)
            : lastEvent?.relationshipType == RelationshipTypes.thread
            ? const Icon(Icons.forum_outlined, size: 12)
            : null,
        highlight: _highlight == 0 && widget.flash == 0
            ? null
            : (_highlight, widget.flash),
        highlightOnMount: widget.flashOnMount,
        onTap: widget.onTap,
        onLongPress: widget.onLongPress == null
            ? null
            : () => widget.onLongPress!(context),
        action: widget.onForget != null
            ? IconButton(
                icon: const Icon(Icons.delete_outlined),
                tooltip: l10n.delete,
                onPressed: widget.onForget,
              )
            : room.membership == Membership.invite
            ? IconButton(
                tooltip: l10n.declineInvitation,
                icon: const Icon(Icons.close, size: 20),
                onPressed: () async {
                  final consent = await showOkCancelAlertDialog(
                    context: context,
                    title: l10n.declineInvitation,
                    message: l10n.areYouSure,
                    okLabel: l10n.yes,
                    isDestructive: true,
                  );
                  if (consent != OkCancelResult.ok || !context.mounted) return;
                  await showFutureLoadingDialog(
                    context: context,
                    future: room.leave,
                  );
                },
              )
            : null,
      ),
    );
  }
}
