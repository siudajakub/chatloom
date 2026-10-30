// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/pages/chat/conversation_bubble.dart';
import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/events/outgoing_upload_progress.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

/// Scrim behind text and glyphs drawn over video frames. Video content is
/// arbitrary, so this stays black/white in both themes.
const roundVideoScrim = NotionMediaColors.scrim;
const roundVideoOnScrim = NotionMediaColors.onScrim;

/// Presentation only, so the actual controls can be tested without codecs,
/// Matrix credentials, media downloads or a native plugin build hook.
///
/// The widget is a fixed-size circle (plus the side action column and the
/// optional [below] slot), so the timeline row height never depends on the
/// pending/ready media state.
class RoundVideoView extends StatelessWidget {
  /// Live video surface (already fitted to cover a square).
  final Widget? video;

  /// Encoded thumbnail; decoded at the rendered diameter.
  final Uint8List? thumbnail;
  final bool playing, loading, mediaUnread, pending, muted, outgoing;
  final String? blockedReason, error;
  final Duration position, duration;
  final double? downloadProgress;
  final double speed;
  final Color? textColor;
  final VoidCallback? onToggle, onCancel;

  /// Shown as a side action after local playback in incognito mode.
  final VoidCallback? onReportPlayed;
  final List<Widget> actions;

  /// Time/edited/sending state, drawn as a pill on the bottom-end corner.
  final Widget? statusOverlay;

  /// Content under the circle (transcript), constrained to circle + actions.
  final Widget? below;

  /// Overrides [inlineDiameter]; still bounded by the incoming constraints.
  final double? diameter;

  /// Attached to the circle so a stage can measure where it flies from.
  final Key? circleKey;

  /// Set while an own round uploads (the server does not have it yet): the
  /// circle shows the first frame, a ring that fills with the upload and
  /// no play button (Telegram).
  final ValueListenable<double?>? upload;

  const RoundVideoView({
    super.key,
    this.video,
    this.thumbnail,
    this.playing = false,
    this.loading = false,
    this.mediaUnread = false,
    this.pending = false,
    this.muted = false,
    this.outgoing = false,
    this.blockedReason,
    this.error,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.downloadProgress,
    this.speed = 1,
    this.textColor,
    this.onToggle,
    this.onCancel,
    this.onReportPlayed,
    this.actions = const [],
    this.statusOverlay,
    this.below,
    this.diameter,
    this.circleKey,
    this.upload,
  });

  static const double minDiameter = 96;
  static const double _actionSize = 36;
  static const double _glyphSize = 40;

  /// Indeterminate download ring drawn around the cancel glyph.
  static const double _spinnerSize = 44;

  /// Pills over the frame stay inside the circle at large text sizes.
  static const double _pillMaxTextScale = 1.3;

  /// Tap cycle shared with voice messages.
  static const List<double> speedCycle = [1.0, 1.25, 1.5, 2.0, 0.5];

  /// Next [speedCycle] step; an off-cycle speed (from the slider) restarts it.
  static double nextSpeed(double speed) {
    final index = speedCycle.indexWhere(
      (value) => (value - speed).abs() < .001,
    );
    return speedCycle[(index + 1) % speedCycle.length];
  }

  static String formatTime(Duration duration) =>
      '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

  /// Telegram-like resting size: 60 % of the screen width within 160–240.
  static double inlineDiameter(BuildContext context) {
    final width = MediaQuery.sizeOf(context).width;
    return math.min(width * .6, 240.0).clamp(160.0, 240.0);
  }

