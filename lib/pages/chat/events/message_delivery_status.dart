// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/message_delivery.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:chatloom/widgets/adaptive_dialogs/show_modal_action_popup.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show RoundVideoDescriptor;

/// The failure line under an own message that did not go through: Telegram's
/// red mark and Messenger's "Not delivered · Tap to retry" in one tappable
/// row. A tap opens Retry / Delete (or the bridge's reason and Send again).
/// A full touch target, only on failed rows, so normal rows keep their size.
class MessageDeliveryFailure extends StatelessWidget {
  final Event event;
  final Timeline timeline;
  final MessageDelivery delivery;

  /// Page colour behind the line over a wallpaper (see [ConversationMetaChip]).
  final Color? backdrop;

  const MessageDeliveryFailure({
    super.key,
    required this.event,
    required this.timeline,
    required this.delivery,
    this.backdrop,
  });

  @override
  Widget build(BuildContext context) {
    final danger = context.notion.colors.danger;
    return Semantics(
      button: true,
      label: delivery.label,
      excludeSemantics: true,
      child: NotionPressable(
        scale: NotionMotion.pressRow,
        child: InkWell(
          key: const ValueKey('message-delivery-failure'),
          borderRadius: NotionRadius.pillAll,
          onTap: () =>
              MessageDeliveryActions.show(context, event, timeline, delivery),
          child: ConstrainedBox(
            constraints: const BoxConstraints(
              minHeight: NotionSize.touchTarget,
            ),
            child: Align(
              widthFactor: 1,
              alignment: AlignmentDirectional.centerEnd,
              child: ConversationMetaChip(
                backdrop: backdrop,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  spacing: NotionSpace.xxs,
                  children: [
                    Icon(Icons.error, size: NotionSize.iconSm, color: danger),
                    Flexible(
                      child: Text(
                        delivery.label,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: NotionType.caption.copyWith(
                          color: danger,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

enum _DeliveryChoice { retry, delete }

/// Retry / Delete of failed own messages, usable from the bubble's failure
/// line and from any message action menu. Every retry is explicit and keeps
/// the original Matrix transaction ID, so it can never duplicate a message.
abstract final class MessageDeliveryActions {
  /// The failed events of a row: the message itself and/or its own edits.
  static List<Event> failedEvents(Event event, Timeline timeline) => [
    if (event.status.isError) event,
    if (event.status.isSent)
      for (final edit in event.aggregatedEvents(
        timeline,
        RelationshipTypes.edit,
      ))
        if (edit.senderId == event.senderId && edit.status.isError) edit,
  ];

  static Future<void> show(
    BuildContext context,
    Event event,
    Timeline timeline,
    MessageDelivery delivery,
  ) async {
    final l10n = L10n.of(context);
    final copyable = _copyText(event, timeline, l10n) != null;
    var message = delivery.detail;
    if (delivery.kind == MessageDeliveryKind.notSent) {
      message = await _notSentReason(event, timeline);
      if (!context.mounted) return;
    }
    final bridge = delivery.kind == MessageDeliveryKind.notDelivered;
    final choice = await showModalActionPopup<_DeliveryChoice>(
      context: context,
      title: bridge
          ? 'Not delivered'
          : delivery.edit
          ? 'Edit not sent'
          : 'Message not sent',
      message: message,
      cancelLabel: l10n.cancel,
      actions: [
        if (delivery.canRetry && (!bridge || copyable))
          AdaptiveModalAction(
            value: _DeliveryChoice.retry,
            label: bridge ? 'Send again' : 'Retry',
            icon: const Icon(Icons.refresh),
            isDefaultAction: true,
          ),
        if (delivery.canDelete)
          AdaptiveModalAction(
            value: _DeliveryChoice.delete,
            label: delivery.edit ? 'Discard edit' : l10n.delete,
            icon: const Icon(Icons.delete_outline),
            isDestructive: true,
          ),
      ],
    );
    if (!context.mounted || choice == null) return;
    switch (choice) {
      case _DeliveryChoice.retry:
        if (bridge) {
          await sendCopy(context, event, timeline);
        } else {
          await retry(context, event, timeline);
        }
      case _DeliveryChoice.delete:
        await delete(context, event, timeline);
    }
  }

  /// Why the server has no confirmation: unknown (maybe received) and
  /// rejected are different, and say so.
  static Future<String> _notSentReason(Event event, Timeline timeline) async {
    const generic =
        'The message did not reach the server. Retry sends the same attempt, '
        'so it is never delivered twice.';
    for (final failed in failedEvents(event, timeline)) {
      final action = PersonalClient.immediateActionOf(failed);
      if (action == null) continue;
      try {
        final state = await PersonalClient.of(
          failed.room.client,
        ).immediateState(action);
        if (state == null) continue;
        if (state.state == ImmediateSendState.failed) {
          return switch (state.errorCode) {
            'bridge_unavailable' =>
              'This network does not accept this message right now.',
            'replyUnavailable' =>
              'The message you replied to is no longer available.',
            'sourceUnavailable' => 'This chat is no longer available.',
            _ => 'The server did not accept this message.',
          };
        }
        return 'ChatLoom could not confirm that the server received this '
            'message. Retry sends the same attempt, so it is never '
            'delivered twice.';
      } catch (_) {
        // Storage is unavailable: the generic text is still true.
      }
    }
    return generic;
  }

  /// Sends the failed message (and failed edits) again with their original
  /// attempt. Returns whether every retry was started.
  static Future<bool> retry(
    BuildContext context,
    Event event,
    Timeline timeline,
  ) async {
    final failed = failedEvents(event, timeline);
    if (failed.isEmpty) return false;
    final proceed = await showTrustUserInRoomDialog(context, event.room);
    if (!context.mounted || !proceed) return false;
    var ok = true;
    for (final e in failed) {
      try {
        final round = RoundVideoDescriptor.fromContent(e.content) != null;
        final txid = e.transactionId ?? e.eventId;
        final roundMatch = RegExp(
          r'^round-([A-Za-z0-9_-]{1,128})$',
        ).firstMatch(txid);
        final immediate = PersonalClient.immediateActionOf(e);
        if (round && roundMatch != null) {
          unawaited(
            TelegramRoundService.of(e.room.client)
                .retry(roundMatch[1]!, stillCurrent: () => context.mounted)
                .then<void>((_) {}, onError: (Object _) {}),
          );
        } else if (immediate != null) {
          // The result updates the bubble through the local echo.
          unawaited(
            PersonalClient.of(e.room.client)
                .retryImmediate(immediate)
                .then<void>((_) {}, onError: (Object _) {}),
          );
        } else {
          unawaited(
            e.sendAgain().then<void>(
              (_) {},
              onError: (Object _) {
                if (context.mounted) {
                  _notify(
                    context,
                    'The message could not be sent again. Send it as a new message.',
                  );
                }
              },
            ),
          );
        }
      } catch (_) {
        ok = false;
      }
    }
    if (!ok && context.mounted) {
      _notify(context, 'The message could not be sent again.');
    }
    return ok;
  }

  /// Removes the unsent local echo (and failed edits) and retires their
  /// outbox attempts. Never unsends anything the server accepted.
  static Future<void> delete(
    BuildContext context,
    Event event,
    Timeline timeline,
  ) async {
    var ok = true;
    for (final e in failedEvents(event, timeline)) {
      try {
        final immediate = PersonalClient.immediateActionOf(e);
        await e.cancelSend();
        if (immediate != null) {
          await PersonalClient.of(e.room.client).discardImmediate(immediate);
        }
      } catch (_) {
        ok = false;
      }
    }
    if (!ok && context.mounted) {
      _notify(context, 'The unsent message could not be removed.');
    }
  }

  /// A bridge rejected the message: send its text again as a new message
  /// (the original stays, marked "Not delivered").
  static Future<void> sendCopy(
    BuildContext context,
    Event event,
    Timeline timeline,
  ) async {
    final l10n = L10n.of(context);
    final text = _copyText(event, timeline, l10n);
    if (text == null) return;
    final room = event.room;
    final proceed = await showTrustUserInRoomDialog(context, room);
    if (!context.mounted || !proceed) return;
    final replyId = event.inReplyToEventId(includingFallback: false);
    final reply = replyId == null ? null : await timeline.getEventById(replyId);
    final thread = event.relationshipType == RelationshipTypes.thread
        ? event.relationshipEventId
        : null;
    try {
      final result = await PersonalClient.of(
        room.client,
      ).sendImmediate(room, text, replyTo: reply, threadId: thread);
      if (result.state == ImmediateSendState.accepted) {
        await PersonalClient.of(room.client).completeImmediate(result.actionId);
      }
    } catch (_) {
      if (context.mounted) _notify(context, 'The message was not sent again.');
    }
  }

  /// Plain text of a text message (reply fallback removed), or null.
  static String? _copyText(Event event, Timeline timeline, L10n l10n) {
    final display = event.getDisplayEvent(timeline);
    if (display.redacted ||
        !{
          MessageTypes.Text,
          MessageTypes.Notice,
          MessageTypes.Emote,
        }.contains(display.messageType)) {
      return null;
    }
    final text = display.calcLocalizedBodyFallback(
      MatrixLocals(l10n),
      withSenderNamePrefix: false,
      hideReply: true,
    );
    return text.trim().isEmpty ? null : text;
  }

  static void _notify(BuildContext context, String message) =>
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(message)));
}
