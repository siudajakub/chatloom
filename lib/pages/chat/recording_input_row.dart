// SPDX-FileCopyrightText: 2019-Present Christian Kußowski
// SPDX-FileCopyrightText: 2019-Present Contributors to FluffyChat
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:math' as math;

import 'package:chatloom/pages/chat/chat_input_row.dart';
import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/pages/chat/recording_view_model.dart';
import 'package:chatloom/pages/chat/voice_record_button.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';

/// Composer replacement while a voice message is being recorded.
///
/// [RecordingDot] lives in voice_record_button.dart (shared with the hold
/// overlay, and free of the app graph for the presentation harness).
///
/// Layout: delete · pause/resume · live dot + timer · waveform · send.
/// Every control is a 48 dp target with an English tooltip/semantics label.
class RecordingInputRow extends StatelessWidget {
  final RecordingViewModelState state;
  final Future<bool> Function(String, int, List<int>, String) onSend;
  const RecordingInputRow({
    required this.state,
    required this.onSend,
    super.key,
  });

  /// `m:ss`, the same clock as the hold overlay and the audio player.
  static String formatDuration(Duration duration) => notionAudioTime(duration);

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final time = formatDuration(state.duration);
    final paused = state.isPaused;
    final status = state.isSending
        ? 'Sending voice message'
        : state.limitReached
        ? 'Recording limit reached'
        : paused
        ? 'Recording paused'
        : 'Recording';
    return SizedBox(
      height: ChatInputRow.height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(width: 4),
          IconButton(
            key: const Key('voice_delete_button'),
            tooltip: 'Delete recording',
            style: IconButton.styleFrom(
              minimumSize: const Size.square(NotionSize.touchTarget),
            ),
            icon: const Icon(Icons.delete_outline),
            color: colors.danger,
            onPressed: state.isSending ? null : state.requestDiscard,
          ),
          if (paused)
            IconButton(
              key: const Key('voice_resume_button'),
              tooltip: 'Resume recording',
              style: IconButton.styleFrom(
                minimumSize: const Size.square(NotionSize.touchTarget),
              ),
              color: colors.text,
              icon: const Icon(Icons.mic_none_outlined),
              onPressed: state.canResume ? state.resume : null,
            )
          else
            IconButton(
              key: const Key('voice_pause_button'),
              tooltip: 'Pause recording',
              style: IconButton.styleFrom(
                minimumSize: const Size.square(NotionSize.touchTarget),
              ),
              color: colors.text,
              icon: const Icon(Icons.pause),
              onPressed: state.controlsBusy ? null : state.pause,
            ),
          const SizedBox(width: 4),
          Semantics(
            container: true,
            liveRegion: paused,
            label: '$status, $time',
            child: ExcludeSemantics(
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  RecordingDot(active: !paused && !state.isSending),
                  const SizedBox(width: 8),
                  Text(
                    time,
                    style: NotionType.body.copyWith(
                      color: state.limitReached ? colors.danger : colors.text,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: ExcludeSemantics(
              child: SizedBox(
                height: 32,
                child: RepaintBoundary(
                  child: CustomPaint(
                    painter: _LiveWaveformPainter(
                      amplitudes: state.amplitudeTimeline,
                      revision: state.amplitudeTimeline.length,
                      duration: state.duration,
                      color: paused ? colors.textTertiary : colors.text,
                    ),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          KeyedSubtree(
            key: const Key('voice_send_button'),
            child: NotionSendButton(
              tooltip: 'Send voice message',
              busy: state.isSending,
              onPressed: state.controlsBusy
                  ? null
                  : () => state.stopAndSend(onSend),
            ),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }
}

/// Right-aligned live amplitude bars (newest on the right). A painter avoids
/// rebuilding ~100 bar widgets ten times per second.
class _LiveWaveformPainter extends CustomPainter {
  final List<double> amplitudes;
  final int revision;
  final Duration duration;
  final Color color;
  _LiveWaveformPainter({
    required this.amplitudes,
    required this.revision,
    required this.duration,
    required this.color,
  });

  static const _barWidth = 3.0, _gap = 2.0;

  @override
  void paint(Canvas canvas, Size size) {
    if (amplitudes.isEmpty || size.width <= 0) return;
    final paint = Paint()
      ..color = color
      ..strokeCap = StrokeCap.round
      ..strokeWidth = _barWidth;
    final capacity = (size.width / (_barWidth + _gap)).floor();
    final count = math.min(capacity, amplitudes.length);
    final mid = size.height / 2;
    for (var i = 0; i < count; i++) {
      final amplitude = amplitudes[amplitudes.length - 1 - i];
      final x = size.width - _barWidth / 2 - i * (_barWidth + _gap);
      final half = math.max(1.5, size.height * (amplitude / 100) / 2);
      canvas.drawLine(Offset(x, mid - half), Offset(x, mid + half), paint);
    }
  }

  @override
  bool shouldRepaint(_LiveWaveformPainter old) =>
      old.revision != revision ||
      old.duration != duration ||
      old.color != color ||
      !identical(old.amplitudes, amplitudes);
}
