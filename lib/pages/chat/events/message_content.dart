// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/events/poll.dart';
import 'package:chatloom/pages/chat/events/round_video_bridge_message.dart';
import 'package:chatloom/pages/chat/events/round_video_message.dart';
import 'package:chatloom/pages/chat/events/undecryptable_message.dart';
import 'package:chatloom/pages/chat/events/video_player.dart';
import 'package:chatloom/pages/chat/media_album.dart';
import 'package:chatloom/pages/image_viewer/image_viewer.dart';
import 'package:chatloom/personal/deleted_messages.dart';
import 'package:chatloom/personal/encryption/undecryptable_messages.dart';
import 'package:chatloom/personal/instagram_share.dart';
import 'package:chatloom/personal/media/gallery_content.dart';
import 'package:chatloom/personal/round_video/round_playback_queue.dart';
import 'package:chatloom/personal/stickers/sticker_message_actions.dart';
import 'package:chatloom/personal/transcript_panel.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import '../../../config/app_config.dart';
import '../../../utils/event_checkbox_extension.dart';
import '../../../utils/file_description.dart';
import '../../../utils/platform_infos.dart';
import '../../../utils/url_launcher.dart';
import 'audio_player.dart';
import 'cute_events.dart';
import 'deleted_message.dart';
import 'gallery_message.dart';
import 'html_message.dart';
import 'image_bubble.dart';
import 'inline_loop_video.dart';
import 'instagram_share_preview.dart';
import 'link_preview.dart';
import 'map_bubble.dart';
import 'message_download_content.dart';
import 'sticker_event.dart';
import 'view_once_message.dart';

class MessageContent extends StatelessWidget {
  final Event event;
  final Color textColor;
  final Color linkColor;
  final void Function(Event)? onInfoTab;
  final BorderRadius borderRadius;
  final Timeline timeline;
  final bool selected;
  final Set<String> bigEmojis;

  /// Time/edited/sending state drawn on a round video's circle.
  final Widget? roundStatus;

  /// Conversation side; defaults to the event sender being this account.
  final bool? outgoing;

  /// An album this (newest) photo/video leads: drawn as one grid, oldest
  /// first, with this event's caption below.
  final List<Event>? album;

  const MessageContent(
    this.event, {
    this.onInfoTab,
    super.key,
    required this.timeline,
    required this.textColor,
    required this.linkColor,
    required this.borderRadius,
    required this.selected,
    required this.bigEmojis,
    this.roundStatus,
    this.outgoing,
    this.album,
  });

  /// True when [event] renders as a round (circle) rather than a bubble:
  /// Telegram round videos and limited-media placeholders. Callers use it to
  /// render a chromeless bubble and move the status onto the circle.
  static bool rendersRound(Event event) {
    if (event.redacted) return false;
    if (!RoundMediaPolicy.fromContent(event.content).canPlay) return true;
    return {EventTypes.Message, EventTypes.Encrypted}.contains(event.type) &&
        event.messageType == MessageTypes.Video &&
        RoundVideoDescriptor.fromContent(event.content) != null;
  }

  /// True when [event] is a sticker (image, Lottie or video): Telegram
  /// draws it without a bubble fill.
  static bool rendersSticker(Event event) =>
      !event.redacted &&
      (event.messageType == MessageTypes.Sticker ||
          StickerEvents.isImageSticker(event) ||
          InlineLoopVideo.isVideoSticker(event));

