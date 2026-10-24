// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'notion_glass.dart';
import 'notion_primitives.dart';
import 'notion_switchers.dart';
import 'notion_tokens.dart';

/// Secondary media actions stay available without crowding playback controls.
class NotionMediaAction {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  const NotionMediaAction({
    required this.label,
    required this.icon,
    required this.onPressed,
  });
}

class NotionMediaActionsButton extends StatelessWidget {
  final List<NotionMediaAction> actions;
  final String label;
  final Color? foregroundColor;
  final Color? backgroundColor;

  const NotionMediaActionsButton({
    super.key,
    required this.actions,
    this.label = 'More options',
    this.foregroundColor,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) => IconButton(
    tooltip: label,
    color: foregroundColor ?? NotionMediaColors.onScrim,
    style: backgroundColor == null
        ? null
        : IconButton.styleFrom(
            backgroundColor: backgroundColor,
            shape: NotionShapes.pill,
          ),
    onPressed: actions.isEmpty
        ? null
        : () async {
            // Return the selected action before invoking it: save/share may open
            // another route and stop may dispose the player that opened this menu.
            final action = await showNotionSheet<NotionMediaAction>(
              context: context,
              title: label,
              builder: (context) => SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final action in actions)
                      NotionGlassMenuRow(
                        leading: Icon(action.icon),
                        title: action.label,
                        onTap: action.onPressed == null
                            ? null
                            : () => Navigator.of(context).pop(action),
                      ),
                  ],
                ),
              ),
            );
            if (context.mounted) action?.onPressed?.call();
          },
    icon: const Icon(Icons.more_horiz),
  );
}

/// The same quiet transport below voice notes, video and enlarged rounds.
/// Owners supply state and callbacks; this widget never owns a decoder.
class NotionMediaPlaybackControls extends StatefulWidget {
  final bool playing;
  final Duration position, duration;
  final double speed;
  final VoidCallback? onToggle, onSpeedCycle, onSpeedPicker;
  final FutureOr<void> Function(Duration)? onSeek;
  final String playLabel, pauseLabel;
  final Widget? trailing;
  final Widget? seekControl;

  const NotionMediaPlaybackControls({
    super.key,
    required this.playing,
    required this.position,
    required this.duration,
    required this.speed,
    this.onToggle,
    this.onSeek,
    this.onSpeedCycle,
    this.onSpeedPicker,
    this.playLabel = 'Play',
    this.pauseLabel = 'Pause',
    this.trailing,
    this.seekControl,
  });

  static String formatTime(Duration value) {
    final seconds = value.inSeconds.clamp(0, 1 << 31);
    final hours = seconds ~/ 3600;
    final minutes = hours > 0
        ? ((seconds ~/ 60) % 60).toString().padLeft(2, '0')
        : (seconds ~/ 60).toString();
    return '${hours > 0 ? '$hours:' : ''}$minutes:${(seconds % 60).toString().padLeft(2, '0')}';
  }

  @override
  State<NotionMediaPlaybackControls> createState() =>
      _NotionMediaPlaybackControlsState();
}

class _NotionMediaPlaybackControlsState
    extends State<NotionMediaPlaybackControls> {
  double? _dragMs;

  Future<void> _seek(double ms) async {
    setState(() => _dragMs = ms);
    try {
      await widget.onSeek?.call(Duration(milliseconds: ms.round()));
    } catch (_) {
      // A failed native seek keeps the actual player position. Never send
      // an unawaited transport callback into the app's global error dialog.
    } finally {
      if (mounted && _dragMs == ms) setState(() => _dragMs = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final totalMs = widget.duration.inMilliseconds > 0
        ? widget.duration.inMilliseconds.toDouble()
        : 1.0;
    final currentMs = (_dragMs ?? widget.position.inMilliseconds.toDouble())
        .clamp(0.0, totalMs);
    final position = Duration(milliseconds: currentMs.round());
    final speed = widget.speed % 1 == 0
        ? widget.speed.toStringAsFixed(0)
        : widget.speed.toString();
    return IconTheme.merge(
      data: const IconThemeData(color: NotionMediaColors.onScrim),
      child: DefaultTextStyle.merge(
        style: NotionType.caption.copyWith(color: NotionMediaColors.onScrim),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            widget.seekControl ??
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: NotionMediaColors.onScrim,
                    thumbColor: NotionMediaColors.onScrim,
                    inactiveTrackColor: NotionMediaColors.onScrim.withAlpha(80),
                  ),
                  child: Slider(
                    value: currentMs,
                    max: totalMs,
                    semanticFormatterCallback: (value) =>
                        NotionMediaPlaybackControls.formatTime(
                          Duration(milliseconds: value.round()),
                        ),
                    onChangeStart: widget.onSeek == null
                        ? null
                        : (value) => setState(() => _dragMs = value),
                    onChanged:
                        widget.onSeek == null ||
                            widget.duration <= Duration.zero
                        ? null
                        : (value) => setState(() => _dragMs = value),
                    onChangeEnd: widget.onSeek == null
                        ? null
                        : (value) => unawaited(_seek(value)),
                  ),
                ),
            Row(
              children: [
                IconButton(
                  tooltip: widget.playing
                      ? widget.pauseLabel
                      : widget.playLabel,
                  color: NotionMediaColors.onScrim,
                  onPressed: widget.onToggle,
                  icon: NotionMorphSwitcher(
                    child: Icon(
                      widget.playing ? Icons.pause : Icons.play_arrow,
                      key: ValueKey(widget.playing),
                    ),
                  ),
                ),
                Expanded(
                  child: Text(
                    '${NotionMediaPlaybackControls.formatTime(position)} / '
                    '${NotionMediaPlaybackControls.formatTime(widget.duration)}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (widget.onSpeedCycle != null)
                  Semantics(
                    label: 'Playback speed',
                    hint: widget.onSpeedPicker == null
                        ? null
                        : defaultTargetPlatform == TargetPlatform.macOS
                        ? 'Right-click for more speeds'
                        : 'Long press for more speeds',
                    // A right click opens the picker as a long press does.
                    child: GestureDetector(
                      onSecondaryTap: widget.onSpeedPicker,
                      child: TextButton(
                        style: TextButton.styleFrom(
                          foregroundColor: NotionMediaColors.onScrim,
                          minimumSize: const Size.square(
                            NotionSize.touchTarget,
                          ),
                        ),
                        onPressed: widget.onSpeedCycle,
                        onLongPress: widget.onSpeedPicker,
                        child: Text('$speed×'),
                      ),
                    ),
                  ),
                ?widget.trailing,
              ],
            ),
          ],
        ),
      ),
    );
  }
}
