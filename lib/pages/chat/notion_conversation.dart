// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;
import 'dart:ui' show FontFeature;

import 'package:fluffychat/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// The same authored grid is used for incoming and outgoing source events.
/// Sender/media widgets and their state remain owned by the existing client.
class NotionAuthoredMessageRow extends StatelessWidget {
  final Widget avatar;
  final String author;
  final String time;
  final Widget body;
  final Widget? actions;
  final String? source;
  const NotionAuthoredMessageRow({
    super.key,
    required this.avatar,
    required this.author,
    required this.time,
    required this.body,
    this.actions,
    this.source,
  });

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: NotionTokens.inset,
      vertical: 10,
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox.square(dimension: 36, child: avatar),
        const SizedBox(width: 16),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              NotionAuthorHeading(author: author, time: time, actions: actions),
              const SizedBox(height: 4),
              DefaultTextStyle.merge(style: NotionTokens.body, child: body),
              if (source != null)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    source!,
                    style: NotionTokens.caption.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    ),
  );
}

class NotionAuthorHeading extends StatelessWidget {
  final String author;
  final String time;
  final Widget? leading;
  final Widget? actions;
  const NotionAuthorHeading({
    super.key,
    required this.author,
    required this.time,
    this.leading,
    this.actions,
  });
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(
        child: Wrap(
          spacing: 8,
          runSpacing: 2,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            ?leading,
            Text(
              author,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                height: 1.35,
              ),
            ),
            Text(
              time,
              style: NotionTokens.caption.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
      ?actions,
    ],
  );
}

/// Quiet surface only: production callers supply their real editors, source
/// selector, recorder, attachment picker and durable send action.
class NotionComposer extends StatelessWidget {
  final Widget input;
  final List<Widget> actions;
  final Widget source;
  final Widget sendAction;
  const NotionComposer({
    super.key,
    required this.input,
    required this.actions,
    required this.source,
    required this.sendAction,
  });
  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      borderRadius: BorderRadius.circular(NotionTokens.radius),
      border: Border.all(color: Theme.of(context).colorScheme.outlineVariant),
      color: Theme.of(context).colorScheme.surface,
    ),
    padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: input,
        ),
        const SizedBox(height: 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(child: Wrap(spacing: 0, runSpacing: 0, children: actions)),
            const SizedBox(width: 4),
            sendAction,
          ],
        ),
        Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 2), child: source),
      ],
    ),
  );
}

class NotionSendButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final bool busy;
  const NotionSendButton({super.key, this.onPressed, this.busy = false});
  @override
  Widget build(BuildContext context) => IconButton(
    key: const Key('send_button'),
    tooltip: 'Send message',
    onPressed: busy ? null : onPressed,
    style: IconButton.styleFrom(
      minimumSize: const Size.square(48),
      backgroundColor: Theme.of(context).colorScheme.onSurface,
      foregroundColor: Theme.of(context).colorScheme.surface,
      disabledBackgroundColor: Theme.of(
        context,
      ).colorScheme.onSurface.withAlpha(90),
      disabledForegroundColor: Theme.of(context).colorScheme.surface,
      shape: const CircleBorder(),
    ),
    icon: busy
        ? SizedBox.square(
            dimension: 20,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Theme.of(context).colorScheme.surface,
            ),
          )
        : const Icon(Icons.arrow_upward, size: 24),
  );
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
  final VoidCallback? onSeekBack;
  final VoidCallback? onSeekForward;
  final VoidCallback? onDownload;
  final VoidCallback? onSpeed;
  final double speed;
  final Widget? speedAction;
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
    this.onSeekBack,
    this.onSeekForward,
    this.onDownload,
    this.onSpeed,
    this.speed = 1,
    this.speedAction,
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
    final pl = Localizations.localeOf(context).languageCode == 'pl';
    final enabledSeek = !widget.downloading ? widget.onSeek : null;
    final progress = (_preview ?? widget.progress).clamp(0.0, 1.0).toDouble();
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
      minimumSize: const Size.square(48),
      padding: const EdgeInsets.all(12),
    );
    final speedLabel =
        '${widget.speed.toStringAsFixed(2).replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')}×';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              SizedBox.square(
                dimension: 48,
                child: widget.downloading
                    ? Semantics(
                        label: pl ? 'Wczytywanie nagrania' : 'Loading audio',
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: foreground,
                            value: widget.downloadProgress?.clamp(0.0, 1.0),
                          ),
                        ),
                      )
                    : IconButton(
                        tooltip: widget.playing
                            ? (pl ? 'Wstrzymaj nagranie' : 'Pause audio')
                            : (pl ? 'Odtwórz nagranie' : 'Play audio'),
                        style: buttonStyle.copyWith(
                          backgroundColor: WidgetStatePropertyAll(foreground),
                          foregroundColor: WidgetStatePropertyAll(
                            foreground.computeLuminance() > .179
                                ? const Color(0xFF242424)
                                : Colors.white,
                          ),
                          shape: const WidgetStatePropertyAll(CircleBorder()),
                        ),
                        onPressed: widget.onPlay,
                        icon: Icon(
                          widget.playing
                              ? Icons.pause_rounded
                              : Icons.play_arrow_rounded,
                          size: 28,
                        ),
                      ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 36,
                        trackShape: NotionWaveformTrackShape(widget.waveform),
                        activeTrackColor: foreground,
                        inactiveTrackColor: foreground.withValues(alpha: .55),
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
                          color: foreground.computeLuminance() > .179
                              ? const Color(0xFF242424)
                              : Colors.white,
                        ),
                      ),
                      child: MergeSemantics(
                        child: Semantics(
                          label: pl ? 'Pozycja nagrania' : 'Audio position',
                          child: Slider(
                            key: const ValueKey('voice-waveform'),
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            value: progress,
                            label: seekTime(progress),
                            semanticFormatterCallback: seekTime,
                            onChanged: enabledSeek == null
                                ? null
                                : (value) => setState(() => _preview = value),
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
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      child: Text(
                        time,
                        textDirection: TextDirection.ltr,
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.3,
                          color: foreground,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          Wrap(
            spacing: 0,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                tooltip: pl ? 'Cofnij o 10 sekund' : 'Rewind 10 seconds',
                style: buttonStyle,
                onPressed: widget.downloading ? null : widget.onSeekBack,
                icon: const Icon(Icons.replay_10_rounded, size: 22),
              ),
              IconButton(
                tooltip: pl ? 'Przewiń o 10 sekund' : 'Forward 10 seconds',
                style: buttonStyle,
                onPressed: widget.downloading ? null : widget.onSeekForward,
                icon: const Icon(Icons.forward_10_rounded, size: 22),
              ),
              widget.speedAction ??
                  TextButton(
                    onPressed: widget.downloading ? null : widget.onSpeed,
                    style: TextButton.styleFrom(
                      foregroundColor: foreground,
                      disabledForegroundColor: foreground.withValues(
                        alpha: .38,
                      ),
                      minimumSize: const Size(48, 48),
                    ),
                    child: Tooltip(
                      message: pl ? 'Prędkość odtwarzania' : 'Playback speed',
                      child: Text(
                        speedLabel,
                        textDirection: TextDirection.ltr,
                        semanticsLabel:
                            '${pl ? 'Prędkość odtwarzania' : 'Playback speed'} $speedLabel',
                      ),
                    ),
                  ),
              if (widget.onDownload != null)
                IconButton(
                  tooltip: pl ? 'Zapisz nagranie' : 'Download audio',
                  style: buttonStyle,
                  onPressed: widget.onDownload,
                  icon: const Icon(Icons.download_rounded, size: 20),
                ),
            ],
          ),
        ],
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
            const Radius.circular(2),
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
            const Radius.circular(2),
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

/// Manual request affordance. Rendering this action never starts a job.
class NotionTranscribeAction extends StatelessWidget {
  final VoidCallback? onPressed;
  final String label;
  final bool busy;
  const NotionTranscribeAction({
    super.key,
    this.onPressed,
    this.label = 'Transcribe',
    this.busy = false,
  });
  @override
  Widget build(BuildContext context) => TextButton(
    onPressed: onPressed,
    style: TextButton.styleFrom(
      padding: EdgeInsets.zero,
      minimumSize: const Size(48, 44),
      alignment: Alignment.centerLeft,
      foregroundColor: Theme.of(context).colorScheme.onSurfaceVariant,
    ),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (busy) ...[
          const SizedBox.square(
            dimension: 14,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 8),
        ],
        Flexible(
          child: Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ],
    ),
  );
}
