// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat/conversation_motion.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_transcribe_button.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// Width of the transcript's leading rule; the caption row below starts at
/// the same inset as the transcript text.
const double _ruleWidth = 2;
const double _textInset = _ruleWidth + NotionSpace.xs;

const _syncRequiredMessage =
    'Connect private sync in Settings. Only audio from the selected message is sent to OpenAI.';
const _startFailedMessage = 'Couldn’t start transcription. Try again.';

const _busyStates = {
  JobState.waitingSync,
  JobState.waitingKeys,
  JobState.queued,
  JobState.processing,
};

/// Short, human reason for a failed or skipped transcription job. Never an
/// error code: the panel shows it next to a Retry button.
String transcriptionErrorText(String? errorCode) => switch (errorCode) {
  'protected_media' ||
  'invalid_round_format' ||
  'invalid_media_format' ||
  'not_audio' => 'This media can’t be transcribed',
  'no_audio_track' => 'This video has no sound',
  'media_conversion_failed' ||
  'invalid_audio_duration' ||
  'empty_audio' => 'Couldn’t read the audio',
  'empty_transcript' => 'No speech detected',
  'source_too_large' || 'audio_chunk_too_large' => 'Too large to transcribe',
  'local_source_unavailable' ||
  'source_status_unknown' ||
  'source_unavailable' ||
  'room_unavailable' => 'Couldn’t load the audio',
  'auto_skipped_duration' => 'Too long to transcribe automatically',
  'auto_skipped_size' ||
  'auto_skipped_size_cap' ||
  'auto_skipped_unknown_size' => 'Too large to transcribe automatically',
  'auto_skipped_budget' => 'Daily limit for automatic transcripts reached',
  'invalid_language' => 'This language isn’t supported',
  final String code when code.startsWith('openai_') =>
    'Transcription service unavailable',
  _ => 'Couldn’t transcribe this message',
};

/// A busy job the worker cannot finish until something outside it changes;
/// the panel then says so under its placeholder. Ordinary progress (queued,
/// processing, a quick retry) has no text at all.
String? transcriptionDelayText(TranscriptionJob job) =>
    job.state == JobState.waitingKeys
    ? 'Waiting for this message to decrypt'
    : null;

/// Transcription controls and result for one voice note, audio, round or
/// video message (also media sent as a file).
///
/// Listens to [PersonalClient] but rebuilds only when this event's job (or
/// its automatic-pending flag) actually changes, so a timeline full of voice
/// messages does not rebuild on every private-sync notification. Renders
/// nothing for media the paired worker cannot transcribe, and for automatic
/// jobs that found no audio track (a silent clip).
///
/// Telegram-style: while a transcript is on its way (automatic, or asked for
/// with Transcribe) the bubble shows shimmering placeholder lines and no
/// status text, then the text fades in at the same place. Only a failure,
/// a skipped limit or a job stuck on missing keys is explained in words.
class TranscriptPanel extends StatefulWidget {
  final Event event;

  /// Text colour of the surrounding bubble; the panel derives its lines and
  /// fills from it. Defaults to `onSurface`.
  final Color? foregroundColor;

  /// Test seam; production resolves the account's [PersonalClient].
  final PersonalClient? personalClient;

  const TranscriptPanel({
    super.key,
    required this.event,
    this.foregroundColor,
    @visibleForTesting this.personalClient,
  });

  /// Cheap, synchronous pre-check for bubbles that add a transcript slot:
  /// true when [event] carries speech media at all (the panel itself then
  /// checks what the paired worker supports).
  static bool mayTranscribe(Event event) =>
      !event.redacted && PersonalClient.autoTranscriptionKind(event) != null;
  @override
  State<TranscriptPanel> createState() => _TranscriptPanelState();
}

enum _Phase { idle, busy, done, error }

const _failedStates = {JobState.failed, JobState.unknown, JobState.conflict};