  @override
  Widget build(BuildContext context) {
    const fontSize = AppConfig.messageFontSize;
    final buttonTextColor = textColor;
    if (event.redacted) {
      return RedactionWidget(
        event: event,
        buttonTextColor: buttonTextColor,
        onInfoTab: onInfoTab,
        fontSize: fontSize,
      );
    }
    final mediaPolicy = RoundMediaPolicy.fromContent(event.content);
    // This precedes every media branch, including protected bridge notices.
    // Never construct an ordinary thumbnail/player for limited media.
    final own = outgoing ?? event.senderId == event.room.client.userID;
    if (!event.redacted && !mediaPolicy.canPlay) {
      return RoundVideoMessage(
        event,
        textColor: textColor,
        showThumbnail: false,
        outgoing: own,
        statusOverlay: roundStatus,
      );
    }
    // Ordinary and merged chats both land here, so a message this device
    // cannot decrypt looks and recovers the same way in each.
    if (isUndecryptable(event)) {
      return UndecryptableMessage(event, textColor: textColor);
    }
    // Instagram view-once photo/video: "Tap to view" until opened here.
    final viewOnce = mediaPolicy.viewOnceMode;
    if (viewOnce != null &&
        {MessageTypes.Image, MessageTypes.Video}.contains(event.messageType)) {
      return ViewOnceMessage(
        event,
        mode: viewOnce,
        timeline: timeline,
        borderRadius: borderRadius,
        textColor: textColor,
        linkColor: linkColor,
      );
    }
    // MSC4274 gallery: one message, many photos/videos/files.
    final gallery = GalleryContent.of(event);
    if (gallery != null) {
      final media = GalleryMessage(
        event,
        gallery: gallery,
        borderRadius: borderRadius,
        textColor: textColor,
        linkColor: linkColor,
      );
      final caption = gallery.caption;
      if (caption == null) return media;
      return _MediaCaption(
        media: media,
        caption: caption,
        width: NotionBubble.mediaMaxWidth,
        textColor: textColor,
        linkColor: linkColor,
      );
    }
    final album = this.album;
    if (album != null && album.length > 1) {
      final grid = MediaAlbumGrid(
        events: album,
        borderRadius: borderRadius,
        timelineFor: (_) => timeline,
      );
      final caption = event.fileDescription;
      if (caption == null) return grid;
      return _MediaCaption(
        media: grid,
        caption: caption,
        width: NotionBubble.mediaMaxWidth,
        textColor: textColor,
        linkColor: linkColor,
      );
    }
    switch (event.type) {
      case EventTypes.Message:
      case EventTypes.Encrypted:
      case EventTypes.Sticker:
        switch (event.messageType) {
          case MessageTypes.Image:
          case MessageTypes.Sticker:
            if (event.redacted) continue textmessage;
            // Stickers sent or bridged as images are stickers too (a
            // Messenger room gets ChatLoom's stickers as `m.image`).
            final sticker =
                event.messageType == MessageTypes.Sticker ||
                StickerEvents.isImageSticker(event);
            // A video sticker (`m.sticker` with a video file) loops inline.
            if (InlineLoopVideo.isVideoSticker(event)) {
              final box = InlineLoopVideo.stickerBox(
                event,
                ConversationMedia.stickerSide(
                  context,
                  desktop: PlatformInfos.isDesktop,
                ),
              );
              return InlineLoopVideo(
                event,
                width: box.width,
                height: box.height,
                borderRadius: NotionRadius.mdAll,
                timeline: timeline,
              );
            }
            final w = event.content
                .tryGetMap<String, Object?>('info')
                ?.tryGet<int>('w');
            final h = event.content
                .tryGetMap<String, Object?>('info')
                ?.tryGet<int>('h');
            // Photos follow the one media rule (bubble width, aspect kept
            // within limits, cropped beyond); stickers are whole and about
            // half the screen's short side (Telegram).
            final box = sticker
                ? ConversationMedia.stickerFrame(
                    ConversationMedia.stickerSide(
                      context,
                      desktop: PlatformInfos.isDesktop,
                    ),
                    width: w,
                    height: h,
                  )
                : ConversationMedia.frame(
                    maxWidth: NotionBubble.mediaMaxWidth,
                    width: w,
                    height: h,
                  );
            final fit = sticker ? BoxFit.contain : BoxFit.cover;
            return ImageBubble(
              event,
              width: box.width,
              height: box.height,
              fit: fit,
              sticker: sticker,
              borderRadius: borderRadius,
              timeline: timeline,
              textColor: textColor,
              onTap: sticker
                  // A pack sticker opens its pack (Telegram).
                  ? () => openStickerFromEvent(
                      context,
                      event,
                      fallback: () =>
                          showImageViewer(context, event, timeline: timeline),
                    )
                  : () => showImageViewer(context, event, timeline: timeline),
            );
          case CuteEventContent.eventType:
            return CuteContent(event);
          case MessageTypes.Audio:
            if (PlatformInfos.isMobile ||
                PlatformInfos.isMacOS ||
                PlatformInfos.isWeb ||
                PlatformInfos.isLinux) {
              // Voice fills the bubble like other media, up to the cap.
              return ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: NotionBubble.mediaMaxWidth,
                ),
                child: AudioPlayerWidget(
                  event,
                  color: textColor,
                  linkColor: linkColor,
                  fontSize: fontSize,
                  // Read only when the note ends (voice continuation).
                  continuationHistory: () => timeline.events,
                ),
              );
            }
            return MessageDownloadContent(
              event,
              textColor: textColor,
              linkColor: linkColor,
            );
          case MessageTypes.Video:
            if (RoundVideoDescriptor.fromContent(
                  event.content,
                  redacted: event.redacted,
                ) !=
                null) {
              return RoundVideoBridgeMessage(
                event,
                textColor: textColor,
                outgoing: own,
                statusOverlay: roundStatus,
                // Built only on an explicit play, not on every row build.
                continuationQueue: () =>
                    RoundPlaybackQueue.after(event, timeline.events),
              );
            }
            // Bridged GIFs and Telegram video stickers: muted inline loops.
            if (InlineLoopVideo.applies(event)) {
              final sticker = InlineLoopVideo.isVideoSticker(event);
              final info = event.content.tryGetMap<String, Object?>('info');
              return LayoutBuilder(
                builder: (context, constraints) {
                  final box = sticker
                      ? InlineLoopVideo.stickerBox(
                          event,
                          ConversationMedia.stickerSide(
                            context,
                            desktop: PlatformInfos.isDesktop,
                          ),
                        )
                      : ConversationMedia.frame(
                          maxWidth: constraints.maxWidth,
                          width: info?.tryGet<num>('w'),
                          height: info?.tryGet<num>('h'),
                          maxHeight: ConversationMedia.maxHeightOf(
                            context,
                            constraints,
                          ),
                        );
                  final loop = InlineLoopVideo(
                    event,
                    width: box.width,
                    height: box.height,
                    borderRadius: sticker ? NotionRadius.mdAll : borderRadius,
                    timeline: timeline,
                  );
                  final caption = sticker ? null : event.fileDescription;
                  if (caption == null) return loop;
                  return _MediaCaption(
                    media: loop,
                    caption: caption,
                    width: box.width,
                    textColor: textColor,
                    linkColor: linkColor,
                  );
                },
              );
            }
            return EventVideoPlayer(
              event,
              textColor: textColor,
              linkColor: linkColor,
              timeline: timeline,
              borderRadius: borderRadius,
            );
          case MessageTypes.File:
            final download = MessageDownloadContent(
              event,
              textColor: textColor,
              linkColor: linkColor,
            );
            // Audio/video sent as a file: transcript slot (transcription
            // feature), empty unless the paired worker supports it.
            if (!TranscriptPanel.mayTranscribe(event)) return download;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                download,
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    NotionSpace.md,
                    0,
                    NotionSpace.md,
                    NotionSpace.xs,
                  ),
                  child: TranscriptPanel(
                    event: event,
                    foregroundColor: textColor,
                  ),
                ),
              ],
            );
          case MessageTypes.Location:
            if (event.redacted) continue textmessage;
            final geoValue = event.content.tryGet<String>('geo_uri');
            final geoUri = geoValue == null ? null : Uri.tryParse(geoValue);
            if (geoUri != null && geoUri.scheme == 'geo') {
              final latlong = geoUri.path
                  .split(';')
                  .first
                  .split(',')
                  .map(double.tryParse)
                  .toList();
              if (latlong.length == 2 &&
                  latlong.first != null &&
                  latlong.last != null &&
                  latlong.first!.isFinite &&
                  latlong.last!.isFinite &&
                  latlong.first!.abs() <= 90 &&
                  latlong.last!.abs() <= 180) {
                return MapBubble(
                  onTap: () =>
                      UrlLauncher(context, geoUri.toString()).launchUrl(),
                  latitude: latlong.first!,
                  longitude: latlong.last!,
                );
              }
            }
            continue textmessage;
          case MessageTypes.Text:
          case MessageTypes.Notice:
          case MessageTypes.Emote:
          case MessageTypes.None:
          textmessage:
          default:
            if (event.redacted) {
              return RedactionWidget(
                event: event,
                buttonTextColor: buttonTextColor,
                onInfoTab: onInfoTab,
                fontSize: fontSize,
              );
            }
            var html = AppSettings.renderHtml.value && event.isRichMessage
                ? event.formattedText
                : event.body.replaceAll('<', '&lt;').replaceAll('>', '&gt;');
            if (event.messageType == MessageTypes.Emote) {
              html = '* $html';
            }

            final bigEmotes =
                !event.isRichMessage && bigEmojis.contains(event.body);

            final previews = BridgedLinkPreview.fromContent(event.content);
            final share = event.messageType == MessageTypes.Text
                ? InstagramShare.fromText(event.body)
                : null;
            final text = Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: HtmlMessage(
                html: html,
                textColor: textColor,
                room: event.room,
                // Settings → Appearance → "Emoji-only messages".
                fontSize:
                    AppConfig.messageFontSize *
                    (bigEmotes
                        ? NotionDisplayPreferences.of(context).jumboEmoji.factor
                        : 1),
                linkStyle: TextStyle(
                  color: linkColor,
                  fontSize: AppConfig.messageFontSize,
                  decoration: TextDecoration.underline,
                  decorationColor: linkColor,
                ),
                onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
                eventId: event.eventId,
                checkboxCheckedEvents: event.aggregatedEvents(
                  timeline,
                  EventCheckboxRoomExtension.relationshipType,
                ),
              ),
            );
            // An Instagram link plays natively; it replaces the bridge's
            // preview card of the same link.
            if (share != null) {
              return Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  InstagramSharePreview(share: share, event: event),
                  Padding(padding: NotionBubble.padding, child: text),
                ],
              );
            }
            if (previews.isEmpty || !AppSettings.showLinkPreviews.value) {
              return text;
            }
            // The bridge's preview of the first link, under the text.
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                text,
                Padding(
                  padding: const EdgeInsets.only(
                    top: NotionSpace.xxs,
                    bottom: NotionSpace.xxs,
                  ),
                  child: LinkPreviewAttachment(
                    event: event,
                    preview: previews.first,
                    textColor: textColor,
                  ),
                ),
              ],
            );
        }
      case PollEventContent.startType:
        if (event.redacted) {
          return RedactionWidget(
            event: event,
            buttonTextColor: buttonTextColor,
            onInfoTab: onInfoTab,
            fontSize: fontSize,
          );
        }
        return PollWidget(
          event: event,
          timeline: timeline,
          textColor: textColor,
          linkColor: linkColor,
        );
      case EventTypes.CallInvite:
        return FutureBuilder<User?>(
          future: event.fetchSenderUser(),
          builder: (context, snapshot) {
            return _ButtonContent(
              label: L10n.of(context).startedACall(
                snapshot.data?.calcDisplayname() ??
                    event.senderFromMemoryOrFallback.calcDisplayname(),
              ),
              icon: '📞',
              textColor: buttonTextColor,
              onPressed: () => onInfoTab?.call(event),
              fontSize: fontSize,
            );
          },
        );
      default:
        return FutureBuilder<User?>(
          future: event.fetchSenderUser(),
          builder: (context, snapshot) {
            return _ButtonContent(
              label: L10n.of(context).userSentUnknownEvent(
                snapshot.data?.calcDisplayname() ??
                    event.senderFromMemoryOrFallback.calcDisplayname(),
                event.type,
              ),
              icon: 'ℹ️',
              textColor: buttonTextColor,
              onPressed: () => onInfoTab?.call(event),
              fontSize: fontSize,
            );
          },
        );
    }
  }
}

