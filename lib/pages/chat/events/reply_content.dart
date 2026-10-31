// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/events/deleted_message.dart';
import 'package:chatloom/personal/deleted_messages.dart';
import 'package:chatloom/personal/encryption/undecryptable_messages.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/view_once_openings.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// The quoted original of a reply, as a muted pill above the reply bubble
/// (see [ConversationReplyQuote]). Photos and videos show a thumbnail.
class ReplyContent extends StatelessWidget {
  final Event replyEvent;
  final Timeline? timeline;
  final Color fill;
  final Color textColor;

  /// Side of the reply that quotes [replyEvent], for alignment.
  final bool outgoing;
  final Widget? caption;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const ReplyContent(
    this.replyEvent, {
    super.key,
    required this.fill,
    required this.textColor,
    this.outgoing = false,
    this.timeline,
    this.caption,
    this.onTap,
    this.onLongPress,
  });

  static const _thumbnailTypes = {MessageTypes.Image, MessageTypes.Video};

  @override
  Widget build(BuildContext context) {
    final timeline = this.timeline;
    final display = timeline != null
        ? replyEvent.getDisplayEvent(timeline)
        : replyEvent;
    // A deleted original reads like its own placeholder (icon, italic).
    final deleted = isDeletedForDisplay(display);
    final media =
        !deleted &&
        !isUndecryptable(display) &&
        _thumbnailTypes.contains(display.messageType);
    // A video without a thumbnail has nothing to download: a static glyph
    // instead of a loader that never resolves.
    // Unopened view-once media shows nothing of itself, here neither.
    final thumbnail =
        media &&
        !ViewOnceOpenings.isSealed(display) &&
        (display.hasThumbnail || display.messageType == MessageTypes.Image);
    // Part of the bubble: a double tap reacts, a single tap jumps.
    return ConversationMessageChromeTap(
      child: ConversationReplyQuote(
        text: personalPreviewLabel(
          display,
          i18n: MatrixLocals(L10n.of(context)),
        ),
        fill: fill,
        textColor: textColor,
        outgoing: outgoing,
        caption: caption,
        textIcon: deleted ? deletedMessageIcon(deletionOf(display).kind) : null,
        leading: thumbnail
            ? MxcImage(
                event: display,
                // The memory cache: remounting a quote (scrolling, rebuilds)
                // does not read and decrypt the attachment again.
                cacheKey: 'reply:${display.eventId}',
                cacheName: display.room.id,
                isThumbnail: true,
                fit: BoxFit.cover,
                width: NotionBubble.quoteThumbnail,
                height: NotionBubble.quoteThumbnail,
              )
            : media
            ? SizedBox.square(
                dimension: NotionBubble.quoteThumbnail,
                child: Icon(
                  Icons.videocam_outlined,
                  size: NotionSize.iconSm,
                  color: textColor,
                ),
              )
            : null,
        onTap: onTap,
        onLongPress: onLongPress,
        semanticLabel: L10n.of(context).showOriginalMessage,
      ),
    );
  }
}
