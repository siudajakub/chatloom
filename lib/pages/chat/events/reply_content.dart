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
import 'package:chatloom/personal/media_transcript.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/view_once_openings.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/matrix_locals.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// The quoted original of a reply, as a muted pill above the reply bubble
/// (see [ConversationReplyQuote]). Photos and videos show a thumbnail; a
/// transcribed voice note or round video shows its gist under its label,
/// so the reader knows which one the reply answers without playing it.
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

  /// Test seam for the transcript of a quoted voice note; production
  /// resolves the account's [PersonalClient].
  final PersonalClient? personalClient;

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
    @visibleForTesting this.personalClient,
  });

  static const _thumbnailTypes = {MessageTypes.Image, MessageTypes.Video};

  /// Voice notes and round videos: spoken messages whose quote names only
  /// their kind, so their transcript says which one it was.
  static bool spoken(Event event) =>
      event.type == EventTypes.Message &&
      switch (event.messageType) {
        MessageTypes.Audio => event.content['org.matrix.msc3245.voice'] is Map,
        MessageTypes.Video =>
          RoundVideoDescriptor.fromContent(event.content) != null,
        _ => false,
      };

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
    final text = personalPreviewLabel(
      display,
      i18n: MatrixLocals(L10n.of(context)),
    );
    if (!deleted && !isUndecryptable(display) && spoken(display)) {
      return MediaTranscriptBuilder(
        event: display,
        personalClient: personalClient,
        builder: (context, transcript) => _quote(
          context,
          display,
          text,
          detail: transcript?.quoteText,
          media: media,
          thumbnail: thumbnail,
        ),
      );
    }
    return _quote(
      context,
      display,
      text,
      deleted: deleted,
      media: media,
      thumbnail: thumbnail,
    );
  }

  Widget _quote(
    BuildContext context,
    Event display,
    String text, {
    String? detail,
    bool deleted = false,
    bool media = false,
    bool thumbnail = false,
  }) {
    // Part of the bubble: a double tap reacts, a single tap jumps.
    return ConversationMessageChromeTap(
      child: ConversationReplyQuote(
        text: text,
        detail: detail,
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
