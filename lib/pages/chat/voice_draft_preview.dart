// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/notion_conversation.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:just_audio/just_audio.dart';
import 'package:material_ui/material_ui.dart';

/// Plays a finished voice draft. Production uses [JustAudioVoiceDraftPlayer];
/// tests pass a fake.
abstract interface class VoiceDraftPlayer {
  /// Opens [path] (a file path or a web Blob URL); returns its length.
  Future<Duration?> open(String path);
  Future<void> play();
  Future<void> pause();
  Future<void> seek(Duration position);

  /// About five updates a second while playing (never per frame).
  Stream<Duration> get position;

  /// False again when playback ends.
  Stream<bool> get playing;
  Future<void> dispose();
}

class JustAudioVoiceDraftPlayer implements VoiceDraftPlayer {
  final AudioPlayer _player = AudioPlayer();

  @override
  Future<Duration?> open(String path) {
    final uri = Uri.tryParse(path);
    return uri == null || uri.scheme.isEmpty || uri.scheme == 'file'
        ? _player.setFilePath(uri?.scheme == 'file' ? uri!.toFilePath() : path)
        : _player.setUrl(path);
  }

  @override
  Future<void> play() async {
    if (_player.processingState == ProcessingState.completed) {
      await _player.seek(Duration.zero);
    }
    unawaited(_player.play());
  }

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> seek(Duration position) => _player.seek(position);

  @override
  Stream<Duration> get position => _player.createPositionStream(
    minPeriod: const Duration(milliseconds: 200),
    maxPeriod: const Duration(milliseconds: 200),
  );

  @override
  Stream<bool> get playing => _player.playerStateStream.map(
    (state) =>
        state.playing && state.processingState != ProcessingState.completed,
  );

  @override
  Future<void> dispose() => _player.dispose();
}

/// The listen-before-send row of a locked voice recording, in the place of
/// the live bars while it is paused: play/pause and a waveform to scrub
/// (Telegram's recorded audio panel, Signal's voice note draft).
///
/// The first play asks [prepare] for the finished file (the recording then
/// ends: it can be sent or deleted, not resumed). Position ticks rebuild
/// only the waveform and the clock.
class VoiceDraftPreview extends StatefulWidget {
  final Future<String?> Function() prepare;
  final Duration duration;
  final List<double> waveform;
  final VoiceDraftPlayer Function() createPlayer;
  final bool enabled;

  const VoiceDraftPreview({
    super.key,
    required this.prepare,
    required this.duration,
    required this.waveform,
    this.createPlayer = JustAudioVoiceDraftPlayer.new,
    this.enabled = true,
  });

  @override
  State<VoiceDraftPreview> createState() => _VoiceDraftPreviewState();
}

class _VoiceDraftPreviewState extends State<VoiceDraftPreview> {
  VoiceDraftPlayer? _player;
  Future<bool>? _opening;
  final _position = ValueNotifier<Duration>(Duration.zero);
  Duration? _length;
  bool _playing = false;
  double? _scrub;
  final _subscriptions = <StreamSubscription<Object?>>[];

  Duration get _total => _length ?? widget.duration;

  Future<bool> _open() => _opening ??= () async {
    final path = await widget.prepare();
    if (!mounted || path == null) return false;
    final player = widget.createPlayer();
    _player = player;
    try {
      final length = await player.open(path);
      if (!mounted) return false;
      _length = length != null && length > Duration.zero ? length : null;
      _subscriptions
        ..add(player.position.listen((value) => _position.value = value))
        ..add(
          player.playing.listen((value) {
            if (mounted && value != _playing) {
              setState(() => _playing = value);
            }
          }),
        );
      return true;
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          const SnackBar(
            content: Text(
              'This recording can’t be played here. You can still send it.',
            ),
          ),
        );
      }
      return false;
    }
  }();

  Future<void> _toggle() async {
    if (_playing) {
      await _player?.pause();
      return;
    }
    if (!await _open() || !mounted) return;
    await _player?.play();
  }

  Future<void> _seek(double value) async {
    if (!await _open() || !mounted) return;
    final target = Duration(
      milliseconds: (_total.inMilliseconds * value).round(),
    );
    _position.value = target;
    await _player?.seek(target);
  }

  @override
  void dispose() {
    for (final subscription in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _position.dispose();
    final player = _player;
    if (player != null) unawaited(player.dispose().catchError((Object _) {}));
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.notion.colors;
    final foreground = colors.text;
    return Row(
      children: [
        SizedBox.square(
          dimension: NotionSize.touchTarget,
          child: IconButton(
            key: const Key('voice_preview_play'),
            tooltip: _playing ? 'Pause recording' : 'Listen to recording',
            onPressed: widget.enabled ? _toggle : null,
            color: foreground,
            icon: NotionMorphSwitcher(
              child: Icon(
                _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
                key: ValueKey(_playing),
              ),
            ),
          ),
        ),
        Expanded(
          child: RepaintBoundary(
            child: ValueListenableBuilder<Duration>(
              valueListenable: _position,
              builder: (context, position, _) {
                final total = _total.inMilliseconds;
                final progress =
                    _scrub ??
                    (total <= 0 ? 0.0 : position.inMilliseconds / total).clamp(
                      0.0,
                      1.0,
                    );
                final shown = Duration(
                  milliseconds: (total * progress).round(),
                );
                return Row(
                  children: [
                    Expanded(
                      child: SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          trackHeight: 28,
                          trackShape: NotionWaveformTrackShape(widget.waveform),
                          activeTrackColor: foreground,
                          inactiveTrackColor: colors.textTertiary,
                          disabledActiveTrackColor: foreground,
                          disabledInactiveTrackColor: colors.textTertiary,
                          thumbColor: foreground,
                          overlayColor: foreground.withValues(alpha: .12),
                          thumbShape: const RoundSliderThumbShape(
                            enabledThumbRadius: 5,
                          ),
                          overlayShape: const RoundSliderOverlayShape(
                            overlayRadius: 12,
                          ),
                        ),
                        child: Slider(
                          key: const Key('voice_preview_seek'),
                          padding: const EdgeInsets.symmetric(
                            horizontal: NotionSpace.xs,
                          ),
                          value: progress,
                          semanticFormatterCallback: (value) => notionAudioTime(
                            Duration(milliseconds: (total * value).round()),
                          ),
                          onChanged: widget.enabled
                              ? (value) => setState(() => _scrub = value)
                              : null,
                          onChangeEnd: widget.enabled
                              ? (value) {
                                  setState(() => _scrub = null);
                                  unawaited(_seek(value));
                                }
                              : null,
                        ),
                      ),
                    ),
                    Text(
                      notionAudioTime(
                        _playing || position > Duration.zero || _scrub != null
                            ? shown
                            : _total,
                      ),
                      style: NotionType.body.copyWith(
                        color: foreground,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ),
      ],
    );
  }
}
