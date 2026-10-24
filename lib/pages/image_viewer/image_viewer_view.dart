// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/events/round_video_bridge_message.dart';
import 'package:chatloom/pages/chat/events/round_video_message.dart';
import 'package:chatloom/pages/image_viewer/image_viewer_chrome.dart';
import 'package:chatloom/pages/image_viewer/pointers_listener.dart';
import 'package:chatloom/pages/image_viewer/progressive_photo.dart';
import 'package:chatloom/pages/image_viewer/video_player.dart';
import 'package:chatloom/personal/media/media_export_actions.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/event_extension.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/hover_builder.dart';
import 'package:chatloom/widgets/mxc_image.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import 'image_viewer.dart';

class ImageViewerView extends StatelessWidget {
  final ImageViewerController controller;

  const ImageViewerView(this.controller, {super.key});

  @override
  Widget build(BuildContext context) {
    final iconButtonStyle = IconButton.styleFrom(
      backgroundColor: NotionMediaColors.stageScrim,
      foregroundColor: NotionMediaColors.onScrim,
    );
    final drag = controller.dismiss;
    // Chrome fades with the route and a dismiss swipe; a tap on the media
    // hides and shows it (Telegram, Messenger).
    Widget chrome(Widget child) => ValueListenableBuilder<bool>(
      valueListenable: controller.chromeVisible,
      child: child,
      builder: (context, visible, child) =>
          NotionMediaChrome(drag: drag, visible: visible, child: child!),
    );
    // Header, caption, actions and arrows follow the page on screen (once
    // per page change, not per scroll frame).
    Widget perPage(Widget Function(BuildContext context, Event event) build) =>
        ValueListenableBuilder<int>(
          valueListenable: controller.currentIndex,
          builder: (context, _, _) => build(context, controller.currentEvent),
        );
    return CallbackShortcuts(
      bindings: controller.shortcuts,
      child: Focus(
        focusNode: controller.focusNode,
        autofocus: true,
        child: GestureDetector(
          onTap: () => Navigator.of(context).pop(),
          child: Scaffold(
            backgroundColor: Colors.transparent,
            extendBodyBehindAppBar: true,
            appBar: PreferredSize(
              preferredSize: const Size.fromHeight(kToolbarHeight),
              child: chrome(
                AppBar(
                  elevation: 0,
                  scrolledUnderElevation: 0,
                  flexibleSpace: const ImageViewerTopScrim(),
                  leading: IconButton(
                    style: iconButtonStyle,
                    icon: const Icon(Icons.close),
                    onPressed: Navigator.of(context).pop,
                    color: NotionMediaColors.onScrim,
                    tooltip: L10n.of(context).close,
                  ),
                  backgroundColor: Colors.transparent,
                  titleSpacing: 0,
                  title: perPage(
                    (context, event) => ImageViewerTitle(
                      event: event,
                      index: controller.currentIndex.value,
                      count: controller.allEvents.length,
                    ),
                  ),
                  actions: [perPage(_actions)],
                ),
              ),
            ),
            body: HoverBuilder(
              builder: (context, hovered) => Stack(
                children: [
                  // Fades in with the route and out while the media is swiped
                  // away.
                  Positioned.fill(
                    child: perPage(
                      (context, event) => NotionMediaBackdrop(
                        drag: drag,
                        color: event.messageType == MessageTypes.Video
                            ? NotionMediaColors.stageScrim
                            : NotionMediaColors.viewer,
                      ),
                    ),
                  ),
                  NotionDismissTransform(
                    drag: drag,
                    child: PointersListener(
                      builder: (context, moreThanOnePointer) =>
                          PageView.builder(
                            physics: !moreThanOnePointer
                                ? BouncingScrollPhysics()
                                : NeverScrollableScrollPhysics(),
                            scrollDirection: Axis.horizontal,
                            controller: controller.pageController,
                            onPageChanged: controller.onPageChanged,
                            itemCount: controller.allEvents.length,
                            itemBuilder: (context, i) => _withCaptionInset(
                              _page(context, controller.allEvents[i]),
                            ),
                          ),
                    ),
                  ),
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: chrome(
                      perPage(
                        (context, event) => ImageViewerCaption(
                          event: event,
                          onHeight: (height) =>
                              controller.captionInset.value = height,
                        ),
                      ),
                    ),
                  ),
                  if (hovered)
                    Positioned.fill(
                      child: perPage(
                        (context, _) => Stack(
                          children: [
                            if (controller.canGoBack)
                              Align(
                                alignment: .centerLeft,
                                child: chrome(
                                  Padding(
                                    padding: const EdgeInsets.all(
                                      NotionSpace.sm,
                                    ),
                                    child: IconButton(
                                      style: iconButtonStyle,
                                      tooltip: L10n.of(context).previous,
                                      icon: const Icon(
                                        Icons.keyboard_arrow_left_outlined,
                                      ),
                                      onPressed: controller.prevImage,
                                    ),
                                  ),
                                ),
                              ),
                            if (controller.canGoNext)
                              Align(
                                alignment: .centerRight,
                                child: chrome(
                                  Padding(
                                    padding: const EdgeInsets.all(
                                      NotionSpace.sm,
                                    ),
                                    child: IconButton(
                                      style: iconButtonStyle,
                                      tooltip: L10n.of(context).next,
                                      icon: const Icon(
                                        Icons.keyboard_arrow_right_outlined,
                                      ),
                                      onPressed: controller.nextImage,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Forward, save (gallery on Android), save as, share, copy image: the
  /// export entries follow the same protected-media gate as the message
  /// menu.
  Widget _actions(BuildContext context, Event event) {
    final policy = RoundMediaPolicy.fromContent(event.content);
    final round =
        RoundVideoDescriptor.fromContent(
          event.content,
          redacted: event.redacted,
        ) !=
        null;
    // Local link assets have no server event that can be forwarded.
    final canForward =
        event.content['chatloom.local_media'] != true &&
        !event.redacted &&
        policy.canForward &&
        (!round ||
            TelegramRoundService.of(event.room.client).canNativeForward(event));
    final canExport = controller.canExport(event);
    return NotionMediaActionsButton(
      actions: [
        NotionMediaAction(
          label: round ? 'Forward in Telegram' : 'Forward',
          icon: Icons.forward_outlined,
          onPressed: canForward ? controller.forwardAction : null,
        ),
        NotionMediaAction(
          label: mediaSaveLabel(event),
          icon: Icons.download_outlined,
          onPressed: canExport
              ? () => controller.saveFileAction(context)
              : null,
        ),
        if (mediaOffersSaveAs())
          NotionMediaAction(
            label: 'Save as…',
            icon: Icons.save_as_outlined,
            onPressed: canExport
                ? () => controller.saveFileAsAction(context)
                : null,
          ),
        if (PlatformInfos.isMobile || PlatformInfos.isMacOS)
          NotionMediaAction(
            label: L10n.of(context).share,
            icon: Icons.adaptive.share_outlined,
            onPressed: canExport
                ? () => controller.shareFileAction(context)
                : null,
          ),
        if (event.canCopyImage)
          NotionMediaAction(
            label: 'Copy image',
            icon: Icons.copy_all_outlined,
            onPressed: () => controller.copyImageAction(context),
          ),
      ],
    );
  }

  /// Keeps a page's own bottom elements (loader, retry, video transport)
  /// above the caption.
  Widget _withCaptionInset(Widget page) => ValueListenableBuilder<double>(
    valueListenable: controller.captionInset,
    child: page,
    builder: (context, inset, page) {
      if (inset <= 0) return page!;
      final media = MediaQuery.of(context);
      return MediaQuery(
        data: media.copyWith(
          padding: media.padding.copyWith(bottom: media.padding.bottom + inset),
        ),
        child: page!,
      );
    },
  );

  Widget _page(BuildContext context, Event event) {
    final policy = RoundMediaPolicy.fromContent(event.content);
    final round =
        RoundVideoDescriptor.fromContent(
          event.content,
          redacted: event.redacted,
        ) !=
        null;
    if (!policy.canPlay || round || event.redacted) {
      return _VerticalDismiss(
        controller: controller,
        child: Padding(
          padding: const EdgeInsets.only(top: 52),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              // No thumbnail to fly from: it fades and scales in.
              child: NotionMediaHero(
                tag: null,
                child: round
                    ? RoundVideoBridgeMessage(
                        event,
                        key: ValueKey((
                          event.room.client,
                          event.room.id,
                          event.eventId,
                        )),
                        textColor: NotionMediaColors.onScrim,
                        enlargeOnPlay: false,
                      )
                    : RoundVideoMessage(
                        event,
                        textColor: NotionMediaColors.onScrim,
                        showThumbnail: false,
                        enlargeOnPlay: false,
                      ),
              ),
            ),
          ),
        ),
      );
    }
    switch (event.messageType) {
      case MessageTypes.Video:
        return _VerticalDismiss(
          controller: controller,
          child: Padding(
            padding: const EdgeInsets.only(top: 52.0),
            child: Center(
              child: GestureDetector(
                // Ignore taps to not go back here:
                onTap: () {},
                child: EventVideoPlayer(
                  event,
                  heroTag: controller.heroTagFor(event),
                  sourceRadius: controller.widget.sourceRadius,
                  currentPage: controller.currentPage,
                  playPauseRequests: controller.playPauseRequests,
                ),
              ),
            ),
          ),
        );
      case MessageTypes.Image:
      case MessageTypes.Sticker:
      default:
        // The final rectangle is known before the full image loads, so the
        // hero lands where the photo will be.
        Widget zoomable(Widget image) => InteractiveViewer(
          minScale: 1.0,
          maxScale: 10.0,
          transformationController: controller.transformFor(event),
          onInteractionStart: controller.onInteractionStart,
          onInteractionUpdate: controller.onInteractionUpdate,
          onInteractionEnd: controller.onInteractionEnds,
          child: GestureDetector(
            // A tap on the photo toggles the chrome (a tap beside it closes
            // the viewer); a double tap zooms into that point.
            onTap: controller.toggleChrome,
            onDoubleTapDown: controller.onDoubleTapDown,
            onDoubleTap: () => controller.onDoubleTap(event),
            child: Center(
              child: NotionMediaHero(
                tag: controller.heroTagFor(event),
                sourceRadius: controller.widget.sourceRadius,
                child: image,
              ),
            ),
          ),
        );
        return LayoutBuilder(
          builder: (context, constraints) {
            final info = event.infoMap;
            final size = event.messageType == MessageTypes.Sticker
                ? null
                : notionFitMedia(
                    info['w'] is num ? info['w'] as num : null,
                    info['h'] is num ? info['h'] as num : null,
                    constraints.biggest,
                  );
            if (size != null) {
              // Opens on the thumbnail the user tapped, sharpens in place.
              return ProgressivePhoto(
                key: ValueKey(event.eventId),
                event: event,
                size: size,
                zoom: controller.transformFor(event),
                frame: (context, photo) => zoomable(photo),
              );
            }
            // Stickers and photos without dimensions: the layers could not
            // share one box, so the image shows when it is ready.
            return zoomable(
              MxcImage(
                key: ValueKey(event.eventId),
                event: event,
                fit: BoxFit.contain,
                isThumbnail: false,
                animated: true,
                maxDecodeSide: ProgressivePhoto.maxDecodeSide,
              ),
            );
          },
        );
    }
  }
}

/// Swipe-to-dismiss for pages without a zoomable image (videos, rounds).
class _VerticalDismiss extends StatelessWidget {
  const _VerticalDismiss({required this.controller, required this.child});

  final ImageViewerController controller;
  final Widget child;

  @override
  Widget build(BuildContext context) => GestureDetector(
    behavior: HitTestBehavior.opaque,
    onVerticalDragStart: controller.onVerticalDragStart,
    onVerticalDragUpdate: controller.onVerticalDragUpdate,
    onVerticalDragEnd: controller.onVerticalDragEnd,
    onVerticalDragCancel: () =>
        controller.dismiss.springBack(reduced: NotionMotion.reduced(context)),
    child: child,
  );
}
