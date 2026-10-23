// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/pages/image_viewer/image_viewer_view.dart';
import 'package:chatloom/personal/round_video/round_playback_coordinator.dart';
import 'package:chatloom/personal/round_video/telegram_round_service.dart';
import 'package:chatloom/personal/ui/forward_sheet.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/platform_infos.dart';
import 'package:chatloom/widgets/share_scaffold_dialog.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import '../../utils/matrix_sdk_extensions/event_extension.dart';

/// Opens [event] full screen, Telegram style: the photo flies out of its
/// thumbnail (a hero with [heroTag], by default the event id that timeline
/// bubbles use) while the backdrop fades in, and flies back on close or
/// after a downward swipe (see [ImageViewerController]). [sourceRadius] is
/// the corner radius of that thumbnail.
Future<void> showImageViewer(
  BuildContext context,
  Event event, {
  Timeline? timeline,
  List<Event>? mediaEvents,
  Object? heroTag,
  BorderRadius sourceRadius = NotionRadius.mdAll,
}) {
  final navigator = Navigator.of(context, rootNavigator: true);
  return navigator.push<void>(
    NotionMediaRoute<void>(
      themes: InheritedTheme.capture(from: context, to: navigator.context),
      builder: (_) => ImageViewer(
        event,
        timeline: timeline,
        mediaEvents: mediaEvents,
        outerContext: context,
        heroTag: heroTag,
        sourceRadius: sourceRadius,
      ),
    ),
  );
}

class ImageViewer extends StatefulWidget {
  final Event event;
  final Timeline? timeline;

  /// Explicit local album, preserving source order without synthetic timeline events.
  final List<Event>? mediaEvents;
  final BuildContext outerContext;

  /// Hero tag of the thumbnail [event] was opened from (other pages use
  /// their event id).
  final Object? heroTag;
  final BorderRadius sourceRadius;

  const ImageViewer(
    this.event, {
    required this.outerContext,
    this.timeline,
    this.mediaEvents,
    this.heroTag,
    this.sourceRadius = NotionRadius.mdAll,
    super.key,
  });

  @override
  ImageViewerController createState() => ImageViewerController();
}

