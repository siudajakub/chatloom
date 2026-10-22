// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/pages/chat/conversation_motion.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

class NotionSendButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool busy;
  final String tooltip;

  /// Long press (touch) or secondary click (mouse) on an enabled button,
  /// for example Send later / Remind me (Telegram's `onSendLongClick`).
  /// The tooltip then shows on hover only, so it never covers the menu.
  final VoidCallback? onLongPress;
  const NotionSendButton({
    super.key,
    this.onPressed,
    this.busy = false,
    this.tooltip = 'Send message',
    this.onLongPress,
  });

  /// Presses with a spring (the send button is a reward element), pulses
  /// when it becomes enabled and sends with a light haptic tick. While the
  /// message is being stored (a few milliseconds) it keeps its look and
  /// ignores taps; a spinner appears only if that takes longer than the
  /// loader grace, so a normal send never flashes grey or a spinner.
  @override
  Widget build(BuildContext context) {
    final send = busy ? null : onPressed;
    const arrow = Icon(Icons.arrow_upward, key: ValueKey('send'), size: 24);
    // The accent fill (Messenger's blue send), white arrow.
    final palette = context.notion.palette;
    final fill = palette.accentFill;
    final onFill = palette.onAccentFill;
    // Springs when it turns enabled (first character typed) or back.
    final more = send == null ? null : onLongPress;
    final button = NotionPop(
      playOnMount: false,
      trigger: onPressed != null,
      child: NotionPressable(
        scale: NotionMotion.pressIcon,
        bounce: true,
        enabled: send != null,
        child: IconButton(
          key: const Key('send_button'),
          onPressed: send == null
              ? null
              : () {
                  NotionHaptics.send();
                  send();
                },
          style: IconButton.styleFrom(
            minimumSize: const Size.square(48),
            backgroundColor: fill,
            foregroundColor: onFill,
            // Busy keeps the enabled colour: no grey flash on every send.
            disabledBackgroundColor: busy && onPressed != null
                ? fill
                : fill.withAlpha(90),
            disabledForegroundColor: onFill,
            shape: const CircleBorder(),
          ),
          icon: busy
              ? NotionDelayedReveal(
                  placeholder: arrow,
                  child: SizedBox.square(
                    key: const ValueKey('busy'),
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: onFill,
                    ),
                  ),
                )
              : arrow,
        ),
      ),
    );
    // One stable tree whether or not the long press is offered (busy
    // toggles it on every send), so the pop and press state survive.
    return Tooltip(
      message: tooltip,
      triggerMode: onLongPress == null ? null : TooltipTriggerMode.manual,
      child: GestureDetector(
        onLongPress: more,
        onSecondaryTap: more,
        child: button,
      ),
    );
  }
}

/// Validates bounded Matrix MSC1767 amplitudes, keeping missing data honest.
List<double> notionVoiceWaveform(Object? value) {
  if (value is! List || value.isEmpty || value.length > 1024) return const [];
  if (value.any((v) => v is! num || !v.isFinite || v < 0)) return const [];
  final count = math.min(value.length, 40);
  return List<double>.generate(count, (i) {
    final start = i * value.length ~/ count;
    final end = (i + 1) * value.length ~/ count;
    var peak = 0.0;
    for (var j = start; j < end; j++) {
      peak = math.max(peak, (value[j] as num).toDouble());
    }
    return (peak / 1024).clamp(0.0, 1.0);
  }, growable: false);
}

String notionAudioTime(Duration duration) {
  final seconds = math.max(0, duration.inSeconds);
  return '${seconds ~/ 60}:${(seconds % 60).toString().padLeft(2, '0')}';
}

/// Compact inline transport. Playback, decryption and transcription stay with
/// the production caller. The standard slider retains keyboard and semantics.
class NotionAudioFileBlock extends StatefulWidget {
  final String duration;
  final Duration? seekDuration;
  final List<double> waveform;
  final double progress;
  final bool playing;
  final bool downloading;
  final double? downloadProgress;
  final Color? foregroundColor;
  final VoidCallback? onPlay;
  final ValueChanged<double>? onSeek;
  final VoidCallback? onDownload;
  final VoidCallback? onSpeed;
  final double speed;
  final Widget? speedAction;
  final VoidCallback? onExpand;

  /// Shows speed for the active note; secondary actions remain in a menu.
  final bool controls;
  const NotionAudioFileBlock({
    super.key,
    required this.duration,
    required this.progress,
    this.seekDuration,
    this.waveform = const [],
    this.playing = false,
    this.downloading = false,
    this.downloadProgress,
    this.foregroundColor,
    this.onPlay,
    this.onSeek,
    this.onDownload,
    this.onSpeed,
    this.speed = 1,
    this.speedAction,
    this.onExpand,
    this.controls = true,
  });

