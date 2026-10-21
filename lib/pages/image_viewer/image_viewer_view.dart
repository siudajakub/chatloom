// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/events/round_video_bridge_message.dart';
import 'package:chatloom/pages/chat/events/round_video_message.dart';
import 'package:chatloom/pages/image_viewer/pointers_listener.dart';
import 'package:chatloom/pages/image_viewer/video_player.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/ui/notion/notion.dart';
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
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: PreferredSize(
          preferredSize: const Size.fromHeight(kToolbarHeight),
          child: chrome(
            AppBar(
              elevation: 0,
              leading: IconButton(
                style: iconButtonStyle,
                icon: const Icon(Icons.close),
                onPressed: Navigator.of(context).pop,
                color: NotionMediaColors.onScrim,
                tooltip: L10n.of(context).close,
              ),
              backgroundColor: Colors.transparent,
              actions: [
                AnimatedBuilder(
                  animation: controller.pageController,
                  builder: (context, _) {
                    final event = controller.pageController.hasClients
                        ? controller.currentEvent
                        : controller.widget.event;
                    final policy = RoundMediaPolicy.fromContent(event.content);
                    final round =
                        RoundVideoDescriptor.fromContent(
                          event.content,
                          redacted: event.redacted,
                        ) !=
                        null;
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          style: iconButtonStyle,
                          icon: const Icon(Icons.reply_outlined),
                          onPressed:
                              !event.redacted &&
                                  policy.canForward &&
                                  (!round ||
                                      TelegramRoundService.of(
                                        event.room.client,
                                      ).canNativeForward(event))
                              ? controller.forwardAction
                              : null,
                          color: NotionMediaColors.onScrim,
                          tooltip: round
                              ? 'Przekazywanie w Telegramie wymaga wsparcia mostu'
                              : L10n.of(context).share,
                        ),
                        const SizedBox(width: 8),
                        IconButton(
                          style: iconButtonStyle,
                          icon: const Icon(Icons.download_outlined),
                          onPressed: !event.redacted && policy.canExport
                              ? () => controller.saveFileAction(context)
                              : null,
                          color: NotionMediaColors.onScrim,
                          tooltip: L10n.of(context).downloadFile,
                        ),
                        const SizedBox(width: 8),
                        if (PlatformInfos.isMobile)
                          Padding(
                            padding: const EdgeInsets.only(right: 8),
                            child: Builder(
                              builder: (context) => IconButton(
                                style: iconButtonStyle,
                                onPressed: !event.redacted && policy.canExport
                                    ? () => controller.shareFileAction(context)
                                    : null,
                                tooltip: L10n.of(context).share,
                                color: NotionMediaColors.onScrim,
                                icon: Icon(Icons.adaptive.share_outlined),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        body: HoverBuilder(
          builder: (context, hovered) => Stack(
            children: [
              // Fades in with the route and out while the media is swiped
              // away.
              Positioned.fill(child: NotionMediaBackdrop(drag: drag)),
              NotionDismissTransform(
                drag: drag,
                child: KeyboardListener(
                  focusNode: controller.focusNode,
                  onKeyEvent: controller.onKeyEvent,
                  child: PointersListener(
                    builder: (context, moreThanOnePointer) => PageView.builder(
                      physics: !moreThanOnePointer
                          ? BouncingScrollPhysics()
                          : NeverScrollableScrollPhysics(),
                      scrollDirection: Axis.horizontal,
                      controller: controller.pageController,
                      onPageChanged: controller.onPageChanged,
                      itemCount: controller.allEvents.length,
                      itemBuilder: (context, i) =>
                          _page(context, controller.allEvents[i]),
                    ),
                  ),
                ),
              ),
              if (hovered) ...[
                if (controller.canGoBack)
                  Align(
                    alignment: .centerLeft,
                    child: chrome(
                      Padding(
                        padding: const EdgeInsets.all(12.0),
                        child: IconButton(
                          style: iconButtonStyle,
                          tooltip: L10n.of(context).previous,
                          icon: const Icon(Icons.keyboard_arrow_left_outlined),
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
                        padding: const EdgeInsets.all(12.0),
                        child: IconButton(
                          style: iconButtonStyle,
                          tooltip: L10n.of(context).next,
                          icon: const Icon(Icons.keyboard_arrow_right_outlined),
                          onPressed: controller.nextImage,
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _page(BuildContext context, Event event) {
    final policy = RoundMediaPolicy.fromContent(event.content);
    final round =
        RoundVideoDescriptor.fromContent(event.content, redacted: event.redacted) !=
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
                ),
              ),
            ),
          ),
        );
      case MessageTypes.Image:
      case MessageTypes.Sticker:
      default:
        return InteractiveViewer(
          minScale: 1.0,
          maxScale: 10.0,
          transformationController: controller.transformFor(event),
          onInteractionStart: controller.onInteractionStart,
          onInteractionUpdate: controller.onInteractionUpdate,
          onInteractionEnd: controller.onInteractionEnds,
          child: LayoutBuilder(
            builder: (context, constraints) {
              // The final rectangle is known before the full image loads,
              // so the hero lands where the photo will be; the thumbnail
              // shows until the full image fades in over it.
              final info = event.infoMap;
              final size = event.messageType == MessageTypes.Sticker
                  ? null
                  : notionFitMedia(
                      info['w'] is num ? info['w'] as num : null,
                      info['h'] is num ? info['h'] as num : null,
                      constraints.biggest,
                    );
              Widget image = MxcImage(
                key: ValueKey(event.eventId),
                event: event,
                fit: BoxFit.contain,
                isThumbnail: false,
                animated: true,
                width: size?.width,
                height: size?.height,
                placeholder: size == null || !event.hasThumbnail
                    ? null
                    : (_) => MxcImage(
                        event: event,
                        fit: BoxFit.contain,
                        isThumbnail: true,
                        width: size.width,
                        height: size.height,
                      ),
              );
              if (size != null) {
                image = SizedBox.fromSize(size: size, child: image);
              }
              return GestureDetector(
                // A tap on the photo toggles the chrome (a tap beside it
                // closes the viewer); a double tap zooms into that point.
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
              );
            },
          ),
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
