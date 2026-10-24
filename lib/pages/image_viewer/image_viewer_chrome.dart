// SPDX-License-Identifier: AGPL-3.0-or-later
//
// Context of the media on screen (Telegram, WhatsApp, Messenger): who sent
// it and when, "3 of 12", and its caption. Part of the viewer chrome: it
// fades with the route, a dismiss swipe and a tap on the media
// (NotionMediaChrome). Scrim gradients, not glass: the chrome fades with an
// opacity, and glass must never sit inside an animating opacity (DESIGN.md).
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/date_time_extension.dart';
import 'package:chatloom/utils/file_description.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// "3 of 12" for page [index] (0-based) of [count]; null for one item.
String? imageViewerPosition(int index, int count) =>
    count > 1 ? '${index + 1} of $count' : null;

/// Sender display name, then date and time · position, on the top scrim.
class ImageViewerTitle extends StatelessWidget {
  const ImageViewerTitle({
    super.key,
    required this.event,
    required this.index,
    required this.count,
  });

  final Event event;
  final int index;
  final int count;

  @override
  Widget build(BuildContext context) {
    final local = event.content['chatloom.local_media'] == true;
    final sender = local
        ? null
        : event.senderFromMemoryOrFallback.calcDisplayname();
    final time = event.originServerTs;
    final when = L10n.of(context).dateAndTimeOfDay(
      time.localizedDate(context),
      time.localizedTimeOfDay(context),
    );
    final position = imageViewerPosition(index, count);
    final subtitle = [if (!local) when, ?position].join(' · ');
    const onScrim = NotionMediaColors.onScrim;
    return Semantics(
      container: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (sender != null && sender.isNotEmpty)
            Text(
              sender,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NotionType.callout.copyWith(
                color: onScrim,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (subtitle.isNotEmpty)
            Text(
              subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: NotionType.caption.copyWith(
                color: onScrim.withValues(alpha: .72),
              ),
            ),
        ],
      ),
    );
  }
}

/// Top scrim behind the close button and title: a gradient from
/// [NotionMediaColors.stageScrim] keeps white text readable over any photo.
class ImageViewerTopScrim extends StatelessWidget {
  const ImageViewerTopScrim({super.key});

  @override
  Widget build(BuildContext context) => const IgnorePointer(
    child: DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [NotionMediaColors.stageScrim, Colors.transparent],
        ),
      ),
      child: SizedBox.expand(),
    ),
  );
}

/// The caption of the media on screen over a bottom scrim: three lines,
/// a tap shows all of it (scrolls past 40 % of the screen) and folds it
/// again. Reports its height (without the safe area) to [onHeight] so the
/// pages keep their status pills and video transport above it.
class ImageViewerCaption extends StatefulWidget {
  const ImageViewerCaption({
    super.key,
    required this.event,
    required this.onHeight,
  });

  final Event event;
  final ValueChanged<double> onHeight;

  /// Caption of [event] (a media body that is not just the file name).
  static String? textOf(Event event) {
    if (event.redacted) return null;
    final text = event.fileDescription?.trim();
    return text == null || text.isEmpty ? null : text;
  }

  @override
  State<ImageViewerCaption> createState() => _ImageViewerCaptionState();
}

class _ImageViewerCaptionState extends State<ImageViewerCaption> {
  bool _expanded = false;

  @override
  void didUpdateWidget(ImageViewerCaption oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.eventId != widget.event.eventId) _expanded = false;
  }

  @override
  Widget build(BuildContext context) {
    final text = ImageViewerCaption.textOf(widget.event);
    if (text == null) {
      return _ReportHeight(
        onHeight: widget.onHeight,
        child: const SizedBox(width: double.infinity),
      );
    }
    final bottom = MediaQuery.paddingOf(context).bottom;
    final maxHeight = MediaQuery.sizeOf(context).height * .4;
    final style = NotionType.callout.copyWith(color: NotionMediaColors.onScrim);
    return DecoratedBox(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [NotionMediaColors.stageScrim, Colors.transparent],
        ),
      ),
      child: Padding(
        padding: EdgeInsets.only(bottom: bottom),
        child: _ReportHeight(
          onHeight: widget.onHeight,
          child: Semantics(
            button: true,
            label: _expanded ? 'Show less' : 'Show the whole caption',
            child: GestureDetector(
              key: const ValueKey('viewer-caption'),
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _expanded = !_expanded),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(
                  NotionSpace.inset,
                  NotionSpace.xl,
                  NotionSpace.inset,
                  NotionSpace.md,
                ),
                child: Center(
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: NotionSize.contentMaxWidth,
                      maxHeight: maxHeight,
                    ),
                    child: _expanded
                        ? SingleChildScrollView(child: Text(text, style: style))
                        : Text(
                            text,
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                            style: style,
                          ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Calls [onHeight] after a layout that changed the child's height (once per
/// change, after the frame; never during build).
class _ReportHeight extends SingleChildRenderObjectWidget {
  const _ReportHeight({required this.onHeight, super.child});

  final ValueChanged<double> onHeight;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderReportHeight(onHeight);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderReportHeight renderObject,
  ) => renderObject.onHeight = onHeight;
}

class _RenderReportHeight extends RenderProxyBox {
  _RenderReportHeight(this.onHeight);

  ValueChanged<double> onHeight;
  double? _reported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _reported) return;
    _reported = height;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (attached) onHeight(height);
    });
  }
}
