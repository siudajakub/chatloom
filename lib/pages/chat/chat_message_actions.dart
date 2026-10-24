// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/pages/chat/conversation_message_menu.dart';
import 'package:chatloom/pages/chat/events/message_delivery_status.dart';
import 'package:chatloom/pages/chat/message_link_actions.dart';
import 'package:chatloom/personal/developer_options.dart';
import 'package:chatloom/personal/hidden_messages.dart';
import 'package:chatloom/personal/media/media_export_actions.dart';
import 'package:chatloom/personal/message_bookmarks.dart';
import 'package:chatloom/personal/network_chat_actions.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/report_policy.dart';
import 'package:chatloom/personal/stickers/sticker_message_actions.dart';
import 'package:chatloom/utils/file_description.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show RoundMediaPolicy;

/// Message types whose body is the text the user reads (copy, select).
const _textTypes = {MessageTypes.Text, MessageTypes.Notice, MessageTypes.Emote};

/// Whether the menu offers Copy for [display] (text, or a media caption).
bool conversationMessageHasText(Event display) =>
    !display.redacted &&
    display.body.trim().isNotEmpty &&
    (_textTypes.contains(display.messageType) ||
        display.fileDescription != null);

/// Whether the menu offers "Select text" for [display].
bool conversationMessageSelectable(Event display) =>
    !display.redacted &&
    _textTypes.contains(display.messageType) &&
    display.body.trim().isNotEmpty;

/// The long-press menu of one message in an ordinary chat: what the
/// selection bar and its overflow menu used to offer, for this message only,
/// behind the same checks (Telegram's order: reply, edit, copy, forward, pin,
/// save, info, report, delete).
List<ConversationMessageAction> chatMessageActions(
  ChatController controller,
  BuildContext context,
  Event event,
) {
  final l10n = L10n.of(context);
  final timeline = controller.timeline;
  final display = timeline == null ? event : event.getDisplayEvent(timeline);
  final failed = event.status.isError || display.status.isError;
  final sent = event.status.isSent;
  final room = controller.room;
  final own = event.senderId == room.client.userID;
  final pinned = controller.pinnedEventIds.contains(event.eventId);
  return [
    if (failed) ...[
      ConversationMessageAction(
        icon: Icons.send_outlined,
        label: l10n.tryToSendAgain,
        // Through the outbox attempt (same transaction ID), like the
        // bubble's own failure line.
        onSelected: () {
          if (timeline == null) return controller.sendAgainAction(event);
          unawaited(MessageDeliveryActions.retry(context, event, timeline));
        },
      ),
      ConversationMessageAction(
        icon: Icons.delete_forever_outlined,
        label: l10n.delete,
        destructive: true,
        onSelected: () => unawaited(
          timeline == null
              ? controller.deleteErrorEventAction(event)
              : MessageDeliveryActions.delete(context, event, timeline),
        ),
      ),
    ],
    if (ConversationMessageActions.canReply(event))
      ConversationMessageAction(
        icon: Icons.reply_rounded,
        label: l10n.reply,
        onSelected: () => controller.replyAction(replyTo: event),
      ),
    if (sent &&
        !event.redacted &&
        controller.activeThreadId == null &&
        room.canSendDefaultMessages &&
        ConversationMessageActions.canThread(room))
      ConversationMessageAction(
        icon: Icons.message_outlined,
        label: l10n.replyInThread,
        onSelected: () => controller.enterThread(event.eventId),
      ),
    if (controller.canEditEvent(event))
      ConversationMessageAction(
        icon: Icons.edit_outlined,
        label: l10n.edit,
        onSelected: () => controller.editEventAction(event),
      ),
    if (conversationMessageHasText(display))
      ConversationMessageAction(
        icon: Icons.copy_outlined,
        label: l10n.copy,
        onSelected: () => controller.copyEventAction(event),
      ),
    // FX-20: Telegram's link sheet "Copy link".
    ...messageLinkActions(controller.context, display),
    if (conversationMessageSelectable(display))
      ConversationMessageAction(
        icon: Icons.text_fields_rounded,
        label: 'Select text',
        onSelected: () => showConversationTextSelection(
          controller.context,
          controller.eventText(event),
        ),
      ),
    if (sent &&
        !event.redacted &&
        !isViewLimited(display) &&
        RoundMediaPolicy.fromContent(display.content).canForward)
      ConversationMessageAction(
        icon: Icons.forward_outlined,
        label: l10n.forward,
        onSelected: () => controller.forwardEventAction(event),
      ),
    if (controller.canPinEvent(event))
      ConversationMessageAction(
        icon: pinned ? Icons.push_pin : Icons.push_pin_outlined,
        // A bridged chat's pin stays in ChatLoom (BR-06).
        label: pinned
            ? l10n.unpin
            : pinStaysInChatLoom(room) != null
            ? 'Pin in ChatLoom'
            : l10n.pinMessage,
        onSelected: () => controller.pinEvent(event),
      ),
    if (MessageBookmarks.canBookmark(event))
      () {
        final personal = PersonalClient.of(room.client);
        final saved = MessageBookmarks.isBookmarked(personal, event);
        return ConversationMessageAction(
          icon: saved ? Icons.bookmark : Icons.bookmark_outline,
          label: saved ? 'Remove bookmark' : 'Bookmark',
          onSelected: () => unawaited(
            MessageBookmarks.toggle(controller.context, personal, event),
          ),
        );
      }(),
    // Stickers: favourite, view pack; GIFs: save (Telegram).
    ...stickerMessageActions(context, display),
    // Save (gallery/Downloads on Android), Save as…, Copy image (macOS).
    // View-once media is never saved from ChatLoom (BR-10).
    ...mediaExportMenuActions(
      controller.context,
      display,
      canSave: controller.canSaveEvent(display) && !isViewLimited(display),
    ),
    // Raw message source: developer options only (CS-23).
    if (DeveloperOptions.enabled)
      ConversationMessageAction(
        icon: Icons.info_outlined,
        label: l10n.messageInfo,
        onSelected: () => controller.showEventInfo(event),
      ),
    // A report goes to the homeserver's admins: Beeper for a bridged chat,
    // never the network itself (CS-24).
    if (sent && !own && canReportInRoom(room))
      ConversationMessageAction(
        icon: Icons.shield_outlined,
        label: l10n.reportMessage,
        onSelected: () => controller.reportEventAction(event),
      ),
    // FX-16: Messenger's "Remove for you" — hidden in ChatLoom only, never
    // redacted or sent; Undo in the snackbar.
    if (HiddenMessages.canHide(event))
      ConversationMessageAction(
        icon: Icons.visibility_off_outlined,
        label: 'Remove for you',
        onSelected: () => HiddenMessages.hideWithUndo(controller.context, event),
      ),
    // A sending own message is deleted as soon as it goes through.
    if (!failed &&
        (controller.canRedactEvent(event) ||
            (own &&
                event.status.isSending &&
                !controller.isArchived &&
                ConversationMessageActions.canDeleteForEveryone(event))))
      ConversationMessageAction(
        icon: Icons.delete_outlined,
        label: l10n.delete,
        destructive: true,
        onSelected: () => controller.redactEventAction(event),
      ),
  ];
}