class ImageViewerController extends State<ImageViewer>
    with TickerProviderStateMixin {
  final FocusNode focusNode = FocusNode();

  /// The media follows a vertical swipe and closes past a threshold, or
  /// springs back; backdrop and chrome fade with it.
  late final NotionDismissDrag dismiss = NotionDismissDrag(vsync: this);

  /// Double tap zooms into the tapped point and back.
  late final NotionDoubleTapZoom zoom = NotionDoubleTapZoom(vsync: this);

  final Map<String, TransformationController> _transforms = {};
  Offset _doubleTapAt = Offset.zero;

  /// Top bar and arrows; a tap on the media toggles them.
  final ValueNotifier<bool> chromeVisible = ValueNotifier(true);

  /// Swipe distance (logical px) or speed (px/s) that closes the viewer.
  static const double dismissDistance = NotionDismissDrag.defaultDistance;
  static const double dismissVelocity = NotionDismissDrag.defaultVelocity;

  /// Vertical offset of the media while it is swiped away.
  ValueNotifier<double> get dismissOffset => dismiss.offset;

  /// Hero tag of [event]'s media.
  Object heroTagFor(Event event) =>
      event.eventId == widget.event.eventId && widget.heroTag != null
      ? widget.heroTag!
      : event.eventId;

  /// Zoom state of one page; a zoomed image pans instead of dismissing.
  TransformationController transformFor(Event event) =>
      _transforms.putIfAbsent(event.eventId, TransformationController.new);

  void toggleChrome() => chromeVisible.value = !chromeVisible.value;

  void onDoubleTapDown(TapDownDetails details) =>
      _doubleTapAt = details.localPosition;

  void onDoubleTap(Event event) => zoom.toggle(
    transformFor(event),
    _doubleTapAt,
    reduced: NotionMotion.reduced(context),
  );

  void onInteractionStart(ScaleStartDetails details) {
    zoom.stop();
    final zoomed = NotionDoubleTapZoom.isZoomed(
      transformFor(currentEventOrInitial),
    );
    if (details.pointerCount == 1 && !zoomed) dismiss.start();
  }

  void onInteractionUpdate(ScaleUpdateDetails details) {
    if (!dismiss.dragging) return;
    if (details.pointerCount > 1) {
      // A pinch takes over: put the media back.
      dismiss.springBack(reduced: NotionMotion.reduced(context));
      return;
    }
    dismiss.update(details.focalPointDelta.dy);
  }

  /// Vertical swipes on pages without a zoomable image (videos, rounds).
  void onVerticalDragStart(DragStartDetails _) => dismiss.start();

  void onVerticalDragUpdate(DragUpdateDetails details) =>
      dismiss.update(details.delta.dy);

  void onVerticalDragEnd(DragEndDetails details) =>
      _endDismiss(details.velocity.pixelsPerSecond.dy);

  void _endDismiss(double velocity) {
    if (dismiss.end(velocity, reduced: NotionMotion.reduced(context))) {
      Navigator.of(context, rootNavigator: false).pop();
    }
  }

  /// Event id of the page on screen; a video plays only on its own page.
  late final ValueNotifier<String?> currentPage = ValueNotifier(
    widget.event.eventId,
  );

  /// A page swiped away forgets its zoom, like Telegram. Players of other
  /// pages stop first; the new page's video then starts on its own (it
  /// waited for [currentPage]), so the stop never catches it.
  void onPageChanged(int index) {
    final current = allEvents[index].eventId;
    zoom.stop();
    for (final entry in _transforms.entries) {
      if (entry.key != current) entry.value.value = Matrix4.identity();
    }
    currentPage.value = null;
    RoundPlaybackCoordinator.shared
        .stopAll(suspend: false)
        .catchError((Object _) {});
    currentPage.value = current;
  }

  Event get currentEventOrInitial =>
      pageController.hasClients ? currentEvent : widget.event;

  @override
  void initState() {
    super.initState();
    allEvents =
        widget.mediaEvents ??
        widget.timeline?.events
            .where(
              (event) => {
                MessageTypes.Image,
                MessageTypes.Sticker,
                if (PlatformInfos.supportsVideoPlayer) MessageTypes.Video,
              }.contains(event.messageType),
            )
            .toList()
            .reversed
            .toList() ??
        [widget.event];
    var index = allEvents.indexWhere(
      (event) => event.eventId == widget.event.eventId,
    );
    if (index < 0) index = 0;
    pageController = PageController(initialPage: index);
  }

  late final PageController pageController;

  late final List<Event> allEvents;

  void onKeyEvent(KeyEvent event) {
    switch (event.logicalKey) {
      case LogicalKeyboardKey.arrowLeft:
        if (canGoBack) prevImage();
        break;
      case LogicalKeyboardKey.arrowRight:
        if (canGoNext) nextImage();
        break;
    }
  }

  Future<void> prevImage() async {
    await pageController.previousPage(
      duration: NotionMotion.long,
      curve: NotionMotion.emphasized,
    );
    if (!mounted) return;
    setState(() {});
  }

  Future<void> nextImage() async {
    await pageController.nextPage(
      duration: NotionMotion.long,
      curve: NotionMotion.emphasized,
    );
    if (!mounted) return;
    setState(() {});
  }

  int get _index => pageController.page?.toInt() ?? 0;

  Event get currentEvent => allEvents[_index];

  bool get canGoNext => _index < allEvents.length - 1;

  bool get canGoBack => _index > 0;

  /// Forward this image to another room.
  void forwardAction() {
    final event = currentEvent;
    final policy = RoundMediaPolicy.fromContent(event.content);
    if (event.redacted || !policy.canForward) return;
    if (RoundVideoDescriptor.fromContent(event.content) != null) {
      TelegramRoundService.of(
        event.room.client,
      ).showForwardPicker(context, event);
      return;
    }
    showForwardSheet(context, items: [ContentShareItem(event.content.copy())]);
  }

  /// Save this file with a system call.
  void saveFileAction(BuildContext context) => currentEvent.saveFile(context);

  /// Save this file with a system call.
  void shareFileAction(BuildContext context) => currentEvent.shareFile(context);

  static const maxScaleFactor = 1.5;

  /// Go back if user swiped it away
  void onInteractionEnds(ScaleEndDetails endDetails) {
    final velocity = endDetails.velocity.pixelsPerSecond.dy;
    if (dismiss.dragging) {
      _endDismiss(velocity);
      return;
    }
    if (PlatformInfos.usesTouchscreen == false) {
      if (velocity > MediaQuery.sizeOf(context).height * maxScaleFactor) {
        Navigator.of(context, rootNavigator: false).pop();
      }
    }
  }

  @override
  void dispose() {
    dismiss.dispose();
    zoom.dispose();
    chromeVisible.dispose();
    currentPage.dispose();
    for (final transform in _transforms.values) {
      transform.dispose();
    }
    focusNode.dispose();
    pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ImageViewerView(this);
}