/// The placeholder of a deleted message: "Message deleted", "You deleted
/// this message", "Message disappeared" or "Deleted by {name}" (see
/// [deletedLabel]), muted and italic after its icon.
class RedactionWidget extends StatelessWidget {
  const RedactionWidget({
    super.key,
    required this.event,
    required this.buttonTextColor,
    required this.onInfoTab,
    required this.fontSize,
  });

  final Event event;
  final Color buttonTextColor;
  final void Function(Event p1)? onInfoTab;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    final l10n = L10n.of(context);
    Widget label() {
      final info = deletionOf(event);
      return DeletedMessageLabel(
        label: deletionText(info, l10n),
        kind: info.kind,
        color: buttonTextColor.withValues(alpha: .7),
        style: NotionType.body.copyWith(fontSize: fontSize),
      );
    }

    // Only "Deleted by {name}" needs a name that may not be loaded yet.
    final redaction = event.redactedBecause;
    final needsName = deletionOf(event).kind == DeletedKind.byOther;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onInfoTab == null ? null : () => onInfoTab!(event),
      child: Padding(
        padding: NotionBubble.textLine,
        child: needsName && redaction != null
            ? FutureBuilder<User?>(
                future: redaction.fetchSenderUser(),
                builder: (context, _) => label(),
              )
            : label(),
      ),
    );
  }
}