  /// `1×`, `1.25×`, `1.5×`: no trailing zeros, at most two decimals.
  static String speedLabel(double speed) {
    var text = speed.toStringAsFixed(2);
    text = text.replaceFirst(RegExp(r'0+$'), '');
    text = text.replaceFirst(RegExp(r'\.$'), '');
    return '$text×';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final notion = context.notion.colors;
    final bubble = ConversationBubbleColors.of(context);
    final color = textColor ?? theme.colorScheme.onSurface;
    final blocked = blockedReason != null;
    final sideActions = blocked
        ? const <Widget>[]
        : [
            ...actions,
            if (onReportPlayed != null)
              RoundSideAction(
                icon: Icons.mark_chat_read_outlined,
                tooltip: 'Send playback receipt',
                onPressed: onReportPlayed,
              ),
          ];
    final totalMs = math.max(1, duration.inMilliseconds).toDouble();
    final currentMs = position.inMilliseconds.toDouble().clamp(0.0, totalMs);
    final active = !blocked && (playing || position > Duration.zero);
    final progress = duration > Duration.zero ? currentMs / totalMs : 0.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final reserve = sideActions.isEmpty
            ? 0.0
            : NotionSize.touchTarget + NotionSpace.xxs;
        var size = diameter ?? inlineDiameter(context);
        if (constraints.hasBoundedWidth) {
          size = math.min(
            size,
            math.max(minDiameter, constraints.maxWidth - reserve),
          );
        }
        final pixels = (size * MediaQuery.devicePixelRatioOf(context)).round();
        final placeholderColor = outgoing ? bubble.outgoing : bubble.incoming;
        final Widget content;
        if (blocked) {
          content = Center(
            child: Icon(
              Icons.lock_outline,
              size: NotionSize.iconLg,
              color: notion.textSecondary,
            ),
          );
        } else if (video != null) {
          content = video!;
        } else if (thumbnail != null) {
          content = Image(
            image: ResizeImage(MemoryImage(thumbnail!), width: pixels),
            fit: BoxFit.cover,
            gaplessPlayback: true,
            excludeFromSemantics: true,
            errorBuilder: (_, _, _) => const SizedBox.expand(),
          );
        } else {
          // The play/cancel glyph is the only mark on an empty circle.
          content = const SizedBox.expand();
        }
        final glyphStyle = IconButton.styleFrom(
          backgroundColor: roundVideoScrim,
          foregroundColor: roundVideoOnScrim,
          disabledBackgroundColor: roundVideoScrim,
          disabledForegroundColor: roundVideoOnScrim.withAlpha(140),
          shape: const CircleBorder(),
          padding: EdgeInsets.zero,
          iconSize: NotionSize.iconLg,
          fixedSize: const Size.square(_glyphSize),
          minimumSize: const Size.square(_glyphSize),
          tapTargetSize: MaterialTapTargetSize.padded,
        );
        final upload = blocked ? null : this.upload;
        final tapEnabled = !blocked && !pending && !loading && upload == null;
        final indeterminate = loading && downloadProgress == null;
        final circle = SizedBox.square(
          key: circleKey,
          dimension: size,
          child: ConversationSelectionRing(
            child: Stack(
              clipBehavior: Clip.none,
              alignment: Alignment.center,
              children: [
                // A double tap on the circle (or its play button) reacts;
                // a single tap plays or pauses.
                Positioned.fill(
                  child: ConversationMessageChromeTap(
                    child: ClipOval(
                      child: ColoredBox(
                        color: placeholderColor,
                        child: NotionTapTarget(
                          behavior: HitTestBehavior.opaque,
                          excludeFromSemantics: true,
                          onTap: tapEnabled ? onToggle : null,
                          child: SizedBox.expand(child: content),
                        ),
                      ),
                    ),
                  ),
                ),
                if (loading && downloadProgress != null || active && !loading)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: RepaintBoundary(
                        child: CustomPaint(
                          painter: RoundProgressPainter(
                            progress: loading ? downloadProgress! : progress,
                            color: loading
                                ? theme.colorScheme.primary
                                : notion.text,
                            track: roundVideoScrim,
                          ),
                        ),
                      ),
                    ),
                  ),
                if (upload != null)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: RepaintBoundary(
                        child: ValueListenableBuilder<double?>(
                          valueListenable: upload,
                          builder: (context, value, _) =>
                              value == null || value >= 1
                              ? const SizedBox.shrink()
                              : CustomPaint(
                                  key: const ValueKey('round-upload-ring'),
                                  painter: RoundProgressPainter(
                                    progress: value,
                                    color: theme.colorScheme.primary,
                                    track: roundVideoScrim,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                // One scrim disc carries both the × and the spinner, so the
                // ring reads on light placeholders and bright frames.
                if (indeterminate)
                  const IgnorePointer(
                    child: SizedBox.square(
                      dimension: NotionSize.touchTarget,
                      child: DecoratedBox(
                        decoration: ShapeDecoration(
                          shape: CircleBorder(),
                          color: roundVideoScrim,
                        ),
                      ),
                    ),
                  ),
                if (loading)
                  IconButton(
                    tooltip: 'Cancel download',
                    onPressed: onCancel,
                    style: indeterminate
                        ? glyphStyle.copyWith(
                            backgroundColor: const WidgetStatePropertyAll(
                              Colors.transparent,
                            ),
                          )
                        : glyphStyle,
                    icon: const Icon(Icons.close),
                  ),
                // Painted after the × so the ring stays visible around it.
                if (indeterminate)
                  // Shown with the × at once; rests after the loop cap.
                  const IgnorePointer(
                    child: NotionDelayedSpinner(
                      key: ValueKey('round-download-spinner'),
                      size: _spinnerSize,
                      delay: Duration.zero,
                      color: roundVideoOnScrim,
                    ),
                  ),
                if (upload != null)
                  OutgoingUploadOverlay(progress: upload)
                else if (!loading && playing && !blocked)
                  Semantics(
                    button: true,
                    label: 'Pause round video',
                    onTap: onToggle,
                    child: const SizedBox.square(
                      dimension: NotionSize.touchTarget,
                    ),
                  )
                else if (!loading && !blocked)
                  ConversationMessageChromeTap(
                    child: IconButton(
                      tooltip: error != null
                          ? 'Retry playback'
                          : 'Play round video',
                      onPressed: pending ? null : onToggle,
                      style: glyphStyle,
                      icon: Icon(
                        error != null ? Icons.refresh : Icons.play_arrow,
                      ),
                    ),
                  ),
                if (!blocked)
                  PositionedDirectional(
                    start: 0,
                    bottom: NotionSpace.xxs,
                    // Spoken through the circle's semantics value instead.
                    child: ExcludeSemantics(
                      child: _Pill(
                        children: [
                          if (mediaUnread)
                            Container(
                              key: const ValueKey('round-unread-dot'),
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: notion.info,
                              ),
                            ),
                          if (muted)
                            const Icon(Icons.volume_off_outlined, size: 12),
                          Text(formatTime(active ? position : duration)),
                          if (speed != 1) Text(speedLabel(speed)),
                        ],
                      ),
                    ),
                  ),
                if (statusOverlay != null)
                  PositionedDirectional(
                    end: 0,
                    bottom: NotionSpace.xxs,
                    child: _Pill(children: [statusOverlay!]),
                  ),
              ],
            ),
          ),
        );
        final availability = upload != null
            ? ', sending'
            : pending
            ? ', checking availability'
            : '';
        final semanticCircle = Semantics(
          container: true,
          label: blocked ? 'Round video unavailable' : 'Round video',
          value:
              '${formatTime(position)} of ${formatTime(duration)}'
              '${mediaUnread ? ', not played yet' : ''}'
              '${muted ? ', muted' : ''}'
              '$availability',
          child: circle,
        );
        final column = Column(
          mainAxisSize: MainAxisSize.min,
          children: sideActions,
        );
        // Actions face the screen centre: after an incoming circle, before an
        // outgoing one (Row order follows the text direction).
        final row = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (outgoing && sideActions.isNotEmpty) ...[
              column,
              const SizedBox(width: NotionSpace.xxs),
            ],
            semanticCircle,
            if (!outgoing && sideActions.isNotEmpty) ...[
              const SizedBox(width: NotionSpace.xxs),
              column,
            ],
          ],
        );
        final width = size + reserve;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: outgoing
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            row,
            if (blocked)
              Padding(
                padding: const EdgeInsets.only(top: NotionSpace.xs),
                child: SizedBox(
                  width: size,
                  child: Text(
                    blockedReason!,
                    textAlign: TextAlign.center,
                    style: NotionType.caption.copyWith(color: color),
                  ),
                ),
              ),
            if (!blocked && error != null)
              Padding(
                padding: const EdgeInsets.only(top: NotionSpace.xs),
                child: SizedBox(
                  width: size,
                  child: Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: NotionType.caption.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              ),
            if (below != null)
              Padding(
                padding: const EdgeInsets.only(top: NotionSpace.xxs),
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: width),
                  child: below,
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 36 dp circular action beside a round video (48 dp hit area).
class RoundSideAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;
  const RoundSideAction({
    super.key,
    required this.icon,
    required this.tooltip,
    this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      style: IconButton.styleFrom(
        backgroundColor: colors.surface,
        foregroundColor: colors.textSecondary,
        side: BorderSide(color: colors.border, width: NotionSize.border),
        shape: const CircleBorder(),
        fixedSize: const Size.square(RoundVideoView._actionSize),
        minimumSize: const Size.square(RoundVideoView._actionSize),
        padding: EdgeInsets.zero,
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final List<Widget> children;
  const _Pill({required this.children});

  @override
  Widget build(BuildContext context) => MediaQuery.withClampedTextScaling(
    maxScaleFactor: RoundVideoView._pillMaxTextScale,
    child: _decorated(),
  );

  Widget _decorated() => DecoratedBox(
    decoration: const ShapeDecoration(
      shape: StadiumBorder(),
      color: roundVideoScrim,
    ),
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: NotionSpace.xs,
        vertical: 2,
      ), // design-lint: allow badge
      child: IconTheme.merge(
        data: const IconThemeData(color: roundVideoOnScrim, size: 12),
        child: DefaultTextStyle.merge(
          style: NotionType.micro.copyWith(color: roundVideoOnScrim),
          maxLines: 1,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            spacing: NotionSpace.xxs,
            children: children,
          ),
        ),
      ),
    ),
  );
}

/// Determinate ring drawn 3 px inside the circle edge.
class RoundProgressPainter extends CustomPainter {
  final double progress;
  final Color color;
  final Color? track;
  final double strokeWidth;
  const RoundProgressPainter({
    required this.progress,
    required this.color,
    this.track,
    this.strokeWidth = 3,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final inset = strokeWidth / 2 + 3;
    final rect = (Offset.zero & size).deflate(inset);
    if (rect.isEmpty) return;
    if (track != null) {
      canvas.drawOval(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth
          ..color = track!,
      );
    }
    final sweep = 2 * math.pi * progress.clamp(0.0, 1.0);
    if (sweep <= 0) return;
    canvas.drawArc(
      rect,
      -math.pi / 2,
      sweep,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..strokeCap = StrokeCap.round
        ..color = color,
    );
  }

  @override
  bool shouldRepaint(RoundProgressPainter oldDelegate) =>
      oldDelegate.progress != progress ||
      oldDelegate.color != color ||
      oldDelegate.track != track ||
      oldDelegate.strokeWidth != strokeWidth;
}

/// Fine speed sheet (.2–3.0×) behind a long press on the stage speed pill;
/// a plain tap cycles [RoundVideoView.speedCycle] like voice messages.
Future<void> showRoundSpeedPicker(
  BuildContext context, {
  required double speed,
  required ValueChanged<double> onChanged,
}) => showNotionSheet<void>(
  context: context,
  title: 'Playback speed',
  builder: (context) {
    var selected = speed.clamp(.2, 3.0);
    return StatefulBuilder(
      builder: (context, setState) {
        void choose(double value) {
          setState(() => selected = value);
          onChanged(value);
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              RoundVideoView.speedLabel(selected),
              textAlign: TextAlign.center,
              style: context.notion.typography.bodyStrong,
            ),
            Slider(
              semanticFormatterCallback: (value) =>
                  '${value.toStringAsFixed(1)} times',
              min: .2,
              max: 3,
              divisions: 28,
              value: selected,
              onChanged: (value) =>
                  choose(double.parse(value.toStringAsFixed(1))),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: NotionSpace.xs,
              runSpacing: NotionSpace.xs,
              children: [
                for (final value in const [.5, 1.0, 1.2, 1.5, 1.7, 2.0])
                  NotionButton(
                    label: RoundVideoView.speedLabel(value),
                    variant: (value - selected).abs() < .001
                        ? NotionButtonVariant.primary
                        : NotionButtonVariant.secondary,
                    onPressed: () => choose(value),
                  ),
              ],
            ),
            const SizedBox(height: NotionSpace.sm),
            NotionButton.ghost(
              label: 'Done',
              onPressed: () => Navigator.pop(context),
            ),
          ],
        );
      },
    );
  },
);
