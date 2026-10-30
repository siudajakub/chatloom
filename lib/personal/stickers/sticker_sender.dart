// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'sticker_convert.dart';
import 'sticker_library.dart';
import 'sticker_models.dart';
import 'sticker_send_plan.dart';

/// Sends stickers and GIFs from the panel, adapted to the room's network
/// ([StickerSendPlan]). Telegram keeps the panel open after a send and so
/// does ChatLoom; the item becomes the newest recent at once (Telegram),
/// not when the server answers: a send that waits in the queue, retries or
/// fails must not keep the recents behind.
abstract final class StickerSender {
  /// Sends [item] to [host]'s room (as a reply when one is being composed).
  /// Returns false when nothing was sent: not possible in this room (the
  /// reason is shown) or the trust check was declined.
  static Future<bool> send(
    BuildContext context,
    ConversationComposerHost host,
    StickerItem item, {
    Future<bool> Function(BuildContext, Room)? confirmTrust,
  }) async {
    final room = host.room;
    final plan = StickerSendPlan.forRoom(room, item);
    if (!plan.possible) {
      ScaffoldMessenger.maybeOf(
        context,
      )?.showSnackBar(SnackBar(content: Text(plan.reason!)));
      return false;
    }
    final proceed = await (confirmTrust ?? showTrustUserInRoomDialog)(
      context,
      room,
    );
    if (!proceed) return false;
    final content = Map<String, Object?>.of(plan.content!);
    final thread = host.activeThreadId;
    final reply = host.replyEvent;
    if (reply != null && thread == null) {
      // A plain relation: a reply fallback would rewrite the body, which
      // bridges use as the sticker's emoji.
      content['m.relates_to'] = {
        'm.in_reply_to': {'event_id': reply.eventId},
      };
      host.cancelReplyEventAction();
    }
    NotionHaptics.send();
    final library = StickerLibrary.of(room.client);
    if (item.kind == StickerKind.gif) {
      library.useGif(item);
    } else {
      library.useSticker(item);
    }
    // The panel may be closed by the time the server answers: report on
    // the app's navigator.
    const reporter = ErrorReporter.action(null, action: ErrorAction.send);
    final relation = content['m.relates_to'];
    Future<void> sendPlan(
      StickerSendPlan plan,
      Map<String, Object?> content,
    ) async {
      await room.sendEvent(
        {...content, 'm.relates_to': ?relation},
        type: plan.type,
        threadRootEventId: thread,
        threadLastEventId: host.threadLastEventId,
      );
    }

    final conversion = plan.conversion;
    if (conversion == null) {
      sendPlan(
        plan,
        content,
      ).then<void>((_) {}, onError: reporter.onErrorCallback);
      return true;
    }
    // Converting and uploading take a moment: the panel stays usable and
    // the sticker goes out when ready (or as [StickerSendPlan.fallback]).
    _sendConverted(
      room,
      item,
      plan,
      conversion,
      content,
      sendPlan,
    ).then<void>((_) {}, onError: reporter.onErrorCallback);
    return true;
  }

  static Future<void> _sendConverted(
    Room room,
    StickerItem item,
    StickerSendPlan plan,
    StickerConversion conversion,
    Map<String, Object?> content,
    Future<void> Function(StickerSendPlan, Map<String, Object?>) sendPlan,
  ) async {
    Map<String, Object?>? converted;
    try {
      converted = await StickerConvertedMedia.prepare(
        room,
        item,
        conversion,
        content,
      );
    } catch (e) {
      // The error's type only: no media, room or server details.
      Logs().w(
        'Sticker conversion failed (${e.runtimeType}), sending fallback',
      );
    }
    if (converted != null) return sendPlan(plan, converted);
    final fallback = plan.fallback;
    if (fallback == null || !fallback.possible) {
      throw StickerUnsendable(fallback?.reason);
    }
    return sendPlan(fallback, fallback.content!);
  }
}

/// A converted sticker that failed with nothing else to send.
class StickerUnsendable implements Exception {
  const StickerUnsendable(this.reason);
  final String? reason;
  @override
  String toString() => reason ?? 'This sticker can’t be sent to this chat.';
}