class _TranscriptPanelState extends State<TranscriptPanel> {
  late PersonalClient personal;
  String? _id;
  TranscriptionJob? _job;
  Object? _signature;
  bool _requesting = false;

  /// Per-message language choice; null entry in [_hasOverride] = synced default.
  bool _hasOverride = false;
  String? _languageOverride;

  String? get _language =>
      _hasOverride ? _languageOverride : personal.transcriptionDefaultLanguage;

  @override
  void initState() {
    super.initState();
    _attach();
  }

  @override
  void didUpdateWidget(covariant TranscriptPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.event.eventId != widget.event.eventId ||
        oldWidget.event.room.client != widget.event.room.client ||
        oldWidget.personalClient != widget.personalClient) {
      personal.removeListener(_onPersonalChanged);
      _hasOverride = false;
      _languageOverride = null;
      _attach();
    }
  }

  void _attach() {
    personal =
        widget.personalClient ?? PersonalClient.of(widget.event.room.client);
    try {
      _id = personal.transcriptId(widget.event);
    } catch (_) {
      _id = null;
    }
    _job = _id == null ? null : personal.transcripts[_id];
    _signature = _signatureOf();
    personal.addListener(_onPersonalChanged);
    // Hydrate the local replica once if nothing has yet. A full load() would
    // re-validate the journal and notify every panel on screen.
    if (!personal.ready) {
      unawaited(personal.loadLocal().catchError((_) {}));
    }
  }

  Object _signatureOf() {
    final job = _id == null ? null : personal.transcripts[_id];
    return (
      job?.state,
      job?.text,
      job?.language,
      job?.errorCode,
      job?.estimatedCostUsd,
      job != null && personal.isTranscriptCancellationPending(job.id),
      job == null && _autoPending(),
      job == null && _offered(),
      personal.transcriptionDefaultLanguage,
    );
  }

  bool _offered() {
    try {
      return personal.transcribableKind(widget.event) != null;
    } catch (_) {
      return false;
    }
  }

  bool _autoPending() {
    try {
      return personal.autoTranscriptPending(widget.event);
    } catch (_) {
      return false;
    }
  }

  void _onPersonalChanged() {
    if (!mounted) return;
    final next = _signatureOf();
    if (next == _signature) return;
    setState(() {
      _signature = next;
      _job = _id == null ? null : personal.transcripts[_id];
    });
  }

  @override
  void dispose() {
    personal.removeListener(_onPersonalChanged);
    super.dispose();
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(
      context,
    )?.showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _request([String? language]) async {
    if (_requesting) return;
    setState(() => _requesting = true);
    try {
      await personal.transcribe(widget.event, language: language ?? _language);
    } on StateError catch (error) {
      _snack(
        error.message == 'Audio is unavailable'
            ? 'This audio can’t be transcribed.'
            : _failureMessage(),
      );
    } catch (_) {
      _snack(_failureMessage());
    } finally {
      if (mounted) {
        setState(() {
          _requesting = false;
          _job = _id == null ? null : personal.transcripts[_id];
          _signature = _signatureOf();
        });
      }
    }
  }

  /// Private sync is only blamed when it is actually not connected.
  String _failureMessage() =>
      personal.ready ? _startFailedMessage : _syncRequiredMessage;

  Future<void> _cancel(TranscriptionJob job) async {
    try {
      await personal.cancelTranscript(job.id);
    } catch (_) {
      _snack(
        'Cancellation was not confirmed. Check the transcription state before retrying.',
      );
    }
  }

  void _selectLanguage(String? language) => setState(() {
    _hasOverride = true;
    _languageOverride = language;
  });

  @override
  Widget build(BuildContext context) {
    if (widget.event.redacted) return const SizedBox.shrink();
    final foreground =
        widget.foregroundColor ?? Theme.of(context).colorScheme.onSurface;
    final job = _job;
    if (job == null && !_offered()) return const SizedBox.shrink();
    // A silent clip found by automatic work is not worth a line of UI.
    if (job != null &&
        job.automatic &&
        job.state == JobState.cancelled &&
        job.errorCode == 'no_audio_track') {
      return const SizedBox.shrink();
    }
    final busy =
        _requesting ||
        (job == null && _autoPending()) ||
        (job != null && _busyStates.contains(job.state));
    final hasText = job?.state == JobState.done && (job?.text ?? '').isNotEmpty;
    final phase = busy
        ? _Phase.busy
        : hasText
        ? _Phase.done
        : _failed(job)
        ? _Phase.error
        : _Phase.idle;

    final child = switch (phase) {
      _Phase.busy => _busy(job, foreground),
      _Phase.done => _done(job!, foreground),
      _Phase.error => _error(job!, foreground),
      _Phase.idle => _idle(job, foreground),
    };
    // The panel grows to the new phase while the phases fade through
    // (placeholder → text, or an error). Every busy step (pending, queued,
    // processing) is one phase, so the placeholder never restarts.
    // Keep the timeline selection recognizer out of this message surface.
    // Copy remains available in Transcript options.
    return SelectionContainer.disabled(
      child: Padding(
        padding: const EdgeInsets.only(top: NotionSpace.xxs),
        child: AnimatedSize(
          duration: ConversationMotion.sizeDuration(
            context,
            NotionMotion.medium,
          ),
          alignment: AlignmentDirectional.topStart,
          curve: NotionMotion.emphasized,
          child: NotionFadeThrough(
            duration: NotionMotion.short,
            child: KeyedSubtree(key: ValueKey(phase), child: child),
          ),
        ),
      ),
    );
  }

  Widget _caption(String text, Color foreground) => Text(
    text,
    style: NotionType.caption.copyWith(
      color: foreground.withValues(alpha: .72),
      height: 1.35,
    ),
  );

  /// Failed, unknown or skipped by a limit. A job switched off by the user
  /// or the operator (kind or automatic transcription off) is not an error:
  /// the plain Transcribe button stays.
  static bool _failed(TranscriptionJob? job) {
    if (job == null) return false;
    final code = job.errorCode;
    if (code == 'auto_disabled' || code == 'auto_skipped_kind') return false;
    if (_failedStates.contains(job.state)) return true;
    return job.state == JobState.cancelled &&
        (code?.startsWith('auto_skipped_') ?? false);
  }

  /// A transcript on its way: shimmering placeholder lines where the text
  /// will appear, no status words. A request this device made by hand can
  /// be cancelled (it may be a long video); automatic work cannot.
  Widget _busy(TranscriptionJob? job, Color foreground) {
    final manual =
        job != null && !job.automatic && _busyStates.contains(job.state);
    final cancelling =
        job != null && personal.isTranscriptCancellationPending(job.id);
    final delay = job == null ? null : transcriptionDelayText(job);
    return Semantics(
      key: const ValueKey('transcript-busy'),
      container: true,
      liveRegion: true,
      label: delay ?? 'Transcribing',
      child: Padding(
        padding: const EdgeInsetsDirectional.only(
          start: _textInset,
          top: NotionSpace.xxs,
          bottom: NotionSpace.xxs,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            // One row in every busy step, so the placeholder keeps its
            // animation when a job appears or a cancel button joins it.
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Flexible(
                  child: ExcludeSemantics(
                    child: NotionShimmerLines(color: foreground),
                  ),
                ),
                if (manual)
                  IconButton(
                    key: const ValueKey('transcribe-cancel'),
                    tooltip: 'Cancel transcription',
                    style: IconButton.styleFrom(
                      foregroundColor: foreground.withValues(alpha: .72),
                      disabledForegroundColor: foreground.withValues(
                        alpha: .38,
                      ),
                      minimumSize: const Size.square(32),
                      tapTargetSize: MaterialTapTargetSize.padded,
                    ),
                    onPressed: cancelling ? null : () => _cancel(job),
                    icon: const Icon(
                      Icons.close_rounded,
                      size: NotionSize.iconSm,
                    ),
                  ),
              ],
            ),
            if (delay != null)
              ExcludeSemantics(child: _caption(delay, foreground)),
          ],
        ),
      ),
    );
  }

  Widget _idle(TranscriptionJob? job, Color foreground) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      NotionTranscribeSplitButton(
        label: job?.state == JobState.done ? 'Transcribe again' : 'Transcribe',
        language: _language,
        foregroundColor: foreground,
        onTranscribe: _request,
        onLanguageSelected: _selectLanguage,
      ),
      if (job?.state == JobState.done)
        _caption('No speech detected', foreground),
    ],
  );

  Widget _error(TranscriptionJob job, Color foreground) {
    final reason = switch (job.state) {
      JobState.unknown => 'The result is unknown. Retrying may cost again.',
      JobState.conflict =>
        'Changed on another device. Check the result before retrying.',
      _ => transcriptionErrorText(job.errorCode),
    };
    // A limit is not a failure: asking by hand simply transcribes it.
    final skipped = job.state == JobState.cancelled;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Semantics(
          liveRegion: true,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                skipped
                    ? Icons.info_outline_rounded
                    : Icons.error_outline_rounded,
                size: NotionSize.iconSm,
                color: foreground.withValues(alpha: .72),
              ),
              const SizedBox(width: NotionSpace.xxs),
              Flexible(child: _caption(reason, foreground)),
            ],
          ),
        ),
        NotionTranscribeSplitButton(
          label: skipped ? 'Transcribe' : 'Retry',
          icon: skipped ? Icons.notes_rounded : Icons.refresh_rounded,
          language: _language,
          foregroundColor: foreground,
          onTranscribe: _request,
          onLanguageSelected: _selectLanguage,
        ),
      ],
    );
  }

  Widget _done(TranscriptionJob job, Color foreground) {
    final text = job.text!;
    final cost = job.estimatedCostUsd;
    final caption =
        'Transcript · ${notionTranscriptionLanguageCode(job.language)}';
    return Column(
      key: const ValueKey('transcript-done'),
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsetsDirectional.only(
            start: _textInset - _ruleWidth,
          ),
          decoration: BoxDecoration(
            border: BorderDirectional(
              start: BorderSide(
                color: foreground.withValues(alpha: .3),
                width: _ruleWidth,
              ),
            ),
          ),
          child: Text(
            text,
            style: NotionType.callout.copyWith(color: foreground),
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsetsDirectional.only(start: _textInset),
              child: Tooltip(
                message: cost == null
                    ? caption
                    : 'Estimated cost: \$${cost.toStringAsFixed(4)}',
                child: _caption(caption, foreground),
              ),
            ),
            MenuAnchor(
              menuChildren: [
                SubmenuButton(
                  key: const ValueKey('transcript-again'),
                  leadingIcon: const Icon(
                    Icons.refresh_rounded,
                    size: NotionSize.icon,
                  ),
                  menuChildren: notionTranscriptionLanguageItems(
                    selected: job.language,
                    onSelected: (language) {
                      _selectLanguage(language);
                      _request(language);
                    },
                  ),
                  child: const Text('Transcribe again'),
                ),
                MenuItemButton(
                  key: const ValueKey('transcript-copy'),
                  leadingIcon: const Icon(
                    Icons.copy_rounded,
                    size: NotionSize.icon,
                  ),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: text));
                    _snack('Transcript copied');
                  },
                  child: const Text('Copy'),
                ),
              ],
              builder: (context, controller, _) => IconButton(
                key: const ValueKey('transcript-menu'),
                tooltip: 'Transcript options',
                style: IconButton.styleFrom(
                  foregroundColor: foreground.withValues(alpha: .72),
                  minimumSize: const Size.square(32),
                  tapTargetSize: MaterialTapTargetSize.padded,
                ),
                onPressed: () =>
                    controller.isOpen ? controller.close() : controller.open(),
                icon: const Icon(
                  Icons.more_horiz_rounded,
                  size: NotionSize.icon,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
