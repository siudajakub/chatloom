// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/pages/chat_list/active_call_indicator.dart';
import 'package:fluffychat/personal/inbox_projection.dart';
import 'package:fluffychat/personal/organization_page.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/ui/notion_inbox_row.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/date_time_extension.dart';
import 'package:fluffychat/utils/matrix_live_kit_calls/matrix_live_kit_call.dart';
import 'package:fluffychat/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:fluffychat/utils/room_status_extension.dart';
import 'package:fluffychat/widgets/adaptive_dialogs/show_ok_cancel_alert_dialog.dart';
import 'package:fluffychat/widgets/avatar.dart';
import 'package:fluffychat/widgets/future_loading_dialog.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

Widget notionInboxAvatar(
  PersonalClient personal,
  InboxProjection projection,
  Room room, {
  double size = 40,
}) {
  final entity = projection.entityFor(room);
  return ClipRRect(
    borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
    child: personal.values.containsKey('avatar:$entity')
        ? PrivateAvatarPreview(
            personal: personal,
            entityId: entity,
            radius: size / 2,
          )
        : Avatar(
            mxContent: room.avatar,
            name: projection.displayName(room),
            size: size,
            borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
            shapeBorder: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(NotionTokens.avatarRadius),
            ),
          ),
  );
}

class ChatListItem extends StatelessWidget {
  final Room room;
  final InboxProjection? projection;
  final Room? space;
  final bool activeChat;
  final void Function(BuildContext context)? onLongPress;
  final void Function()? onForget;
  final void Function() onTap;
  final String? filter;
  const ChatListItem(
    this.room, {
    this.projection,
    this.activeChat = false,
    required this.onTap,
    this.onLongPress,
    this.onForget,
    this.filter,
    this.space,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final personal = PersonalClient.of(room.client);
    final supplied = this.projection;
    final projection = supplied != null && identical(supplied.personal, personal)
        ? supplied
        : InboxProjection.snapshot(personal);
    final metadata = projection.metadataFor(room);
    final group = projection.groupFor(room);
    final sources = group == null
        ? [room]
        : group.members
              .map((member) => room.client.getRoomById(member.roomId))
              .whereType<Room>()
              .toList();
    final events =
        sources.map((source) => source.lastEvent).whereType<Event>().toList()
          ..sort((a, b) => b.originServerTs.compareTo(a.originServerTs));
    final lastEvent = events.firstOrNull;
    final name = projection.displayName(room);
    final typing = sources.where(
      (source) =>
          source.typingUsers.any((user) => user.id != room.client.userID),
    );
    final typingText = typing.isEmpty
        ? ''
        : typing.first.getLocalizedTypingText(context);
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
    final directId = lastEvent?.room.directChatMatrixIDForDisplay;
    final prefix =
        lastEvent?.senderId == room.client.userID ||
        directId == null ||
        lastEvent?.senderId != directId;
    final needSender =
        lastEvent != null &&
        lastEvent.room.getState(EventTypes.RoomMember, lastEvent.senderId) ==
            null;
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
    return FutureBuilder<String>(
      key: ValueKey(
        '${lastEvent?.eventId}_${lastEvent?.type}_${lastEvent?.redacted}',
      ),
      future: needSender
          ? lastEvent.calcLocalizedBody(
              MatrixLocals(l10n),
              hideReply: true,
              hideEdit: true,
              plaintextBody: true,
              removeMarkdown: true,
              withSenderNamePrefix: prefix,
            )
          : null,
      initialData: lastEvent?.calcLocalizedBodyFallback(
        MatrixLocals(l10n),
        hideReply: true,
        hideEdit: true,
        plaintextBody: true,
        removeMarkdown: true,
        withSenderNamePrefix: prefix,
      ),
      builder: (context, snapshot) {
        final preview = room.membership == Membership.invite
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
            : typingText.isNotEmpty
            ? typingText
            : snapshot.data?.trim().replaceAll('\n', ' ') ?? l10n.noMessagesYet;
        return NotionInboxRow(
          avatar: notionInboxAvatar(personal, projection, room),
          name: name,
          preview: preview,
          time: lastEvent?.originServerTs.localizedTimeShort(context),
          unreadCount: projection.unreadCount(room),
          unread: sources.any((source) => source.isUnread),
          muted: metadata.muted || nativeLimited,
          notificationLabel: notificationLabel,
          selected: activeChat,
          draft: draft != null || conflict,
          redacted: lastEvent?.redacted == true && draft == null,
          previewLeading: room.hasActiveMatrixRtcCall
              ? ActiveCallIndicator(room: room)
              : lastEvent?.status.isSending == true
              ? const SizedBox.square(
                  dimension: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.5,
                    semanticsLabel: 'Sending',
                  ),
                )
              : lastEvent?.relationshipType == RelationshipTypes.thread
              ? const Icon(Icons.forum_outlined, size: 12)
              : null,
          onTap: onTap,
          onLongPress: onLongPress == null ? null : () => onLongPress!(context),
          action: onForget != null
              ? IconButton(
                  icon: const Icon(Icons.delete_outlined),
                  tooltip: l10n.delete,
                  onPressed: onForget,
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
                    if (consent != OkCancelResult.ok || !context.mounted)
                      return;
                    await showFutureLoadingDialog(
                      context: context,
                      future: room.leave,
                    );
                  },
                )
              : null,
        );
      },
    );
  }
}
