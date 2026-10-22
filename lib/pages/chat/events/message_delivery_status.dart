// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/media/outgoing_media.dart';
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
  /// A file whose send this process still owns (queued, or waiting out a
  /// rate limit) is not failed: it ends as sent or "Not sent" by itself, so
  /// neither Retry (a second job) nor Delete (sent anyway) applies to it.
  static List<Event> failedEvents(Event event, Timeline timeline) => [
    if (event.status.isError && !OutgoingMedia.isActive(event)) event,
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
        if (delivery.canRetry && (!bridge || canSendCopy(event, timeline)))
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
        if (bridge) {
          await deleteUndelivered(context, event);
        } else {
          await delete(context, event, timeline);
        }
    }
  }

  /// Why the server has no confirmation: unknown (maybe received) and
  /// rejected are different, and say so.
  static Future<String> _notSentReason(Event event, Timeline timeline) async {
    const generic =
        'The message did not reach the server. Retry sends the same attempt, '
        'so it is never delivered twice.';
    for (final failed in failedEvents(event, timeline)) {
      final round = TelegramRoundService.actionOf(failed);
      if (round != null && _isRound(failed)) {
        try {
          return await TelegramRoundService.of(
            failed.room.client,
          ).failureReason(round);
        } catch (_) {
          return generic;
        }
      }
      final media = OutgoingMedia.failureOf(
        failed.transactionId ?? failed.eventId,
      );
      if (media != null) return media;
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
        final round = TelegramRoundService.actionOf(e);
        final immediate = PersonalClient.immediateActionOf(e);
        if (round != null && _isRound(e)) {
          // The bubble shows the upload again; leaving the chat does not
          // stop it.
          unawaited(
            TelegramRoundService.of(e.room.client)
                .retry(round, room: e.room)
                .then<void>((_) {}, onError: (Object _) {}),
          );
        } else if (immediate != null) {
          // The result updates the bubble through the local echo; a retry
          // that could not start says why instead of doing nothing.
          unawaited(_retryText(context, e, immediate));
        } else {
          unawaited(
            sendAgain(e).then<void>(
              (_) {},
              onError: (Object error) {
                if (context.mounted) {
                  _notify(
                    context,
                    error is OutgoingMediaUnavailable
                        ? 'This file is no longer on this device. Delete it and send it again.'
                        : 'The message could not be sent again. Send it as a new message.',
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
        await discard(e);
      } catch (_) {
        ok = false;
      }
    }
    if (!ok && context.mounted) {
      _notify(context, 'The unsent message could not be removed.');
    }
  }

  /// Removes one unsent local echo and retires its outbox attempt (text,
  /// round). Throws when it could not be removed.
  static Future<void> discard(Event e) async {
    final immediate = PersonalClient.immediateActionOf(e);
    final round = TelegramRoundService.actionOf(e);
    // A round's attempt is retired first: it must never be sent after its
    // bubble is gone.
    if (round != null && _isRound(e)) {
      await TelegramRoundService.of(e.room.client).discard(round);
    } else if (_isFile(e)) {
      // Never sent after its bubble is gone; this device's copy goes.
      await OutgoingMedia.discard(e);
    }
    await e.cancelSend();
    if (immediate != null) {
      await PersonalClient.of(e.room.client).discardImmediate(immediate);
    }
  }

  static bool _isRound(Event event) =>
      RoundVideoDescriptor.fromContent(event.content) != null;

  static bool _isFile(Event event) => {
    MessageTypes.Image,
    MessageTypes.Video,
    MessageTypes.Audio,
    MessageTypes.File,
  }.contains(event.messageType);

  /// Retries the text attempt [actionId] and explains a retry that could
  /// not start (the bubble itself shows an accepted or unconfirmed result).
  static Future<void> _retryText(
    BuildContext context,
    Event event,
    String actionId,
  ) async {
    ImmediateSendResult? result;
    try {
      result = await _retryOutboxText(event, actionId);
    } catch (_) {}
    if (result != null && result.state != ImmediateSendState.failed) return;
    if (!context.mounted) return;
    _notify(context, retryFailureText(result?.errorCode));
  }

  /// Retries an outbox text. An echo whose attempt is not in this device's
  /// outbox any more is sent again by the SDK with its own transaction ID
  /// (the server deduplicates it), as before the outbox existed.
  static Future<ImmediateSendResult> _retryOutboxText(
    Event event,
    String actionId,
  ) async {
    final result = await PersonalClient.of(
      event.room.client,
    ).retryImmediate(actionId);
    if (result.state != ImmediateSendState.failed ||
        result.errorCode != 'actionUnavailable' ||
        !event.status.isError) {
      return result;
    }
    final eventId = await event.sendAgain();
    return ImmediateSendResult(
      state: eventId == null
          ? ImmediateSendState.unknown
          : ImmediateSendState.accepted,
      actionId: actionId,
      transactionId: event.transactionId ?? event.eventId,
      eventId: eventId,
    );
  }

  /// Why a text Retry did not send, in plain words (never the code).
  static String retryFailureText(String? code) => switch (code) {
    'bridge_unavailable' =>
      'Not sent: this network does not accept this message right now.',
    'replyUnavailable' =>
      'Not sent: the message you replied to is no longer available.',
    'sourceUnavailable' => 'Not sent: this chat is no longer available.',
    'actionUnavailable' || 'requestMismatch' || 'actionCompleted' =>
      'This message can no longer be sent again. Delete it and send it as a new message.',
    'differentDeviceNeedsReconciliation' =>
      'This message was started on another device. Send it again as a new message.',
    'storageUnavailable' || null =>
      'ChatLoom could not read its outbox. Try again in a moment.',
    _ => 'The server did not accept this message.',
  };

  /// Sends one failed event again with its original transaction: files
  /// (photos, videos, voice) through [OutgoingMedia], so the bubble shows
  /// the upload again; everything else through the SDK.
  static Future<void> sendAgain(Event event) async {
    if (!_isRound(event) && _isFile(event)) {
      await OutgoingMedia.retry(event);
      return;
    }
    // A text or edit of the encrypted outbox is retried there, so its
    // attempt is completed instead of left behind.
    final immediate = PersonalClient.immediateActionOf(event);
    if (immediate != null && !_isRound(event)) {
      final result = await _retryOutboxText(event, immediate);
      if (result.state == ImmediateSendState.failed) {
        throw ImmediateOutboxFailure(result.errorCode ?? 'failed');
      }
      return;
    }
    await event.sendAgain();
  }

  /// Whether a rejected message can be sent again as a new copy: text,
  /// media (its uploaded file is reused), anything but a round video,
  /// whose retry belongs to the round service.
  static bool canSendCopy(Event event, Timeline timeline) {
    final display = event.getDisplayEvent(timeline);
    return !display.redacted &&
        !_isRound(event) &&
        (_copyText(event, timeline, null) != null ||
            const {
              MessageTypes.Image,
              MessageTypes.Video,
              MessageTypes.Audio,
              MessageTypes.File,
              MessageTypes.Location,
            }.contains(display.messageType));
  }

  /// A bridge rejected the message: send it again as a new message (text
  /// through the outbox; media with its uploaded file, reply kept), then
  /// remove the rejected original, which never reached the other person.
  /// The chat ends with one message, as after Messenger's retry.
  static Future<void> sendCopy(
    BuildContext context,
    Event event,
    Timeline timeline,
  ) async {
    final l10n = L10n.of(context);
    final text = _copyText(event, timeline, l10n);
    final room = event.room;
    final proceed = await showTrustUserInRoomDialog(context, room);
    if (!context.mounted || !proceed) return;
    final replyId = event.inReplyToEventId(includingFallback: false);
    final thread = event.relationshipType == RelationshipTypes.thread
        ? event.relationshipEventId
        : null;
    try {
      // The quoted message may have to be fetched from the server.
      final reply = replyId == null
          ? null
          : await timeline.getEventById(replyId);
      var accepted = false;
      if (text != null) {
        final result = await PersonalClient.of(
          room.client,
        ).sendImmediate(
          room,
          text,
          replyTo: reply,
          threadId: thread,
          // No draft holds a copy: an identical later message is a new one.
          onDurable: (attempt) => unawaited(
            PersonalClient.of(room.client).markImmediateConsumed(attempt.actionId),
          ),
        );
        if (result.state == ImmediateSendState.accepted) {
          await PersonalClient.of(
            room.client,
          ).completeImmediate(result.actionId);
          accepted = true;
        }
      } else {
        final content = event.getDisplayEvent(timeline).content.copy()
          ..remove('m.new_content')
          ..remove('m.relates_to');
        final id = await room.sendEvent(
          content,
          inReplyTo: reply,
          threadRootEventId: thread,
        );
        accepted = id != null;
      }
      if (accepted) await _removeUndelivered(event);
    } catch (_) {
      if (context.mounted) _notify(context, 'The message was not sent again.');
    }
  }

  /// Redacts a message the network never got; the bridge's report about
  /// that redaction means nothing to the user.
  static Future<void> _removeUndelivered(Event event) async {
    final id = await event.redactEvent();
    if (id != null) MessageDeletions.markQuiet(event.room, id);
  }

  /// Delete of a message the network rejected: it only leaves this chat.
  static Future<void> deleteUndelivered(
    BuildContext context,
    Event event,
  ) async {
    final network = bridgedNetworkLabel(event.room);
    final ok = await showNotionConfirmDialog(
      context: context,
      title: 'Delete message?',
      message: network == null
          ? 'It was not delivered and will be removed from this chat.'
          : 'It was not delivered to $network and will be removed from '
                'this chat.',
      confirmLabel: 'Delete',
      destructive: true,
    );
    if (!ok || !context.mounted) return;
    try {
      await _removeUndelivered(event);
    } catch (_) {
      if (context.mounted) {
        _notify(context, 'Couldn’t delete the message. Try again.');
      }
    }
  }

  /// Plain text of a text message (reply fallback removed), or null.
  static String? _copyText(Event event, Timeline timeline, L10n? l10n) {
    final display = event.getDisplayEvent(timeline);
    if (display.redacted ||
        !{
          MessageTypes.Text,
          MessageTypes.Notice,
          MessageTypes.Emote,
        }.contains(display.messageType)) {
      return null;
    }
    if (l10n == null) return display.body.trim().isEmpty ? null : display.body;
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
