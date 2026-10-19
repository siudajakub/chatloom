// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:fluffychat/pages/image_viewer/image_viewer_view.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/platform_infos.dart';
import 'package:fluffychat/utils/show_scaffold_dialog.dart';
import 'package:fluffychat/widgets/share_scaffold_dialog.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:fluffychat/personal/round_video/telegram_round_service.dart';

import '../../utils/matrix_sdk_extensions/event_extension.dart';

/// Opens [event] full screen: the viewer fades in while it scales up from
/// the dialog start scale, and leaves the same way (or follows a downward
/// swipe, see [ImageViewerController]).
Future<void> showImageViewer(
  BuildContext context,
  Event event, {
  Timeline? timeline,
}) => showNotionCustomDialog<void>(
  context: context,
  builder: (_) => ImageViewer(event, timeline: timeline, outerContext: context),
);

class ImageViewer extends StatefulWidget {
  final Event event;
  final Timeline? timeline;
  final BuildContext outerContext;

  const ImageViewer(
    this.event, {
    required this.outerContext,
    this.timeline,
    super.key,
  });

  @override
  ImageViewerController createState() => ImageViewerController();
}

class ImageViewerController extends State<ImageViewer>
    with SingleTickerProviderStateMixin {
  final FocusNode focusNode = FocusNode();

  /// Vertical offset of the media while it is swiped away (or springs
  /// back). The backdrop fades and the media shrinks with it.
  final ValueNotifier<double> dismissOffset = ValueNotifier(0);
  late final AnimationController _settle = AnimationController.unbounded(
    vsync: this,
  )..addListener(() => dismissOffset.value = _settle.value);
  final Map<String, TransformationController> _transforms = {};
  bool _dismissDrag = false;

  /// Swipe distance (logical px) or speed (px/s) that closes the viewer.
  static const double dismissDistance = 120;
  static const double dismissVelocity = 900;

  /// Zoom state of one page; a zoomed image pans instead of dismissing.
  TransformationController transformFor(Event event) =>
      _transforms.putIfAbsent(event.eventId, TransformationController.new);

  void onInteractionStart(ScaleStartDetails details) {
    final zoomed =
        transformFor(currentEventOrInitial).value.getMaxScaleOnAxis() > 1.01;
    _dismissDrag = details.pointerCount == 1 && !zoomed;
    if (_dismissDrag) _settle.stop();
  }

  void onInteractionUpdate(ScaleUpdateDetails details) {
    if (!_dismissDrag) return;
    if (details.pointerCount > 1) {
      // A pinch takes over: put the media back.
      _dismissDrag = false;
      _springBack(0);
      return;
    }
    dismissOffset.value += details.focalPointDelta.dy;
  }

  void _springBack(double velocity) {
    if (NotionMotion.reduced(context)) {
      _settle.value = 0;
      return;
    }
    _settle
      ..value = dismissOffset.value
      ..animateWith(
        NotionMotion.springTo(
          NotionMotion.snappy,
          dismissOffset.value,
          0,
          velocity: velocity,
        ),
      );
  }

  Event get currentEventOrInitial =>
      pageController.hasClients ? currentEvent : widget.event;

  @override
  void initState() {
    super.initState();
    allEvents =
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
    showScaffoldDialog(
      context: context,
      builder: (context) =>
          ShareScaffoldDialog(items: [ContentShareItem(event.content)]),
    );
  }

  /// Save this file with a system call.
  void saveFileAction(BuildContext context) => currentEvent.saveFile(context);

  /// Save this file with a system call.
  void shareFileAction(BuildContext context) => currentEvent.shareFile(context);

  static const maxScaleFactor = 1.5;

  /// Go back if user swiped it away
  void onInteractionEnds(ScaleEndDetails endDetails) {
    final velocity = endDetails.velocity.pixelsPerSecond.dy;
    if (_dismissDrag) {
      _dismissDrag = false;
      if (dismissOffset.value.abs() > dismissDistance ||
          (velocity.abs() > dismissVelocity &&
              velocity.sign == dismissOffset.value.sign)) {
        Navigator.of(context, rootNavigator: false).pop();
      } else {
        _springBack(velocity);
      }
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
    _settle.dispose();
    dismissOffset.dispose();
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