  @override
  State<NotionAudioFileBlock> createState() => _NotionAudioFileBlockState();
}

class _NotionAudioFileBlockState extends State<NotionAudioFileBlock> {
  double? _preview;

  @override
  void didUpdateWidget(covariant NotionAudioFileBlock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.onSeek == null || widget.downloading) _preview = null;
  }

  @override
  Widget build(BuildContext context) {
    final foreground =
        widget.foregroundColor ?? Theme.of(context).colorScheme.onSurface;
    final enabledSeek = !widget.downloading ? widget.onSeek : null;
    final progress = (_preview ?? widget.progress).clamp(0.0, 1.0);
    final total = widget.seekDuration;
    String seekTime(double value) => total == null
        ? '${(value * 100).round()}%'
        : notionAudioTime(
            Duration(milliseconds: (total.inMilliseconds * value).round()),
          );
    final time = _preview != null && total != null
        ? '${seekTime(progress)} / ${notionAudioTime(total)}'
        : widget.duration;
    final buttonStyle = IconButton.styleFrom(
      foregroundColor: foreground,
      disabledForegroundColor: foreground.withValues(alpha: .38),
      minimumSize: const Size.square(NotionSize.touchTarget),
      padding: const EdgeInsets.all(NotionSpace.sm),
    );
    final speedLabel =
        '${widget.speed.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')}×';
    // Player labels are message chrome: double tap belongs to reactions.
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: NotionSpace.xxs),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                SizedBox.square(
                  dimension: 48,
                  // Loading ↔ play pops in place (the old state leaves at once).
                  child: ConversationSlotMorph(
                    child: widget.downloading
                        ? Semantics(
                            key: const ValueKey('audio-loading'),
                            label: 'Loading audio',
                            child: Padding(
                              padding: const EdgeInsets.all(NotionSpace.sm),
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: foreground,
                                value: widget.downloadProgress?.clamp(0.0, 1.0),
                              ),
                            ),
                          )
                        : IconButton(
                            key: const ValueKey('audio-play'),
                            tooltip: widget.playing
                                ? 'Pause audio'
                                : 'Play audio',
                            style: buttonStyle.copyWith(
                              backgroundColor: WidgetStatePropertyAll(
                                foreground,
                              ),
                              foregroundColor: WidgetStatePropertyAll(
                                NotionContrast.on(foreground),
                              ),
                              shape: const WidgetStatePropertyAll(
                                CircleBorder(),
                              ),
                            ),
                            onPressed: widget.onPlay,
                            icon: NotionMorphSwitcher(
                              child: Icon(
                                widget.playing
                                    ? Icons.pause_rounded
                                    : Icons.play_arrow_rounded,
                                key: ValueKey(widget.playing),
                                size: 28,
                              ),
                            ),
                          ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RepaintBoundary(
                        child: SliderTheme(
                          data: SliderTheme.of(context).copyWith(
                            trackHeight: 36,
                            trackShape: NotionWaveformTrackShape(
                              widget.waveform,
                            ),
                            activeTrackColor: foreground,
                            inactiveTrackColor: foreground.withValues(
                              alpha: .55,
                            ),
                            disabledActiveTrackColor: foreground,
                            disabledInactiveTrackColor: foreground.withValues(
                              alpha: .55,
                            ),
                            thumbColor: foreground,
                            overlayColor: foreground.withValues(alpha: .12),
                            thumbShape: const RoundSliderThumbShape(
                              enabledThumbRadius: 5,
                              disabledThumbRadius: 0,
                            ),
                            overlayShape: const RoundSliderOverlayShape(
                              overlayRadius: 12,
                            ),
                            showValueIndicator:
                                ShowValueIndicator.onlyForContinuous,
                            valueIndicatorColor: foreground,
                            valueIndicatorTextStyle: TextStyle(
                              color: NotionContrast.on(foreground),
                            ),
                          ),
                          child: MergeSemantics(
                            child: Semantics(
                              label: 'Audio position',
                              child: Slider(
                                key: const ValueKey('voice-waveform'),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: NotionSpace.xs,
                                ),
                                value: progress,
                                label: seekTime(progress),
                                semanticFormatterCallback: seekTime,
                                onChanged: enabledSeek == null
                                    ? null
                                    : (value) =>
                                          setState(() => _preview = value),
                                onChangeEnd: enabledSeek == null
                                    ? null
                                    : (value) {
                                        setState(() => _preview = null);
                                        widget.onSeek?.call(value);
                                      },
                              ),
                            ),
                          ),
                        ),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: ConversationMessageChromeTap(
                              child: Tooltip(
                                message: widget.onExpand == null
                                    ? time
                                    : 'Expand audio player',
                                child: Semantics(
                                  button: widget.onExpand != null,
                                  label: widget.onExpand == null
                                      ? null
                                      : 'Expand audio player',
                                  child: InkWell(
                                    onTap: widget.onExpand,
                                    borderRadius: NotionRadius.smAll,
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: NotionSpace.xs,
                                        vertical: NotionSpace.sm,
                                      ),
                                      child: Text(
                                        time,
                                        textDirection: TextDirection.ltr,
                                        style: NotionType.footnote.copyWith(
                                          color: foreground,
                                          fontFeatures: const [
                                            FontFeature.tabularFigures(),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (widget.controls)
                            widget.speedAction ??
                                TextButton(
                                  onPressed: widget.downloading
                                      ? null
                                      : widget.onSpeed,
                                  style: TextButton.styleFrom(
                                    foregroundColor: foreground,
                                    disabledForegroundColor: foreground
                                        .withValues(alpha: .38),
                                    minimumSize: const Size.square(
                                      NotionSize.touchTarget,
                                    ),
                                  ),
                                  child: Tooltip(
                                    message: 'Playback speed',
                                    child: Text(
                                      speedLabel,
                                      textDirection: TextDirection.ltr,
                                      semanticsLabel:
                                          'Playback speed $speedLabel',
                                    ),
                                  ),
                                ),
                          if (widget.onExpand != null ||
                              widget.onDownload != null)
                            NotionMediaActionsButton(
                              foregroundColor: foreground,
                              actions: [
                                if (widget.onExpand != null)
                                  NotionMediaAction(
                                    label: 'Expand audio player',
                                    icon: Icons.open_in_full_rounded,
                                    onPressed: widget.onExpand,
                                  ),
                                if (widget.onDownload != null)
                                  NotionMediaAction(
                                    label: 'Download audio',
                                    icon: Icons.download_rounded,
                                    onPressed: widget.onDownload,
                                  ),
                              ],
                            ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Real amplitudes where supplied; a flat seek track when they are unavailable.
class NotionWaveformTrackShape extends SliderTrackShape
    with BaseSliderTrackShape {
  final List<double> samples;
  const NotionWaveformTrackShape(this.samples);

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );
    if (rect.width <= 0) return;
    final active = sliderTheme.activeTrackColor!;
    final inactive = sliderTheme.inactiveTrackColor!;
    final canvas = context.canvas;
    void drawTrack(Color color) {
      final paint = Paint()..color = color;
      if (samples.isEmpty) {
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(center: rect.center, width: rect.width, height: 4),
            const Radius.circular(
              2,
            ), // design-lint: allow pill: half the 4 px bar
          ),
          paint,
        );
        return;
      }
      // Interpolate the supplied envelope to a stable visual density.
      const count = 40;
      final step = rect.width / count;
      for (var i = 0; i < count; i++) {
        final samplePosition = i / (count - 1) * (samples.length - 1);
        final low = samplePosition.floor();
        final high = math.min(low + 1, samples.length - 1);
        final value =
            samples[low] +
            (samples[high] - samples[low]) * (samplePosition - low);
        final amplitude = value.isFinite ? value.clamp(0.0, 1.0) : 0.0;
        final x = textDirection == TextDirection.ltr
            ? rect.left + step * (i + .5)
            : rect.right - step * (i + .5);
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromCenter(
              center: Offset(x, rect.center.dy),
              width: math.min(3.0, step * .6),
              height: 4 + amplitude * (rect.height - 4),
            ),
            const Radius.circular(
              2,
            ), // design-lint: allow pill: half the 4 px bar
          ),
          paint,
        );
      }
    }

    drawTrack(inactive);
    canvas.save();
    canvas.clipRect(
      Rect.fromLTRB(
        textDirection == TextDirection.ltr ? rect.left : thumbCenter.dx,
        rect.top,
        textDirection == TextDirection.ltr ? thumbCenter.dx : rect.right,
        rect.bottom,
      ),
    );
    drawTrack(active);
    canvas.restore();
  }
}

/// Offset correction for a rendered event anchor. Reverse timelines increase
/// their screen Y when scroll offset increases.
double notionRestoredScrollOffset(
  double current,
  double beforeY,
  double afterY, {
  required bool reverse,
}) => current + (reverse ? beforeY - afterY : afterY - beforeY);