class _ButtonContent extends StatelessWidget {
  final void Function() onPressed;
  final String label;
  final String icon;
  final Color? textColor;
  final double fontSize;

  const _ButtonContent({
    required this.label,
    required this.icon,
    required this.textColor,
    required this.onPressed,
    required this.fontSize,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: InkWell(
        onTap: onPressed,
        child: Text(
          '$icon  $label',
          style: TextStyle(color: textColor, fontSize: fontSize),
        ),
      ),
    );
  }
}

/// Media with its caption below, inside the media bubble.
class _MediaCaption extends StatelessWidget {
  const _MediaCaption({
    required this.media,
    required this.caption,
    required this.width,
    required this.textColor,
    required this.linkColor,
  });

  final Widget media;
  final String caption;
  final double width;
  final Color textColor;
  final Color linkColor;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    spacing: NotionSpace.xs,
    children: [
      media,
      ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width),
        child: Padding(
          padding: NotionBubble.padding.copyWith(top: 0),
          child: Linkify(
            text: caption,
            textWidthBasis: TextWidthBasis.longestLine,
            textScaleFactor: MediaQuery.textScalerOf(context).scale(1),
            style: TextStyle(
              color: textColor,
              fontSize: AppConfig.messageFontSize,
            ),
            options: const LinkifyOptions(humanize: false),
            linkStyle: TextStyle(
              color: linkColor,
              fontSize: AppConfig.messageFontSize,
              decoration: TextDecoration.underline,
              decorationColor: linkColor,
            ),
            onOpen: (url) => UrlLauncher(context, url.url).launchUrl(),
          ),
        ),
      ),
    ],
  );
}
