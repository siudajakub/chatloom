// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/events/round_video_bridge_message.dart';
import 'package:chatloom/pages/chat/events/round_video_message.dart';
import 'package:chatloom/pages/image_viewer/pointers_listener.dart';
import 'package:chatloom/pages/image_viewer/video_player.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
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
      backgroundColor: Colors.black.withAlpha(200),
      foregroundColor: Colors.white,
    );
    final backdrop = Colors.black.withAlpha(128);
    return GestureDetector(
      onTap: () => Navigator.of(context).pop(),
      child: Scaffold(
        backgroundColor: Colors.transparent,
        extendBodyBehindAppBar: true,
        appBar: AppBar(
          elevation: 0,
          leading: IconButton(
            style: iconButtonStyle,
            icon: const Icon(Icons.close),
            onPressed: Navigator.of(context).pop,
            color: Colors.white,
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
                      color: Colors.white,
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
                      color: Colors.white,
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
                            color: Colors.white,
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
        body: HoverBuilder(
          builder: (context, hovered) => Stack(
            children: [
              // The backdrop fades while the media is swiped away.
              Positioned.fill(
                child: ValueListenableBuilder<double>(
                  valueListenable: controller.dismissOffset,
                  child: ColoredBox(color: backdrop),
                  builder: (context, offset, child) => Opacity(
                    opacity: (1 - offset.abs() / 400).clamp(0.0, 1.0),
                    child: child,
                  ),
                ),
              ),
              _DismissTransform(
                offset: controller.dismissOffset,
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
                      onPageChanged: (_) => RoundPlaybackCoordinator.shared
                          .stopAll(suspend: false),
                      itemCount: controller.allEvents.length,
                      itemBuilder: (context, i) {
                        final event = controller.allEvents[i];
                        final policy = RoundMediaPolicy.fromContent(
                          event.content,
                        );
                        final round =
                            RoundVideoDescriptor.fromContent(
                              event.content,
                              redacted: event.redacted,
                            ) !=
                            null;
                        if (!policy.canPlay || round || event.redacted) {
                          return Padding(
                            padding: const EdgeInsets.only(top: 52),
                            child: Center(
                              child: GestureDetector(
                                onTap: () {},
                                child: round
                                    ? RoundVideoBridgeMessage(
                                        event,
                                        key: ValueKey((
                                          event.room.client,
                                          event.room.id,
                                          event.eventId,
                                        )),
                                        textColor: Colors.white,
                                        enlargeOnPlay: false,
                                      )
                                    : RoundVideoMessage(
                                        event,
                                        textColor: Colors.white,
                                        showThumbnail: false,
                                        enlargeOnPlay: false,
                                      ),
                              ),
                            ),
                          );
                        }
                        switch (event.messageType) {
                          case MessageTypes.Video:
                            return Padding(
                              padding: const EdgeInsets.only(top: 52.0),
                              child: Center(
                                child: GestureDetector(
                                  // Ignore taps to not go back here:
                                  onTap: () {},
                                  child: EventVideoPlayer(event),
                                ),
                              ),
                            );
                          case MessageTypes.Image:
                          case MessageTypes.Sticker:
                          default:
                            return InteractiveViewer(
                              minScale: 1.0,
                              maxScale: 10.0,
                              transformationController: controller.transformFor(
                                event,
                              ),
                              onInteractionStart: controller.onInteractionStart,
                              onInteractionUpdate:
                                  controller.onInteractionUpdate,
                              onInteractionEnd: controller.onInteractionEnds,
                              child: Center(
                                child: Hero(
                                  tag: event.eventId,
                                  child: GestureDetector(
                                    // Ignore taps to not go back here:
                                    onTap: () {},
                                    child: MxcImage(
                                      key: ValueKey(event.eventId),
                                      event: event,
                                      fit: BoxFit.contain,
                                      isThumbnail: false,
                                      animated: true,
                                    ),
                                  ),
                                ),
                              ),
                            );
                        }
                      },
                    ),
                  ),
                ),
              ),
              if (hovered) ...[
                if (controller.canGoBack)
                  Align(
                    alignment: .centerLeft,
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: IconButton(
                        style: iconButtonStyle,
                        tooltip: L10n.of(context).previous,
                        icon: const Icon(Icons.keyboard_arrow_left_outlined),
                        onPressed: controller.prevImage,
                      ),
                    ),
                  ),
                if (controller.canGoNext)
                  Align(
                    alignment: .centerRight,
                    child: Padding(
                      padding: const EdgeInsets.all(12.0),
                      child: IconButton(
                        style: iconButtonStyle,
                        tooltip: L10n.of(context).next,
                        icon: const Icon(Icons.keyboard_arrow_right_outlined),
                        onPressed: controller.nextImage,
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
}

/// Moves the pages with a dismiss swipe: down (or up) by the finger, and a
/// little smaller the further they travel.
class _DismissTransform extends AnimatedWidget {
  const _DismissTransform({
    required ValueNotifier<double> offset,
    required this.child,
  }) : super(listenable: offset);

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final offset = (listenable as ValueNotifier<double>).value;
    final height = MediaQuery.sizeOf(context).height;
    final shrink = height <= 0 ? 0.0 : (offset.abs() / height).clamp(0.0, 1.0);
    return Transform.translate(
      offset: Offset(0, offset),
      child: Transform.scale(scale: 1 - .15 * shrink, child: child),
    );
  }
}
