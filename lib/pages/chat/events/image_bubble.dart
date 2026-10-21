// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math';

import 'package:chatloom/config/app_config.dart';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/file_description.dart';
import 'package:chatloom/utils/url_launcher.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:flutter_linkify/flutter_linkify.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../../../widgets/blur_hash.dart';

class ImageBubble extends StatelessWidget {
  final Event event;
  final bool tapToView;
  final BoxFit fit;
  final Color? backgroundColor;
  final Color? textColor;
  final Color? linkColor;
  final bool thumbnailOnly;
  final bool animated;
  final double width;
  final double height;
  final void Function()? onTap;
  final BorderRadius? borderRadius;
  final Timeline? timeline;

  const ImageBubble(
    this.event, {
    this.tapToView = true,
    this.backgroundColor,
    this.fit = BoxFit.contain,
    this.thumbnailOnly = true,
    this.width = 400,
    this.height = 300,
    this.animated = false,
    this.onTap,
    this.borderRadius,
    this.timeline,
    this.textColor,
    this.linkColor,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    var borderRadius =
        this.borderRadius ?? BorderRadius.circular(NotionTokens.radius);

    final fileDescription = event.fileDescription;
    final textColor = this.textColor;

    if (fileDescription != null) {
      // The caption continues the image below: the joint stays flush.
      borderRadius = borderRadius.copyWith(
        bottomLeft: Radius.zero, // design-lint: allow joins the caption
        bottomRight: Radius.zero, // design-lint: allow joins the caption
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final width =
            constraints.maxWidth.isFinite && this.width > constraints.maxWidth
            ? constraints.maxWidth
            : this.width;
        final scaled = this.width > 0
            ? this.height * width / this.width
            : this.height;
        // Tall media is cropped (cover) rather than taller than the screen.
        final height = min(
          scaled,
          ConversationMedia.maxHeightOf(context, constraints),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: .min,
          spacing: 8,
          children: [
            Material(
              color: Colors.transparent,
              clipBehavior: Clip.hardEdge,
              shape: RoundedRectangleBorder(
                borderRadius: borderRadius,
                side: BorderSide(
                  color: event.messageType == MessageTypes.Sticker
                      ? Colors.transparent
                      : theme.dividerColor,
                ),
              ),
              child: InkWell(
                onTap: onTap,
                borderRadius: borderRadius,
                child: Stack(
                  alignment: Alignment.center,
                  children: [
                    Hero(
                      tag: event.eventId,
                      // Straight flight, as the viewer route uses.
                      createRectTween: NotionMediaHero.rectTween,
                      child: AppSettings.showThumbnailsInTimeline.value
                          ? MxcImage(
                              cacheKey: event.transactionId ?? event.eventId,
                              cacheName: event.room.id,
                              event: event,
                              width: width,
                              height: height,
                              fit: fit,
                              animated: animated,
                              isThumbnail: thumbnailOnly,
                              placeholder:
                                  event.messageType == MessageTypes.Sticker
                                  ? null
                                  : (_) => _ImageBubblePlaceholder(
                                      event: event,
                                      width: width,
                                      height: height,
                                      fit: fit,
                                    ),
                            )
                          : _ImageBubblePlaceholder(
                              event: event,
                              width: width,
                              height: height,
                              fit: fit,
                            ),
                    ),
                  ],
                ),
              ),
            ),
            if (fileDescription != null && textColor != null)
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

class _ImageBubblePlaceholder extends StatelessWidget {
  final Event event;
  final double width, height;
  final BoxFit fit;

  const _ImageBubblePlaceholder({
    required this.event,
    required this.width,
    required this.height,
    required this.fit,
  });

  @override
  Widget build(BuildContext context) {
    final blurHashString =
        event.infoMap.tryGet<String>('xyz.amorgan.blurhash') ??
        'LEHV6nWB2yk8pyo0adR*.7kCMdnj';
    return SizedBox(
      width: width,
      height: height,
      child: BlurHash(
        blurhash: blurHashString,
        width: width,
        height: height,
        fit: fit,
      ),
    );
  }
}
