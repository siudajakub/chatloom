// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/pages/chat/conversation_motion.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/ui/notion_transcribe_button.dart';
import 'package:fluffychat/ui/notion/notion.dart';
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

/// Short, user-facing reason for a failed or skipped transcription job.
String transcriptionErrorText(String? errorCode) => switch (errorCode) {
  'protected_media' ||
  'invalid_round_format' => 'Protected or unsupported media',
  'media_conversion_failed' ||
  'invalid_audio_duration' ||
  'empty_audio' => 'Couldn’t read the audio track',
  'empty_transcript' => 'No speech detected',
  'source_too_large' || 'audio_chunk_too_large' => 'Too large to transcribe',
  'local_source_unavailable' ||
  'source_status_unknown' => 'Source temporarily unavailable',
  'auto_skipped_duration' ||
  'auto_skipped_budget' => 'Not transcribed automatically (limit)',
  'invalid_language' => 'Unsupported transcription language',
  final String code when code.startsWith('openai_') =>
    'Transcription service error',
  _ => 'Couldn’t process this audio',
};

/// Busy label for a running transcription. [state] is the job's busy state,
/// or null before a job exists (a manual request starting, or an automatic
/// transcription pending).
String transcriptionBusyLabel(JobState? state, {bool requesting = false}) =>
    switch (state) {
      JobState.waitingSync => 'Waiting for sync',
      JobState.waitingKeys => 'Waiting for keys',
      JobState.queued => 'Queued',
      JobState.processing => 'Transcribing…',
      _ => requesting ? 'Starting…' : 'Transcribing…',
    };

/// Transcription controls and result for one voice or round message.
///
/// Listens to [PersonalClient] but rebuilds only when this event's job (or
/// its automatic-pending flag) actually changes, so a timeline full of voice
/// messages does not rebuild on every private-sync notification.
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
  @override
  State<TranscriptPanel> createState() => _TranscriptPanelState();
}

enum _Phase { idle, busy, done, error }

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
      personal.transcriptionDefaultLanguage,
    );
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
    final autoPending = job == null && _autoPending();
    final busy =
        _requesting ||
        autoPending ||
        (job != null && _busyStates.contains(job.state));
    final hasText = job?.state == JobState.done && (job?.text ?? '').isNotEmpty;
    final phase = busy
        ? _Phase.busy
        : hasText
        ? _Phase.done
        : job != null &&
              {
                JobState.failed,
                JobState.unknown,
                JobState.conflict,
              }.contains(job.state)
        ? _Phase.error
        : job?.state == JobState.cancelled &&
              (job?.errorCode?.startsWith('auto_skipped_') ?? false)
        ? _Phase.error
        : _Phase.idle;

    final child = switch (phase) {
      _Phase.busy => _busy(job, foreground),
      _Phase.done => _done(job!, foreground),
      _Phase.error => _error(job!, foreground),
      _Phase.idle => _idle(job, foreground),
    };
    // The panel grows to the new phase while the phases fade through
    // (requesting → transcribing → text, or an error).
    return Padding(
      padding: const EdgeInsets.only(top: NotionSpace.xxs),
      child: AnimatedSize(
        duration: ConversationMotion.sizeDuration(context, NotionMotion.medium),
        alignment: AlignmentDirectional.topStart,
        curve: NotionMotion.emphasized,
        child: NotionFadeThrough(
          duration: NotionMotion.short,
          child: KeyedSubtree(key: ValueKey(phase), child: child),
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

  Widget _busy(TranscriptionJob? job, Color foreground) {
    final cancelling =
        job != null && personal.isTranscriptCancellationPending(job.id);
    final label = transcriptionBusyLabel(
      job != null && _busyStates.contains(job.state) ? job.state : null,
      requesting: _requesting,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        NotionTranscribeSplitButton(
          busy: true,
          label: label,
          language: job?.language ?? _language,
          cancelling: cancelling,
          foregroundColor: foreground,
          onCancel: job == null ? null : () => _cancel(job),
        ),
        if (cancelling)
          _caption(
            'Cancellation requested. Processing may already have started.',
            foreground,
          ),
      ],
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
      if (job?.state == JobState.cancelled)
        _caption('Transcription cancelled.', foreground),
      if (job?.state == JobState.paused)
        _caption('Transcription paused.', foreground),
    ],
  );

  Widget _error(TranscriptionJob job, Color foreground) {
    final reason = switch (job.state) {
      JobState.unknown => 'The result is unknown. Retrying may cost again.',
      JobState.conflict =>
        'Changed on another device. Check the result before retrying.',
      _ => transcriptionErrorText(job.errorCode),
    };
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
                Icons.error_outline_rounded,
                size: NotionSize.iconSm,
                color: foreground.withValues(alpha: .72),
              ),
              const SizedBox(width: NotionSpace.xxs),
              Flexible(child: _caption(reason, foreground)),
            ],
          ),
        ),
        NotionTranscribeSplitButton(
          label: 'Retry',
          icon: Icons.refresh_rounded,
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
          child: SelectableText(
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
