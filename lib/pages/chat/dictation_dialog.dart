// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:math' as math;

import 'package:chatloom/personal/dictation/dictation_service.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import 'notion_conversation.dart' show notionAudioTime;
import 'recording_view_model.dart';
import 'voice_record_button.dart' show RecordingDot;

typedef DictationTranscribe =
    Future<String> Function(String path, int durationMs, String fileName);

/// Captures a private audio draft and sends only explicitly confirmed text.
/// The transcriber receives the local file; no voice-message sender is used.
Future<void> showDictationDialog(
  BuildContext context, {
  required Room room,
  required DictationTranscribe transcribe,
  required Future<bool> Function(String text) onSend,
  required bool Function() canSend,
  String? Function(String text)? validateText,
  Future<void> Function()? onCancel,
}) async {
  await showNotionCustomDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => DictationDialog(
      room: room,
      transcribe: transcribe,
      onSend: onSend,
      canSend: canSend,
      validateText: validateText,
      onCancel: onCancel,
    ),
  );
}

enum DictationPhase {
  starting,
  recording,
  transcribing,
  review,
  error,
  sending,
}

class DictationDialog extends StatefulWidget {
  const DictationDialog({
    super.key,
    required this.room,
    required this.transcribe,
    required this.onSend,
    required this.canSend,
    this.validateText,
    this.onCancel,
  });

  final Room room;
  final DictationTranscribe transcribe;
  final Future<bool> Function(String text) onSend;
  final bool Function() canSend;
  final String? Function(String text)? validateText;
  final Future<void> Function()? onCancel;

  @override
  State<DictationDialog> createState() => _DictationDialogState();
}

