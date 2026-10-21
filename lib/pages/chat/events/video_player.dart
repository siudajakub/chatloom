// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/personal/transcript_panel.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/file_description.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/utils/url_launcher.dart';
import 'package:chatloom/widgets/blur_hash.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../image_viewer/image_viewer.dart';
import 'outgoing_upload_progress.dart';

class EventVideoPlayer extends StatelessWidget {
  final Event event;
  final Timeline? timeline;
  final Color? textColor;
  final Color? linkColor;

  /// Corners of the frame; inside a media bubble, the bubble's own shape.
  final BorderRadius? borderRadius;

  const EventVideoPlayer(
    this.event, {
    this.timeline,
    this.textColor,
    this.linkColor,
    this.borderRadius,
    super.key,
  });

  static const String fallbackBlurHash = 'L5H2EC=PM+yV0g-mq.wG9c010J}I';

  @override
  Widget build(BuildContext context) {
    final supportsVideoPlayer = PlatformInfos.supportsVideoPlayer;

    final blurHash =
        (event.infoMap as Map<String, dynamic>).tryGet<String>(
          'xyz.amorgan.blurhash',
        ) ??
        fallbackBlurHash;
    final fileDescription = event.fileDescription;
    final infoMap = event.content.tryGetMap<String, Object?>('info');

    final durationInt = infoMap?.tryGet<int>('duration');
    final duration = durationInt == null
        ? null
        : Duration(milliseconds: durationInt);
    final borderRadius =
        this.borderRadius ?? BorderRadius.circular(NotionTokens.radius);
    // While an own video uploads its bubble shows the upload, and opening
    // it waits until the server has it.
    final uploading = isOutgoingUpload(event);
    // A caption continues the frame below, so the joint stays flush.
    final frameRadius = fileDescription == null
        ? borderRadius
        : borderRadius.copyWith(
            bottomLeft: Radius.zero, // design-lint: allow joins the caption
            bottomRight: Radius.zero, // design-lint: allow joins the caption
          );

    return LayoutBuilder(
      builder: (context, constraints) {
        // Same rule as images: the bubble's media width, aspect kept within
        // limits, tall reels cropped instead of narrowed.
        final frame = ConversationMedia.frame(
          maxWidth: constraints.maxWidth,
          width: infoMap?.tryGet<int>('w'),
          height: infoMap?.tryGet<int>('h'),
          maxHeight: ConversationMedia.maxHeightOf(context, constraints),
        );
        final width = frame.width;
        final height = frame.height;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: .min,
          spacing: 8,
          children: [
            Material(
              color: context.notion.colors.surface,
              borderRadius: frameRadius,
              child: InkWell(
                onTap: uploading
                    ? null
                    : () => supportsVideoPlayer
                          ? showImageViewer(context, event, timeline: timeline)
                          : event.saveFile(context),
                borderRadius: frameRadius,
                child: SizedBox(
                  width: width,
                  height: height,
                  child: Hero(
                    tag: event.eventId,
                    // Straight flight, as the viewer route uses.
                    createRectTween: NotionMediaHero.rectTween,
                    child: Stack(
                      children: [
                        if (event.hasThumbnail &&
                            AppSettings.showThumbnailsInTimeline.value)
                          MxcImage(
                            event: event,
                            cacheKey: event.transactionId ?? event.eventId,
                            cacheName: event.room.id,
                            isThumbnail: true,
                            width: width,
                            height: height,
                            fit: BoxFit.cover,
                            placeholder: (context) => BlurHash(
                              blurhash: blurHash,
                              width: width,
                              height: height,
                              fit: BoxFit.cover,
                            ),
                          )
                        else
                          BlurHash(
                            blurhash: blurHash,
                            width: width,
                            height: height,
                            fit: BoxFit.cover,
                          ),
                        Center(
                          child: uploading
                              ? OutgoingUploadOverlay(
                                  progress: uploadProgressOf(event),
                                )
                              : DecoratedBox(
                                  decoration: const ShapeDecoration(
                                    color: NotionMediaColors.scrim,
                                    shape: CircleBorder(),
                                  ),
                                  child: Padding(
                                    padding: const EdgeInsets.all(
                                      NotionSpace.sm,
                                    ),
                                    child: Icon(
                                      supportsVideoPlayer
                                          ? Icons.play_arrow_outlined
                                          : Icons.file_download_outlined,
                                      color: NotionMediaColors.onScrim,
                                      size: NotionSize.iconLg,
                                    ),
                                  ),
                                ),
                        ),
                        if (duration != null)
                          Positioned(
                            bottom: NotionSpace.xs,
                            left: NotionSpace.md,
                            child: DecoratedBox(
                              decoration: const BoxDecoration(
                                color: NotionMediaColors.scrim,
                                borderRadius: NotionRadius.pillAll,
                              ),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: NotionSpace.xs,
                                  vertical: NotionSpace.xxs,
                                ),
                                child: Text(
                                  NotionMediaPlaybackControls.formatTime(
                                    duration,
                                  ),
                                  style: NotionType.caption.copyWith(
                                    color: NotionMediaColors.onScrim,
                                  ),
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
            // Transcript slot (transcription feature): the panel renders
            // nothing unless the paired worker can transcribe this video.
            if (TranscriptPanel.mayTranscribe(event))
              SizedBox(
                width: width,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: NotionSpace.sm,
                  ),
                  child: TranscriptPanel(
                    event: event,
                    foregroundColor: textColor,
                  ),
                ),
              ),
            if (fileDescription != null &&
                textColor != null &&
                linkColor != null)
              SizedBox(
                width: width,
                child: Padding(
                  padding: NotionBubble.padding.copyWith(top: 0),
                  child: Linkify(
                    text: fileDescription,
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
      },
    );
  }
}
