// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// Presentation only, so the actual controls can be tested without codecs,
/// Matrix credentials, media downloads or a native plugin build hook.
class RoundVideoView extends StatelessWidget {
  final Widget? video;
  final bool playing, loading, mediaUnread;
  final String? blockedReason, error;
  final Duration position, duration;
  final double? downloadProgress;
  final double speed;
  final Color? textColor;
  final VoidCallback? onToggle, onCancel, onReportPlayed;
  final ValueChanged<Duration>? onSeek;
  final ValueChanged<double>? onSpeedChanged;
  final List<Widget> actions;

  const RoundVideoView({
    super.key,
    this.video,
    this.playing = false,
    this.loading = false,
    this.mediaUnread = false,
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
    this.onSeek,
    this.onSpeedChanged,
    this.actions = const [],
  });

  static String formatTime(Duration duration) =>
      '${duration.inMinutes}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}';

  Future<void> _speedPicker(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (context) {
      var selected = speed.clamp(.2, 3.0);
      return StatefulBuilder(
        builder: (context, setState) => SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Playback speed',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                const SizedBox(height: 8),
                Text('${selected.toStringAsFixed(1)}×'),
                Slider(
                  semanticFormatterCallback: (value) =>
                      '${value.toStringAsFixed(1)} times',
                  min: .2,
                  max: 3,
                  divisions: 28,
                  value: selected,
                  onChanged: (value) {
                    setState(() => selected = value);
                    onSpeedChanged?.call(value);
                  },
                ),
                Wrap(
                  spacing: 4,
                  children: [
                    for (final value in const [.5, 1.0, 1.2, 1.5, 1.7, 2.0])
                      TextButton(
                        onPressed: () {
                          setState(() => selected = value);
                          onSpeedChanged?.call(value);
                        },
                        child: Text('$value×'),
                      ),
                  ],
                ),
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Done'),
                ),
              ],
            ),
          ),
        ),
      );
    },
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final color = textColor ?? theme.colorScheme.onSurface;
    final blocked = blockedReason != null;
    final totalMs = math.max(1, duration.inMilliseconds).toDouble();
    final currentMs = position.inMilliseconds.toDouble().clamp(0.0, totalMs);
    final progress = duration > Duration.zero ? currentMs / totalMs : 0.0;
    return LayoutBuilder(
      builder: (context, constraints) {
        final diameter = math.min(constraints.maxWidth, 224.0);
        return SizedBox(
          width: diameter,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Semantics(
                label: blocked ? 'Round video unavailable' : 'Round video',
                value: '${formatTime(position)} of ${formatTime(duration)}',
                child: SizedBox.square(
                  dimension: diameter,
                  child: Stack(
                    alignment: Alignment.center,
                    children: [
                      Positioned.fill(
                        child: Padding(
                          padding: const EdgeInsets.all(5),
                          child: ClipOval(
                            child: ColoredBox(
                              color: theme.colorScheme.surfaceContainerHighest,
                              child: blocked
                                  ? const Icon(Icons.lock_outline, size: 40)
                                  : video ??
                                        const Icon(
                                          Icons.videocam_outlined,
                                          size: 40,
                                        ),
                            ),
                          ),
                        ),
                      ),
                      Positioned.fill(
                        child: IgnorePointer(
                          child: CircularProgressIndicator(
                            value: loading ? downloadProgress : progress,
                            strokeWidth: 3,
                            color: theme.colorScheme.primary,
                            backgroundColor: theme.colorScheme.outlineVariant,
                          ),
                        ),
                      ),
                      if (!blocked && !loading)
                        IconButton.filled(
                          tooltip: playing
                              ? 'Pause round video'
                              : error != null
                              ? 'Retry playback'
                              : 'Play round video',
                          onPressed: onToggle,
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black87,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(48, 48),
                          ),
                          icon: Icon(playing ? Icons.pause : Icons.play_arrow),
                        ),
                      if (loading)
                        IconButton.filled(
                          tooltip: 'Cancel download',
                          onPressed: onCancel,
                          style: IconButton.styleFrom(
                            backgroundColor: Colors.black87,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(48, 48),
                          ),
                          icon: const Icon(Icons.close),
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 8),
              if (blocked)
                Text(
                  blockedReason!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: color),
                )
              else ...[
                Wrap(
                  alignment: WrapAlignment.center,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 8,
                  children: [
                    if (mediaUnread)
                      Semantics(
                        label: 'Message not played yet',
                        child: Icon(Icons.circle, size: 8, color: color),
                      ),
                    Text(
                      '${formatTime(position)} / ${formatTime(duration)}',
                      style: TextStyle(color: color),
                    ),
                    TextButton(
                      onPressed: onSpeedChanged == null
                          ? null
                          : () => _speedPicker(context),
                      child: Text(
                        '${speed.toStringAsFixed(speed == speed.roundToDouble() ? 0 : 1)}×',
                      ),
                    ),
                  ],
                ),
                if (onSeek != null)
                  Slider(
                    value: currentMs,
                    max: totalMs,
                    semanticFormatterCallback: (value) =>
                        formatTime(Duration(milliseconds: value.round())),
                    onChanged: onSeek == null
                        ? null
                        : (value) =>
                              onSeek!(Duration(milliseconds: value.round())),
                  ),
                if (loading)
                  Text(
                    downloadProgress == null
                        ? 'Downloading round video…'
                        : 'Downloading ${(downloadProgress! * 100).round()}%',
                    style: TextStyle(color: color),
                  ),
                if (error != null)
                  Text(
                    error!,
                    textAlign: TextAlign.center,
                    style: TextStyle(color: theme.colorScheme.error),
                  ),
                if (onReportPlayed != null)
                  TextButton(
                    onPressed: onReportPlayed,
                    child: const Text('Send playback receipt'),
                  ),
                if (actions.isNotEmpty)
                  Wrap(alignment: WrapAlignment.center, children: actions),
              ],
            ],
          ),
        );
      },
    );
  }
}
