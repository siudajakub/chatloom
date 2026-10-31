// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// The finished transcript of one voice note, round or video, as the live
/// view in the full-screen players reads it. Never asks for a transcript:
/// it only shows one that private sync already has.
@immutable
class MediaTranscript {
  const MediaTranscript({
    required this.text,
    this.timing,
    this.durationSeconds,
  });

  final String text;

  /// The worker's stored timestamps, when it wrote any (none do yet).
  final Object? timing;

  /// Length of the transcribed audio as the worker measured it.
  final double? durationSeconds;

  /// Exact lines from stored timestamps; otherwise lines estimated over the
  /// first known length: the [player]'s, the worker's, the [declared] one.
  /// Null when no length is known.
  TranscriptTiming? timingFor(Duration? player, {Duration? declared}) {
    final exact = TranscriptTiming.tryParse(timing, text);
    if (exact != null) return exact;
    final seconds = durationSeconds;
    final measured = seconds != null && seconds > 0
        ? Duration(milliseconds: (seconds * 1000).round())
        : null;
    final total = [
      player,
      measured,
      declared,
    ].firstWhere((d) => d != null && d > Duration.zero, orElse: () => null);
    return total == null ? null : TranscriptTiming.approximate(text, total);
  }

  /// The done transcript of [job], or null.
  static MediaTranscript? of(TranscriptionJob? job) {
    final text = job?.text;
    if (job == null || job.state != JobState.done || text == null) return null;
    if (text.trim().isEmpty) return null;
    return MediaTranscript(
      text: text,
      timing: job.timing,
      durationSeconds: job.durationSeconds,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MediaTranscript &&
      other.text == text &&
      identical(other.timing, timing) &&
      other.durationSeconds == durationSeconds;

  @override
  int get hashCode =>
      Object.hash(text, identityHashCode(timing), durationSeconds);
}

/// The length a message declares for its media (`info.duration`, ms).
Duration? declaredMediaDuration(Event event) {
  final value = event.content
      .tryGetMap<String, Object?>('info')
      ?.tryGet<int>('duration');
  return value != null && value > 0 ? Duration(milliseconds: value) : null;
}

/// Whether the full-screen players show the live transcript; remembered on
/// this device, on by default.
abstract final class MediaTranscriptPreference {
  static final ValueNotifier<bool> visible = ValueNotifier(_load());

  static bool _load() {
    try {
      // Read the store directly: before it is initialised (tests, early
      // start) this throws quietly instead of logging a storage error.
      final store = AppSettings.store;
      return store.getBool(AppSettings.personalMediaTranscriptVisible.key) ??
          AppSettings.personalMediaTranscriptVisible.defaultValue;
    } catch (_) {
      return true;
    }
  }

  static void toggle() {
    final value = visible.value = !visible.value;
    try {
      unawaited(
        AppSettings.personalMediaTranscriptVisible
            .setItem(value)
            .catchError((Object _) {}),
      );
    } catch (_) {
      // Settings unavailable (tests, early start): the choice stays in memory.
    }
  }
}

/// Builds with the finished transcript of [event] (null when there is none
/// or [event] is null). Listens to private sync but rebuilds only when that
/// transcript changes.
class MediaTranscriptBuilder extends StatefulWidget {
  const MediaTranscriptBuilder({
    super.key,
    required this.event,
    required this.builder,
    @visibleForTesting this.personalClient,
  });

  final Event? event;
  final Widget Function(BuildContext context, MediaTranscript? transcript)
  builder;

  /// Test seam; production resolves the account's [PersonalClient].
  final PersonalClient? personalClient;

  @override
  State<MediaTranscriptBuilder> createState() => _MediaTranscriptBuilderState();
}

class _MediaTranscriptBuilderState extends State<MediaTranscriptBuilder> {
  PersonalClient? _personal;
  String? _id;
  MediaTranscript? _transcript;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(covariant MediaTranscriptBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event?.eventId != widget.event?.eventId ||
        !identical(oldWidget.event?.room.client, widget.event?.room.client) ||
        oldWidget.personalClient != widget.personalClient) {
      _personal?.removeListener(_onChanged);
      _attach();
    }
  }

  void _attach() {
    final event = widget.event;
    _personal = null;
    _id = null;
    if (event != null && !event.redacted) {
      try {
        final personal =
            widget.personalClient ?? PersonalClient.of(event.room.client);
        _id = personal.transcriptId(event);
        _personal = personal..addListener(_onChanged);
      } catch (_) {
        _personal = null;
      }
    }
    _transcript = _read();
  }

  MediaTranscript? _read() {
    final personal = _personal, id = _id;
    if (personal == null || id == null) return null;
    return MediaTranscript.of(personal.transcripts[id]);
  }

  void _onChanged() {
    if (!mounted) return;
    final next = _read();
    if (next == _transcript) return;
    setState(() => _transcript = next);
  }

  @override
  void dispose() {
    _personal?.removeListener(_onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _transcript);
}

/// Show / hide the live transcript, for the controls of a full-screen
/// player (over the media stage).
class MediaTranscriptToggle extends StatelessWidget {
  const MediaTranscriptToggle({super.key});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<bool>(
    valueListenable: MediaTranscriptPreference.visible,
    builder: (context, visible, _) => IconButton(
      key: const ValueKey('media-transcript-toggle'),
      tooltip: visible ? 'Hide transcript' : 'Show transcript',
      color: NotionMediaColors.onScrim,
      onPressed: MediaTranscriptPreference.toggle,
      icon: NotionMorphSwitcher(
        child: Icon(
          visible ? Icons.lyrics : Icons.lyrics_outlined,
          key: ValueKey(visible),
        ),
      ),
    ),
  );
}

/// A player position as a listenable: [source] notifies, [read] answers
/// (e.g. a `VideoPlayerController` and its `value.position`).
class MediaPositionListenable implements ValueListenable<Duration> {
  MediaPositionListenable(this.source, this.read);

  final Listenable source;
  final Duration Function() read;

  @override
  Duration get value => read();

  @override
  void addListener(VoidCallback listener) => source.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => source.removeListener(listener);
}

/// The transcript of a playing message, following [position] line by line
/// ([NotionSyncedTranscript]). Lines are exact when the worker stored
/// timestamps, otherwise estimated over the media length and labelled
/// "Approximate timing". Nothing when no length is known yet.
class MediaSyncedTranscript extends StatefulWidget {
  const MediaSyncedTranscript({
    super.key,
    required this.transcript,
    required this.position,
    this.duration,
    this.declaredDuration,
    this.onSeek,
  });

  final MediaTranscript transcript;
  final ValueListenable<Duration> position;

  /// The player's length, when it has loaded the media.
  final Duration? duration;

  /// The length the message declares (fallback).
  final Duration? declaredDuration;
  final ValueChanged<Duration>? onSeek;

  /// Caption of estimated lines.
  static const approximateCaption = 'Approximate timing';

  @override
  State<MediaSyncedTranscript> createState() => _MediaSyncedTranscriptState();
}

class _MediaSyncedTranscriptState extends State<MediaSyncedTranscript> {
  Object? _key;
  List<NotionTranscriptLine> _lines = const [];
  bool _approximate = false;

  void _update() {
    final key = (
      widget.transcript,
      widget.duration?.inMilliseconds,
      widget.declaredDuration?.inMilliseconds,
    );
    if (key == _key) return;
    _key = key;
    final timing = widget.transcript.timingFor(
      widget.duration,
      declared: widget.declaredDuration,
    );
    _approximate = timing?.approximate ?? false;
    _lines = [
      for (final line in timing?.lines ?? const <TranscriptLine>[])
        NotionTranscriptLine(
          start: line.start,
          text: line.text,
          words: [
            for (final word in line.words)
              NotionTranscriptWord(
                start: word.start,
                textStart: word.textStart,
                textEnd: word.textEnd,
              ),
          ],
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    _update();
    if (_lines.isEmpty) return const SizedBox.shrink();
    return NotionSyncedTranscript(
      key: const ValueKey('media-synced-transcript'),
      lines: _lines,
      position: widget.position,
      onSeek: widget.onSeek,
      caption: _approximate ? MediaSyncedTranscript.approximateCaption : null,
    );
  }
}