class _DictationDialogState extends State<DictationDialog>
    with WidgetsBindingObserver {
  final _recorderKey = GlobalKey<RecordingViewModelState>();
  final _editor = TextEditingController();
  DictationPhase _phase = DictationPhase.starting;
  String? _error;
  bool _closing = false;
  bool _allowPop = false;
  bool _confirmationOpen = false;
  bool _started = false;
  bool _sent = false;
  AppLifecycleState _appState = AppLifecycleState.resumed;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _appState =
        WidgetsBinding.instance.lifecycleState ?? AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // A lock, account switch or enclosing route removal can bypass the
    // close button. Cancel the private worker job on that path as well.
    if (!_closing && !_sent) {
      unawaited(widget.onCancel?.call().catchError((Object _) {}));
    }
    _editor.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _appState = state;
    if (state == AppLifecycleState.resumed) {
      return;
    }
    if (_phase == DictationPhase.starting &&
        state != AppLifecycleState.inactive) {
      // Permission/native startup can still be waiting. Invalidate the
      // capture generation now so its late completion cannot activate a mic
      // in the background. A permission dialog's transient inactive state
      // only pauses the recording once startup completes.
      _recorderKey.currentState?.cancel();
      return;
    }
    if (_phase != DictationPhase.recording) return;
    // A backgrounded dictation never keeps the microphone running.
    unawaited(_recorderKey.currentState?.pause());
  }

  String _words(String pl, String en) =>
      Localizations.localeOf(context).languageCode == 'pl' ? pl : en;

  Future<void> _start() async {
    if (!mounted || _closing) return;
    if (_appState != AppLifecycleState.resumed) {
      setState(() {
        _phase = DictationPhase.error;
        _error = _words(
          'Wróć do aplikacji, aby uruchomić mikrofon.',
          'Return to the app to start the microphone.',
        );
      });
      return;
    }
    if (!widget.canSend()) {
      if (_editor.text.isNotEmpty && PersonalPrivacy.surfaceUnlocked) {
        setState(() {
          _phase = DictationPhase.review;
          _error = _words(
            'Ta rozmowa jest teraz niedostępna. Tekst pozostaje tutaj do skopiowania.',
            'This conversation is unavailable. Your text stays here to copy.',
          );
        });
      } else {
        await _close();
      }
      return;
    }
    setState(() {
      _phase = DictationPhase.starting;
      _error = null;
    });
    final recorder = _recorderKey.currentState;
    if (recorder == null) return;
    await recorder.startRecording(widget.room);
    if (!mounted || _closing) return;
    if (_appState != AppLifecycleState.resumed && recorder.isRecording) {
      await recorder.pause();
      if (!mounted || _closing) return;
    }
    if (!widget.canSend()) {
      await _close();
      return;
    }
    _started = recorder.isRecording;
    setState(() {
      _phase = _started ? DictationPhase.recording : DictationPhase.error;
      if (!_started) {
        _error = _words(
          'Nie udało się uruchomić mikrofonu. Sprawdź uprawnienia i spróbuj ponownie.',
          'The microphone could not start. Check its permission and try again.',
        );
      }
    });
  }

  Future<void> _transcribe() async {
    if (!mounted || _closing || _phase == DictationPhase.transcribing) return;
    final recorder = _recorderKey.currentState;
    if (recorder == null || !recorder.isRecording) {
      await _start();
      return;
    }
    if (!widget.canSend()) {
      await _close();
      return;
    }
    setState(() {
      _phase = DictationPhase.transcribing;
      _error = null;
    });
    if (!recorder.isPaused) await recorder.pause();
    if (!mounted || _closing) return;
    _duration = recorder.elapsed;
    var attempted = false;
    // This callback only transcribes. Returning false deliberately retains
    // the stopped local recording for a failed-transcription retry.
    await recorder.stopAndSend((path, duration, waveform, fileName) async {
      attempted = true;
      try {
        if (!widget.canSend()) return false;
        final text = (await widget.transcribe(path, duration, fileName)).trim();
        if (!mounted || _closing) return false;
        if (!PersonalPrivacy.surfaceUnlocked) {
          await _close();
          return false;
        }
        if (text.isEmpty) {
          throw const FormatException('Empty transcript');
        }
        _editor.text = text;
        setState(() => _phase = DictationPhase.review);
      } catch (error) {
        if (mounted && !_closing) {
          setState(() {
            _phase = DictationPhase.error;
            _error = error is DictationException
                ? _transcriptionError(error.code)
                : _words(
                    'Nie udało się przygotować tekstu. Nagranie jest zachowane — spróbuj ponownie.',
                    'The transcript could not be prepared. Your recording is kept — try again.',
                  );
          });
        }
      }
      return false;
    });
    if (!mounted || _closing) return;
    if (!widget.canSend()) {
      if (_editor.text.isNotEmpty && PersonalPrivacy.surfaceUnlocked) {
        setState(() {
          _phase = DictationPhase.review;
          _error = _words(
            'Ta rozmowa jest teraz niedostępna. Tekst pozostaje tutaj do skopiowania.',
            'This conversation is unavailable. Your text stays here to copy.',
          );
        });
      } else {
        await _close();
      }
      return;
    }
    if (!attempted && _phase == DictationPhase.transcribing) {
      setState(() {
        _phase = DictationPhase.error;
        _error = _words(
          'Nie udało się odczytać nagrania. Nagraj wiadomość ponownie.',
          'The recording could not be read. Record your message again.',
        );
      });
    }
  }

  Future<void> _resume() async {
    if (_closing || _appState != AppLifecycleState.resumed) return;
    final recorder = _recorderKey.currentState;
    if (recorder == null) return;
    await recorder.resume();
    if (!mounted || _closing) return;
    // A background event while native resume was pending could not pause a
    // busy recorder. Recheck after that operation releases its busy state.
    if (_appState != AppLifecycleState.resumed) await recorder.pause();
  }

  Future<void> _send() async {
    final text = _editor.text.trim();
    if (text.isEmpty || _phase == DictationPhase.sending || _closing) return;
    final validation = widget.validateText?.call(text);
    if (validation != null) {
      setState(() => _error = validation);
      return;
    }
    if (!widget.canSend()) {
      if (!PersonalPrivacy.surfaceUnlocked) {
        await _close();
        return;
      }
      setState(
        () => _error = _words(
          'Ta rozmowa jest teraz niedostępna. Tekst pozostaje tutaj do skopiowania.',
          'This conversation is unavailable. Your text stays here to copy.',
        ),
      );
      return;
    }
    setState(() {
      _phase = DictationPhase.sending;
      _error = null;
    });
    var accepted = false;
    try {
      accepted = await widget.onSend(text);
    } catch (_) {}
    if (!mounted || _closing) return;
    if (accepted) {
      _sent = true;
      _pop();
    } else {
      setState(() {
        _phase = DictationPhase.review;
        _error = _words(
          'Nie udało się wysłać wiadomości. Tekst jest zachowany — spróbuj ponownie.',
          'The message could not be sent. Your text is kept — try again.',
        );
      });
    }
  }

  Future<void> _requestClose() async {
    if (_closing || _confirmationOpen || _phase == DictationPhase.sending) {
      return;
    }
    _confirmationOpen = true;
    final recorder = _recorderKey.currentState;
    if (recorder?.isRecording == true && !recorder!.controlsBusy) {
      await recorder.pause();
    }
    if (!mounted || _closing) {
      _confirmationOpen = false;
      return;
    }
    if (_started || _editor.text.isNotEmpty) {
      final discard = await showNotionConfirmDialog(
        context: context,
        title: _words(
          'Odrzucić dyktowaną wiadomość?',
          'Discard this dictation?',
        ),
        message: _words(
          'Bieżące nagranie i tekst nie zostaną wysłane do rozmówcy.',
          'The current recording and text will not be sent to the recipient.',
        ),
        confirmLabel: _words('Odrzuć', 'Discard'),
        cancelLabel: _words('Zachowaj', 'Keep'),
        destructive: true,
      );
      _confirmationOpen = false;
      if (!mounted || !discard) return;
    }
    _confirmationOpen = false;
    await _close();
  }

  Future<void> _close() async {
    if (_closing) return;
    _closing = true;
    try {
      await widget.onCancel?.call();
    } catch (_) {}
    if (mounted) _pop();
  }

  String _transcriptionError(String code) => switch (code) {
    'paid_request_unknown' => _words(
      'Nie udało się potwierdzić wyniku transkrypcji. ElevenLabs mogło już naliczyć opłatę. Ponowna próba może naliczyć ją drugi raz.',
      'The transcription result could not be confirmed. ElevenLabs may already have charged for it. Retrying may incur another charge.',
    ),
    'dictation_daily_budget' ||
    'dictation_budget_exceeded' ||
    'daily_budget_exceeded' ||
    'daily_budget' => _words(
      'Dzienny budżet transkrypcji został wykorzystany. Nagranie pozostaje tutaj.',
      'The daily transcription budget has been used. Your recording stays here.',
    ),
    'dictation_timeout' => _words(
      'Transkrypcja nie odpowiedziała na czas. Nagranie jest zachowane. Ponowna próba może wiązać się z kolejną opłatą.',
      'Transcription did not respond in time. Your recording is kept. Retrying may incur another charge.',
    ),
    'dictation_not_configured' ||
    'dictation_unavailable' ||
    'transcription_unavailable' => _words(
      'Usługa transkrypcji jest teraz niedostępna. Nagranie jest zachowane.',
      'Transcription is currently unavailable. Your recording is kept.',
    ),
    'dictation_duration_limit' || 'source_too_large' => _words(
      'Nagranie przekracza limit 5 minut lub 10 MB. Nagraj krótszą wiadomość.',
      'The recording exceeds 5 minutes or 10 MB. Record a shorter message.',
    ),
    'empty_transcript' => _words(
      'Nie rozpoznano mowy. Możesz ponowić transkrypcję albo zamknąć dyktowanie.',
      'No speech was recognized. Retry transcription or close dictation.',
    ),
    _ => _words(
      'Nie udało się przygotować tekstu. Nagranie jest zachowane — spróbuj ponownie.',
      'The transcript could not be prepared. Your recording is kept — try again.',
    ),
  };

  void _pop() {
    setState(() => _allowPop = true);
    // Let PopScope observe the new flag before asking the route to pop.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) Navigator.of(context).pop();
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _allowPop,
    onPopInvokedWithResult: (didPop, result) {
      if (!didPop) unawaited(_requestClose());
    },
    child: RecordingViewModel(
      key: _recorderKey,
      builder: (context, recorder) => ListenableBuilder(
        listenable: recorder.samples,
        builder: (context, _) {
          if (_phase == DictationPhase.recording &&
              // Leave one sampling/stop margin before the service's strict
              // five-minute cap; a late native stop still fails closed there.
              recorder.elapsed >=
                  DictationLimits.maxDuration - const Duration(seconds: 1)) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted && _phase == DictationPhase.recording) {
                unawaited(_transcribe());
              }
            });
          }
          return DictationPanel(
            phase: _phase,
            controller: _editor,
            duration: _phase == DictationPhase.recording
                ? recorder.duration
                : _duration,
            paused: recorder.isPaused,
            error: _error,
            onClose: _requestClose,
            onPrimary: switch (_phase) {
              DictationPhase.recording => _transcribe,
              DictationPhase.error => _transcribe,
              _ => _send,
            },
            onResume: recorder.canResume ? _resume : null,
          );
        },
      ),
    ),
  );
}

