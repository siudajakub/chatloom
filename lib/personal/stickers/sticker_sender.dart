// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat/conversation_source.dart';
import 'package:chatloom/pages/chat/trust_user_key_dialog.dart';
import 'package:chatloom/personal/matrix_error_text.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/error_reporter.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'sticker_library.dart';
import 'sticker_models.dart';
import 'sticker_send_plan.dart';

/// Sends stickers and GIFs from the panel, adapted to the room's network
/// ([StickerSendPlan]). Telegram keeps the panel open after a send and so
/// does ChatLoom; the item becomes the newest recent once the server has
/// accepted it.
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
    // The panel may be closed by the time the server answers: report on
    // the app's navigator.
    const reporter = ErrorReporter.action(null, action: ErrorAction.send);
    room
        .sendEvent(
          content,
          type: plan.type,
          threadRootEventId: thread,
          threadLastEventId: host.threadLastEventId,
        )
        .then<void>((eventId) {
          if (eventId == null) return;
          if (item.kind == StickerKind.gif) {
            library.useGif(item);
          } else {
            library.useSticker(item);
          }
        }, onError: reporter.onErrorCallback);
    return true;
  }
}