/// Shared presentation for the live recorder and the editable text review.
/// Also rendered by phone-sized widget captures using fictional content.
class DictationPanel extends StatelessWidget {
  const DictationPanel({
    super.key,
    required this.phase,
    required this.controller,
    required this.onClose,
    required this.onPrimary,
    this.duration = Duration.zero,
    this.paused = false,
    this.error,
    this.onResume,
  });

  final DictationPhase phase;
  final TextEditingController controller;
  final VoidCallback onClose;
  final VoidCallback onPrimary;
  final Duration duration;
  final bool paused;
  final String? error;
  final VoidCallback? onResume;

  @override
  Widget build(BuildContext context) {
    final tokens = context.notion;
    final pl = Localizations.localeOf(context).languageCode == 'pl';
    String words(String polish, String english) => pl ? polish : english;
    final reviewing =
        phase == DictationPhase.review || phase == DictationPhase.sending;
    final busy =
        phase == DictationPhase.starting ||
        phase == DictationPhase.transcribing ||
        phase == DictationPhase.sending;
    final media = MediaQuery.of(context);
    final available = math.max(
      0.0,
      media.size.height -
          media.viewInsets.bottom -
          media.padding.vertical -
          NotionSpace.xl * 2,
    );
    final height = math.min(media.size.height * .82, available);
    return NotionDialogFrame(
      padding: const EdgeInsets.all(NotionSpace.md),
      maxWidth: NotionSize.sheetDialogMaxWidth,
      child: SizedBox(
        height: height,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final compact =
                constraints.maxHeight < NotionSize.contentMaxWidth / 2;
            final content = Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Semantics(
                        header: true,
                        child: Text(
                          reviewing
                              ? words(
                                  'Sprawdź wiadomość',
                                  'Review your message',
                                )
                              : words('Dyktuj wiadomość', 'Dictate a message'),
                          style: tokens.typography.heading,
                        ),
                      ),
                    ),
                    NotionIconButton(
                      icon: Icons.close,
                      label: words('Zamknij dyktowanie', 'Close dictation'),
                      onPressed: phase == DictationPhase.sending
                          ? null
                          : onClose,
                    ),
                  ],
                ),
                if (!compact) ...[
                  Text(
                    reviewing
                        ? words(
                            'Popraw tekst albo od razu go wyślij.',
                            'Make any edits, then send when ready.',
                          )
                        : words(
                            'Mów naturalnie. Przygotujemy tekst do sprawdzenia.',
                            'Speak naturally. We’ll prepare the text for review.',
                          ),
                    style: tokens.typography.calloutMuted,
                  ),
                  const SizedBox(height: NotionSpace.lg),
                ],
                Expanded(
                  child: reviewing
                      ? NotionTextField(
                          key: const Key('dictation-editor'),
                          controller: controller,
                          hint: words('Treść wiadomości', 'Message text'),
                          expands: true,
                          readOnly: phase == DictationPhase.sending,
                          keyboardType: TextInputType.multiline,
                          textInputAction: TextInputAction.newline,
                        )
                      : Center(
                          child: SingleChildScrollView(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  phase == DictationPhase.error
                                      ? Icons.error_outline
                                      : Icons.mic_none_outlined,
                                  size: NotionSize.avatarLg,
                                  color: phase == DictationPhase.error
                                      ? tokens.colors.danger
                                      : tokens.colors.accent,
                                ),
                                const SizedBox(height: NotionSpace.lg),
                                if (phase == DictationPhase.recording)
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      RecordingDot(active: !paused),
                                      const SizedBox(width: NotionSpace.xs),
                                      Text(
                                        notionAudioTime(duration),
                                        style: tokens.typography.title,
                                      ),
                                    ],
                                  ),
                                const SizedBox(height: NotionSpace.sm),
                                Semantics(
                                  liveRegion: true,
                                  child: Text(
                                    switch (phase) {
                                      DictationPhase.transcribing => words(
                                        'ElevenLabs Scribe v2 przygotowuje tekst…',
                                        'ElevenLabs Scribe v2 is preparing the text…',
                                      ),
                                      DictationPhase.starting => words(
                                        'Uruchamianie mikrofonu…',
                                        'Starting microphone…',
                                      ),
                                      DictationPhase.error => words(
                                        'Spróbuj ponownie',
                                        'Try again',
                                      ),
                                      _ =>
                                        paused
                                            ? words(
                                                'Nagranie wstrzymane',
                                                'Recording paused',
                                              )
                                            : words(
                                                'Nagrywanie · maks. 5 min',
                                                'Recording · up to 5 min',
                                              ),
                                    },
                                    textAlign: TextAlign.center,
                                    style: tokens.typography.calloutMuted,
                                  ),
                                ),
                                if (paused &&
                                    onResume != null &&
                                    phase == DictationPhase.recording)
                                  NotionButton.ghost(
                                    label: words(
                                      'Wznów nagrywanie',
                                      'Resume recording',
                                    ),
                                    icon: Icons.mic_none_outlined,
                                    onPressed: onResume,
                                  ),
                              ],
                            ),
                          ),
                        ),
                ),
                if (error != null) ...[
                  const SizedBox(height: NotionSpace.sm),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      error!,
                      style: tokens.typography.callout.copyWith(
                        color: tokens.colors.danger,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: NotionSpace.md),
                if (!compact) ...[
                  Text(
                    reviewing
                        ? words(
                            'Do rozmowy trafi tylko tekst.',
                            'Only the text will be sent to the conversation.',
                          )
                        : words(
                            'Nagranie trafia do ElevenLabs w celu transkrypcji. Do rozmowy wyślesz tylko tekst.',
                            'Audio is sent to ElevenLabs for transcription. Only text is sent to the conversation.',
                          ),
                    style: tokens.typography.footnoteMuted,
                  ),
                  const SizedBox(height: NotionSpace.md),
                ],
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) => NotionButton.primary(
                    key: const Key('dictation-primary'),
                    label: reviewing
                        ? words('Wyślij wiadomość', 'Send message')
                        : phase == DictationPhase.error
                        ? words('Spróbuj ponownie', 'Try again')
                        : words(
                            'Zatrzymaj i zamień na tekst',
                            'Stop and transcribe',
                          ),
                    icon: reviewing ? Icons.arrow_upward : Icons.stop_rounded,
                    expand: true,
                    busy: busy,
                    onPressed: busy || (reviewing && value.text.trim().isEmpty)
                        ? null
                        : onPrimary,
                  ),
                ),
              ],
            );
            // Extremely short multi-window layouts still allow every control
            // to be reached. Normal phone layouts keep the action pinned.
            final accessibleScale =
                media.textScaler.scale(NotionSize.headerHeight) /
                NotionSize.headerHeight;
            final minimumHeight =
                NotionSize.headerHeight *
                (error == null ? 3 : 6) *
                accessibleScale;
            if (constraints.maxHeight < minimumHeight) {
              return SingleChildScrollView(
                child: SizedBox(
                  height:
                      NotionSize.headerHeight *
                      (error == null ? 5 : 8) *
                      accessibleScale,
                  child: content,
                ),
              );
            }
            return content;
          },
        ),
      ),
    );
  }
}
