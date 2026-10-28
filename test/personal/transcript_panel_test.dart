// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline widget tests for the transcription split button and panel.
import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/transcript_panel.dart';
import 'package:chatloom/personal/ui/notion_transcribe_button.dart';
import 'package:chatloom/personal/worker_readiness.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import '../notion/conversation_test_support.dart';

class _FakePersonal extends PersonalClient {
  _FakePersonal(super.client)
    : super.forTesting(openStore: () => throw StateError('No fixture store'));

  final jobs = <String, TranscriptionJob>{};
  final requests = <String?>[];
  final cancels = <String>[];
  final pendingCancels = <String>{};
  bool autoPending = false;
  String? defaultLanguage;
  bool fakeReady = true;
  Object? transcribeError;
  Completer<void>? transcribeGate;
  int loads = 0;
  int localLoads = 0;

  @override
  bool get ready => fakeReady;
  @override
  Future<void> load() async => loads++;
  @override
  Future<void> loadLocal() async => localLoads++;
  @override
  Map<String, TranscriptionJob> get transcripts => jobs;
  @override
  String transcriptId(Event e) => 'transcript:${e.eventId}';
  @override
  bool autoTranscriptPending(Event e) => autoPending;
  @override
  String? get transcriptionDefaultLanguage => defaultLanguage;
  @override
  bool isTranscriptCancellationPending(String id) =>
      pendingCancels.contains(id);
  @override
  Future<void> transcribe(Event e, {String? language}) async {
    requests.add(language);
    if (transcribeGate case final gate?) await gate.future;
    if (transcribeError case final error?) throw error;
    setJob(e, JobState.waitingSync, language: language);
  }

  @override
  Future<TranscriptCancellation> cancelTranscript(String id) async {
    cancels.add(id);
    pendingCancels.add(id);
    notifyListeners();
    return TranscriptCancellation.waitingAcknowledgement;
  }

  void poke() => notifyListeners();

  void setJob(
    Event e,
    JobState state, {
    String? language,
    String? text,
    String? errorCode,
    double? cost,
    TranscriptionOrigin origin = TranscriptionOrigin.manual,
  }) {
    final id = transcriptId(e);
    jobs[id] = TranscriptionJob(
      id: id,
      source: SourceEventRef(
        conversation: ConversationRef(
          accountId: e.room.client.userID!,
          roomId: e.room.id,
        ),
        eventId: e.eventId,
      ),
      state: state,
      language: language,
      text: text,
      errorCode: errorCode,
      estimatedCostUsd: cost,
      origin: origin,
    );
    notifyListeners();
  }
}

/// No step-by-step status words while a transcript is on its way.
const _statusWords = [
  'Waiting for sync',
  'Waiting for keys',
  'Queued',
  'Starting…',
  'Transcribing…',
  'Cancelling…',
];

void expectPlaceholderOnly(WidgetTester tester) {
  expect(find.byType(NotionShimmerLines), findsOneWidget);
  expect(find.byType(CircularProgressIndicator), findsNothing);
  for (final word in _statusWords) {
    expect(find.text(word), findsNothing, reason: word);
  }
}

/// The placeholder animates forever, so settle for a bounded time instead.
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  late ConversationClient client;
  late ConversationRoom room;
  late Event voice;
  late _FakePersonal personal;

  setUp(() {
    client = ConversationClient();
    room = ConversationRoom(client, '!voice:example.invalid');
    voice = room.message(
      r'$voice',
      'voice.ogg',
      content: {
        'msgtype': MessageTypes.Audio,
        'body': 'voice.ogg',
        'url': 'mxc://example.invalid/voice',
      },
    );
    personal = _FakePersonal(client);
  });

  Future<void> pump(
    WidgetTester tester, {
    Color? foreground,
    List<Event>? events,
    double? width,
    double textScale = 1,
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
          child: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: width,
              child: ListView(
                children: [
                  for (final event in events ?? [voice])
                    TranscriptPanel(
                      event: event,
                      foregroundColor: foreground,
                      personalClient: personal,
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    ),
  );

  testWidgets('double tap transcript reacts without selecting text', (
    tester,
  ) async {
    personal.setJob(voice, JobState.done, text: 'Do zobaczenia');
    var likes = 0;
    String? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SelectionArea(
            onSelectionChanged: (value) => selected = value?.plainText,
            child: Center(
              child: SizedBox(
                width: 320,
                child: ConversationMessageGestures(
                  identity: voice.eventId,
                  onLike: () async {
                    likes++;
                    return true;
                  },
                  child: TranscriptPanel(
                    event: voice,
                    personalClient: personal,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Do zobaczenia'));
    await tester.pump(const Duration(milliseconds: 80));
    await tester.tap(find.text('Do zobaczenia'));
    await tester.pumpAndSettle();
    expect(likes, 1);
    expect(selected, isNull);
    expect(find.byType(SelectableText), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('idle shows the split button and requests one job', (
    tester,
  ) async {
    await pump(tester);
    expect(find.text('Transcribe'), findsOneWidget);
    expect(find.text('Auto'), findsOneWidget);
    expect(
      find.bySemanticsLabel('Transcription language: Automatic'),
      findsOneWidget,
    );
    await tester.tap(find.text('Transcribe'));
    await settle(tester);
    expect(personal.requests, [null]);
    // Busy: shimmering lines where the text will appear; a request made by
    // hand keeps a small cancel button, the split button is gone.
    expectPlaceholderOnly(tester);
    expect(find.byKey(const ValueKey('transcribe-cancel')), findsOneWidget);
    expect(find.byKey(const ValueKey('transcribe-primary')), findsNothing);
    expect(find.text('Auto'), findsNothing);
    expect(find.bySemanticsLabel('Transcribing'), findsOneWidget);
  });

  testWidgets('language menu offers Armenian and keeps the choice', (
    tester,
  ) async {
    await pump(tester);
    await tester.tap(find.byKey(const ValueKey('transcribe-language')));
    await settle(tester);
    for (final name in ['Automatic', 'Polish', 'English', 'Armenian']) {
      expect(find.text(name), findsOneWidget);
    }
    expect(find.text('Հայերեն'), findsOneWidget);
    expect(find.text('Polski'), findsOneWidget);
    await tester.tap(find.text('Armenian'));
    await settle(tester);
    expect(find.text('HY'), findsOneWidget);
    await tester.tap(find.text('Transcribe'));
    await settle(tester);
    expect(personal.requests, ['hy']);
  });

  testWidgets('default language comes from the synced policy', (tester) async {
    personal.defaultLanguage = 'pl';
    await pump(tester);
    expect(find.text('PL'), findsOneWidget);
    await tester.tap(find.text('Transcribe'));
    await settle(tester);
    expect(personal.requests, ['pl']);
  });

  testWidgets('every busy step is the same quiet placeholder', (tester) async {
    for (final origin in TranscriptionOrigin.values) {
      for (final state in [
        JobState.waitingSync,
        JobState.queued,
        JobState.processing,
      ]) {
        personal.setJob(voice, state, origin: origin);
        await pump(tester);
        await settle(tester);
        expectPlaceholderOnly(tester);
        expect(
          find.byKey(const ValueKey('transcribe-cancel')),
          origin == TranscriptionOrigin.manual ? findsOneWidget : findsNothing,
          reason: 'Automatic work has no controls',
        );
      }
    }
  });

  testWidgets('a pending request shows the placeholder at once', (
    tester,
  ) async {
    final gate = personal.transcribeGate = Completer<void>();
    await pump(tester);
    await tester.tap(find.text('Transcribe'));
    await settle(tester);
    expectPlaceholderOnly(tester);
    final placeholder = tester.state(find.byType(NotionShimmerLines));
    gate.complete();
    await settle(tester);
    expectPlaceholderOnly(tester);
    expect(
      tester.state(find.byType(NotionShimmerLines)),
      same(placeholder),
      reason: 'The placeholder does not restart when the job appears',
    );
  });

  testWidgets('a job stuck on missing keys says so under the placeholder', (
    tester,
  ) async {
    personal.setJob(
      voice,
      JobState.waitingKeys,
      errorCode: 'waiting_keys',
      origin: TranscriptionOrigin.auto,
    );
    await pump(tester);
    await settle(tester);
    expect(find.byType(NotionShimmerLines), findsOneWidget);
    expect(find.text('Waiting for this message to decrypt'), findsOneWidget);
    expect(find.textContaining('keys'), findsNothing);
  });

  testWidgets('automatic work switched off leaves the plain button', (
    tester,
  ) async {
    personal.setJob(
      voice,
      JobState.failed,
      errorCode: 'auto_disabled',
      origin: TranscriptionOrigin.auto,
    );
    await pump(tester);
    expect(find.text('Transcribe'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
  });

  testWidgets('a failed start blames private sync only when disconnected', (
    tester,
  ) async {
    personal.transcribeError = Exception('offline');
    await pump(tester);
    await tester.tap(find.text('Transcribe'));
    await settle(tester);
    expect(
      find.text('Couldn’t start transcription. Try again.'),
      findsOneWidget,
    );
    expect(find.textContaining('Connect private sync'), findsNothing);

    ScaffoldMessenger.of(
      tester.element(find.byType(TranscriptPanel)),
    ).removeCurrentSnackBar();
    await settle(tester);
    personal
      ..fakeReady = false
      ..transcribeError = StateError('Private journal is not configured');
    await tester.tap(find.text('Transcribe'));
    await settle(tester);
    expect(find.textContaining('Connect private sync'), findsOneWidget);
  });

  testWidgets('a done job without text says no speech was detected', (
    tester,
  ) async {
    personal.setJob(voice, JobState.done, language: 'en', text: '');
    await pump(tester);
    expect(find.text('No speech detected'), findsOneWidget);
    expect(find.text('Transcribe again'), findsOneWidget);
  });

  test('error codes map to short reasons', () {
    expect(
      transcriptionErrorText('protected_media'),
      'This media can’t be transcribed',
    );
    for (final code in [
      'media_conversion_failed',
      'invalid_audio_duration',
      'empty_audio',
    ]) {
      expect(transcriptionErrorText(code), 'Couldn’t read the audio');
    }
    expect(transcriptionErrorText('empty_transcript'), 'No speech detected');
    expect(
      transcriptionErrorText('audio_chunk_too_large'),
      'Too large to transcribe',
    );
    expect(
      transcriptionErrorText('source_too_large'),
      'Too large to transcribe',
    );
    expect(
      transcriptionErrorText('local_source_unavailable'),
      'Couldn’t load the audio',
    );
    expect(
      transcriptionErrorText('source_status_unknown'),
      'Couldn’t load the audio',
    );
    expect(
      transcriptionErrorText('openai_rate_limited'),
      'Transcription service unavailable',
    );
    expect(
      transcriptionErrorText('auto_skipped_budget'),
      'Daily limit for automatic transcripts reached',
    );
    expect(
      transcriptionErrorText('auto_skipped_duration'),
      'Too long to transcribe automatically',
    );
    expect(
      transcriptionErrorText('auto_skipped_size_cap'),
      'Too large to transcribe automatically',
    );
    expect(transcriptionErrorText(null), 'Couldn’t transcribe this message');
    expect(
      transcriptionErrorText('whatever'),
      'Couldn’t transcribe this message',
    );
    // Human words only: no error code ever reaches the bubble.
    for (final code in [
      'protected_media',
      'openai_partial_failure',
      'auto_skipped_unknown_size',
      'room_unavailable',
      'transcription_failed',
    ]) {
      expect(transcriptionErrorText(code), isNot(contains('_')));
    }
  });

  testWidgets('failed job shows the mapped reason and Retry', (tester) async {
    personal.setJob(voice, JobState.failed, errorCode: 'protected_media');
    await pump(tester);
    expect(find.text('This media can’t be transcribed'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    await settle(tester);
    expect(personal.requests, [null]);
    expectPlaceholderOnly(tester);
  });

  testWidgets('skipped automatic job explains the limit', (tester) async {
    personal.setJob(
      voice,
      JobState.cancelled,
      errorCode: 'auto_skipped_duration',
      origin: TranscriptionOrigin.auto,
    );
    await pump(tester);
    expect(find.text('Too long to transcribe automatically'), findsOneWidget);
    // Not a failure: asking by hand transcribes it.
    expect(find.text('Retry'), findsNothing);
    await tester.tap(find.text('Transcribe'));
    await settle(tester);
    expect(personal.requests, [null]);
  });

  testWidgets('unknown result warns about cost', (tester) async {
    personal.setJob(voice, JobState.unknown);
    await pump(tester);
    expect(
      find.text('The result is unknown. Retrying may cost again.'),
      findsOneWidget,
    );
  });

  // A burst of voice notes (2026-10-26): the worker retries transient
  // failures itself and publishes the job as queued with the failure code
  // meanwhile; only retries used up end in an error.
  group('failures the worker retries by itself', () {
    test('only those count as retrying', () {
      TranscriptionJob job(JobState state, String? code) => TranscriptionJob(
        id: 'transcript:x',
        source: const SourceEventRef(
          conversation: ConversationRef(
            accountId: '@a:example.invalid',
            roomId: '!r:example.invalid',
          ),
          eventId: r'$x',
        ),
        state: state,
        errorCode: code,
      );
      for (final code in [
        'source_unavailable',
        'local_source_unavailable',
        'local_source_busy',
        'openai_rate_limited',
        'transcription_failed',
      ]) {
        expect(transcriptionRetrying(job(JobState.queued, code)), isTrue);
        // Retries used up: a real error.
        expect(transcriptionRetrying(job(JobState.failed, code)), isFalse);
      }
      expect(
        transcriptionRetrying(
          job(JobState.waitingSync, 'source_status_unknown'),
        ),
        isTrue,
      );
      expect(transcriptionRetrying(job(JobState.queued, null)), isFalse);
      // A refusal of a duplicate request says nothing about retries.
      expect(transcriptionRetrying(job(JobState.queued, 'conflict')), isFalse);
      expect(
        transcriptionRetrying(job(JobState.waitingKeys, 'waiting_keys')),
        isFalse,
      );
      expect(
        transcriptionErrorText('local_source_busy'),
        'Couldn’t load the audio',
      );
    });

    testWidgets('they stay one placeholder, never an error, until the '
        'transcript appears in place', (tester) async {
      personal.setJob(voice, JobState.queued, origin: TranscriptionOrigin.auto);
      await pump(tester);
      await settle(tester);
      final placeholder = tester.state(find.byType(NotionShimmerLines));
      for (final (state, code) in [
        (JobState.processing, null),
        (JobState.queued, 'source_unavailable'),
        (JobState.queued, 'local_source_unavailable'),
        (JobState.waitingSync, 'source_status_unknown'),
        (JobState.queued, 'transcription_failed'),
      ]) {
        personal.setJob(
          voice,
          state,
          errorCode: code,
          origin: TranscriptionOrigin.auto,
        );
        await settle(tester);
        expectPlaceholderOnly(tester);
        expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
        expect(find.text('Retry'), findsNothing);
        expect(
          tester.state(find.byType(NotionShimmerLines)),
          same(placeholder),
          reason: 'no restart or flicker at $state $code',
        );
      }
      personal.setJob(
        voice,
        JobState.done,
        language: 'en',
        text: 'Back in a minute',
        origin: TranscriptionOrigin.auto,
      );
      await settle(tester);
      expect(find.text('Back in a minute'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
    });

    testWidgets('a long back-off says it will try again, calmly', (
      tester,
    ) async {
      personal.setJob(
        voice,
        JobState.queued,
        errorCode: 'openai_rate_limited',
        origin: TranscriptionOrigin.auto,
      );
      await pump(tester);
      await settle(tester);
      expect(
        find.text(TranscriptBusyLines.retryWaitText),
        findsNothing,
        reason: 'a quick retry is silent',
      );
      final steps = (NotionMotion.loopCap.inMilliseconds / 500).ceil() + 4;
      for (var i = 0; i < steps; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text(TranscriptBusyLines.retryWaitText), findsOneWidget);
      expect(find.text(TranscriptBusyLines.longWaitText), findsNothing);
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
    });

    testWidgets('retries used up: one short reason and Retry, which goes '
        'straight back to the placeholder', (tester) async {
      personal.setJob(
        voice,
        JobState.failed,
        errorCode: 'transcription_failed',
        origin: TranscriptionOrigin.auto,
      );
      await pump(tester);
      await settle(tester);
      expect(find.text('Couldn’t transcribe this message'), findsOneWidget);
      expect(find.byIcon(Icons.error_outline_rounded), findsOneWidget);
      expect(find.text('Retry'), findsOneWidget);
      await tester.tap(find.text('Retry'));
      await settle(tester);
      expect(personal.requests, [null]);
      expectPlaceholderOnly(tester);
      expect(find.byIcon(Icons.error_outline_rounded), findsNothing);
      // The worker accepts and starts the request: still the same line.
      final placeholder = tester.state(find.byType(NotionShimmerLines));
      for (final state in [JobState.queued, JobState.processing]) {
        personal.setJob(voice, state);
        await settle(tester);
        expectPlaceholderOnly(tester);
        expect(
          tester.state(find.byType(NotionShimmerLines)),
          same(placeholder),
        );
      }
    });
  });

  testWidgets('a message arriving in an open chat shows the placeholder, '
      'then its transcript in place', (tester) async {
    // The bubble is built before the client knows anything automatic.
    await pump(tester);
    expect(find.text('Transcribe'), findsOneWidget);
    // Private sync comes up: an automatic transcript is expected.
    personal.autoPending = true;
    personal.poke();
    await settle(tester);
    expectPlaceholderOnly(tester);
    expect(find.byKey(const ValueKey('transcribe-cancel')), findsNothing);
    final placeholder = tester.state(find.byType(NotionShimmerLines));
    // The worker's job arrives through the journal: same placeholder.
    personal.autoPending = false;
    for (final state in [JobState.queued, JobState.processing]) {
      personal.setJob(
        voice,
        state,
        language: 'en',
        origin: TranscriptionOrigin.auto,
      );
      await settle(tester);
      expectPlaceholderOnly(tester);
      expect(tester.state(find.byType(NotionShimmerLines)), same(placeholder));
    }
    personal.setJob(
      voice,
      JobState.done,
      language: 'en',
      text: 'See you at five',
      origin: TranscriptionOrigin.auto,
    );
    await settle(tester);
    expect(find.text('See you at five'), findsOneWidget);
    expect(find.text('Transcript · EN'), findsOneWidget);
    expect(find.byType(NotionShimmerLines), findsNothing);
  });

  testWidgets('cancel requests cancellation and disables itself', (
    tester,
  ) async {
    personal.setJob(voice, JobState.queued);
    await pump(tester);
    expectPlaceholderOnly(tester);
    await tester.tap(find.byKey(const ValueKey('transcribe-cancel')));
    await settle(tester);
    expect(personal.cancels, ['transcript:\$voice']);
    expect(
      tester
          .widget<IconButton>(find.byKey(const ValueKey('transcribe-cancel')))
          .onPressed,
      isNull,
    );
    expectPlaceholderOnly(tester);
  });

  testWidgets('done shows readable transcript with menu actions', (
    tester,
  ) async {
    final copied = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    personal.setJob(
      voice,
      JobState.done,
      language: 'pl',
      text: 'Do zobaczenia',
      cost: .0012,
    );
    await pump(tester, foreground: Colors.white);
    expect(find.text('Transcribe'), findsNothing);
    expect(find.text('Transcript · PL'), findsOneWidget);
    expect(find.text('Estimated cost: \$0.0012'), findsNothing);
    final transcript = tester.widget<Text>(find.text('Do zobaczenia'));
    expect(transcript.style?.color, Colors.white);
    // The caption row starts at the transcript text's inset.
    expect(
      tester.getTopLeft(find.text('Transcript · PL')).dx,
      tester.getTopLeft(find.text('Do zobaczenia')).dx,
    );

    await tester.tap(find.byKey(const ValueKey('transcript-menu')));
    await settle(tester);
    expect(find.text('Transcribe again'), findsOneWidget);
    await tester.tap(find.text('Copy'));
    await settle(tester);
    expect(copied, ['Do zobaczenia']);

    await tester.tap(find.byKey(const ValueKey('transcript-menu')));
    await settle(tester);
    await tester.tap(find.text('Transcribe again'));
    await settle(tester);
    expect(find.text('Armenian'), findsOneWidget);
    await tester.tap(find.text('Armenian'));
    await settle(tester);
    expect(personal.requests, ['hy']);
  });

  testWidgets('five transcript lines stay fully visible without a toggle', (
    tester,
  ) async {
    final text = List.generate(5, (i) => 'Line ${i + 1}').join('\n');
    personal.setJob(voice, JobState.done, text: text);
    await pump(tester, width: 320);
    final transcript = tester.widget<Text>(
      find.byKey(const ValueKey('transcript-text')),
    );
    expect(transcript.maxLines, isNull);
    expect(find.byKey(const ValueKey('transcript-expand')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('six transcript lines preview three and expand and collapse', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    final text = List.generate(6, (i) => 'Line ${i + 1}').join('\n');
    personal.setJob(voice, JobState.done, text: text);
    await pump(tester, width: 320);
    final textFinder = find.byKey(const ValueKey('transcript-text'));
    expect(tester.widget<Text>(textFinder).maxLines, 3);
    expect(tester.widget<Text>(textFinder).overflow, TextOverflow.ellipsis);
    final collapsedHeight = tester.getSize(textFinder).height;
    expect(find.bySemanticsLabel('Show more'), findsOneWidget);
    final button = find.byKey(const ValueKey('transcript-expand'));
    expect(tester.getSize(button).height, greaterThanOrEqualTo(48));
    await tester.tap(button);
    await settle(tester);
    expect(tester.widget<Text>(textFinder).maxLines, isNull);
    expect(tester.getSize(textFinder).height, greaterThan(collapsedHeight));
    expect(find.bySemanticsLabel('Show less'), findsOneWidget);
    await tester.tap(button);
    await settle(tester);
    expect(tester.widget<Text>(textFinder).maxLines, 3);
    expect(tester.getSize(textFinder).height, collapsedHeight);
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('wrapped lines follow width and accessibility text scale', (
    tester,
  ) async {
    const text =
        'One two three four five six seven eight nine ten. '
        'One two three four five six seven eight nine ten.';
    personal.setJob(voice, JobState.done, text: text);
    await pump(tester, width: 640);
    expect(find.byKey(const ValueKey('transcript-expand')), findsNothing);
    await pump(tester, width: 240, textScale: 2);
    await settle(tester);
    expect(find.text('Show more'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('transcript-text')))
          .maxLines,
      3,
    );
    await tester.tap(find.text('Show more'));
    await settle(tester);
    expect(find.text('Show less'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('copy keeps the full collapsed transcript', (tester) async {
    final text = List.generate(8, (i) => 'Line ${i + 1}').join('\n');
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          copied = (call.arguments as Map)['text'] as String;
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );
    personal.setJob(voice, JobState.done, text: text);
    await pump(tester, width: 320);
    await tester.tap(find.byKey(const ValueKey('transcript-menu')));
    await settle(tester);
    await tester.tap(find.text('Copy'));
    await settle(tester);
    expect(copied, text);
  });

  testWidgets('capture synthetic collapsed and expanded transcripts', (
    tester,
  ) async {
    final output = Platform.environment['NOTION_CAPTURE_DIR'];
    if (output == null) return;
    await tester.runAsync(() async {
      await (FontLoader(
            'Roboto',
          )..addFont(rootBundle.load('assets/notion/fonts/Roboto-Regular.ttf')))
          .load();
      await (FontLoader(
        'MaterialIcons',
      )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    });
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final key = GlobalKey();
    personal.setJob(
      voice,
      JobState.done,
      language: 'pl',
      text:
          'To jest przykładowa transkrypcja wiadomości głosowej. '
          'Spotkajmy się jutro po południu w kawiarni. '
          'Przyniosę szkice projektu i omówimy wszystkie szczegóły. '
          'Daj znać, która godzina będzie dla ciebie wygodna. '
          'Jeśli pogoda dopisze, możemy też wybrać się na krótki spacer.',
    );
    await tester.pumpWidget(
      MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: Center(
            child: RepaintBoundary(
              key: key,
              child: Container(
                width: 320,
                padding: const EdgeInsets.all(NotionSpace.md),
                color: NotionTheme.build(Brightness.dark).colorScheme.surface,
                child: TranscriptPanel(event: voice, personalClient: personal),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final state in ['collapsed', 'expanded']) {
      final boundary =
          key.currentContext!.findRenderObject() as RenderRepaintBoundary;
      await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 2);
        final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
        final file = File('$output/transcript-$state.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes!.buffer.asUint8List());
        image.dispose();
      });
      if (state == 'collapsed') {
        await tester.tap(find.text('Show more'));
        await tester.pumpAndSettle();
      }
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('a replacement transcript starts collapsed again', (
    tester,
  ) async {
    final text = List.generate(6, (i) => 'Line ${i + 1}').join('\n');
    personal.setJob(voice, JobState.done, text: text);
    await pump(tester, width: 320);
    await tester.tap(find.text('Show more'));
    await settle(tester);
    personal.setJob(voice, JobState.done, text: '$text\nAnother line');
    await settle(tester);
    expect(find.text('Show more'), findsOneWidget);
    expect(
      tester
          .widget<Text>(find.byKey(const ValueKey('transcript-text')))
          .maxLines,
      3,
    );
  });

  testWidgets('panels never reload the client and ignore unrelated changes', (
    tester,
  ) async {
    final other = room.message(
      r'$voice2',
      'voice2.ogg',
      content: {
        'msgtype': MessageTypes.Audio,
        'body': 'voice2.ogg',
        'url': 'mxc://example.invalid/voice2',
      },
    );
    await pump(tester, events: [voice, other, voice]);
    await settle(tester);
    expect(personal.loads, 0);
    expect(personal.localLoads, 0);

    // Unrelated notification: no panel schedules a rebuild.
    personal.notifyListeners();
    expect(tester.binding.hasScheduledFrame, isFalse);

    // Only this event's job change rebuilds.
    personal.setJob(other, JobState.queued);
    expect(tester.binding.hasScheduledFrame, isTrue);
    await settle(tester);
    expect(find.byType(NotionShimmerLines), findsOneWidget);
    expect(find.text('Transcribe'), findsNWidgets(2));
  });

  testWidgets('a not-yet-ready client is hydrated locally only', (
    tester,
  ) async {
    personal.fakeReady = false;
    await pump(tester);
    expect(personal.loads, 0);
    expect(personal.localLoads, 1);
  });

  testWidgets('split button contrasts on an outgoing bubble colour', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ColoredBox(
            color: Colors.blue.shade800,
            child: NotionTranscribeSplitButton(
              foregroundColor: Colors.white,
              onTranscribe: () {},
              onLanguageSelected: (_) {},
            ),
          ),
        ),
      ),
    );
    final size = tester.getSize(
      find.byKey(const ValueKey('transcribe-primary')),
    );
    expect(size.height, greaterThanOrEqualTo(48));
    final label = tester.widget<RichText>(
      find
          .descendant(
            of: find.byKey(const ValueKey('transcribe-primary')),
            matching: find.byType(RichText),
          )
          .last,
    );
    expect(label.text.style?.color, Colors.white);
  });

  testWidgets('split button pill grows with large text', (tester) async {
    Future<double> pillHeight(double scale) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(scale)),
            child: Scaffold(
              body: Center(
                child: NotionTranscribeSplitButton(
                  onTranscribe: () {},
                  onLanguageSelected: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      return tester
          .getSize(find.byKey(const ValueKey('transcribe-pill')))
          .height;
    }

    expect(await pillHeight(1), 36);
    expect(await pillHeight(2), 56);
    expect(
      tester.getSize(find.byKey(const ValueKey('transcribe-primary'))).height,
      greaterThanOrEqualTo(56),
    );
  });

  group('videos and automatic work', () {
    late Event clip;
    setUp(() {
      clip = room.message(
        r'$clip',
        'clip.mp4',
        content: {
          'msgtype': MessageTypes.Video,
          'body': 'clip.mp4',
          'url': 'mxc://example.invalid/clip',
          'info': {'mimetype': 'video/mp4', 'duration': 30000},
        },
      );
    });

    testWidgets('a video is offered only by a media-capable worker', (
      tester,
    ) async {
      expect(TranscriptPanel.mayTranscribe(clip), isTrue);
      await pump(tester, events: [clip]);
      expect(find.text('Transcribe'), findsNothing);
      personal.workerReadiness = WorkerReadiness(
        receivedAt: DateTime.now(),
        transcriptionMedia: 2,
      );
      personal.poke();
      await settle(tester);
      expect(find.text('Transcribe'), findsOneWidget);
    });

    testWidgets('GIF-style loops and images never get a transcript slot', (
      tester,
    ) async {
      final gif = room.message(
        r'$gif',
        'loop.mp4',
        content: {
          'msgtype': MessageTypes.Video,
          'body': 'loop.mp4',
          'info': {'mimetype': 'video/mp4', 'fi.mau.gif': true},
        },
      );
      expect(TranscriptPanel.mayTranscribe(gif), isFalse);
      final photo = room.message(
        r'$photo',
        'photo.jpg',
        content: {'msgtype': MessageTypes.Image, 'body': 'photo.jpg'},
      );
      expect(TranscriptPanel.mayTranscribe(photo), isFalse);
    });

    testWidgets('automatic work shows one quiet line, then the transcript', (
      tester,
    ) async {
      personal.setJob(clip, JobState.queued, origin: TranscriptionOrigin.auto);
      await pump(tester, events: [clip]);
      expect(find.byKey(const ValueKey('transcript-busy')), findsOneWidget);
      expectPlaceholderOnly(tester);
      expect(find.byKey(const ValueKey('transcribe-cancel')), findsNothing);
      expect(find.text('Transcribe'), findsNothing);
      personal.setJob(
        clip,
        JobState.done,
        text: 'Hello from the video',
        origin: TranscriptionOrigin.auto,
      );
      await settle(tester);
      expect(find.text('Hello from the video'), findsOneWidget);
      expect(find.byKey(const ValueKey('transcript-busy')), findsNothing);
    });

    testWidgets('a silent clip found automatically renders nothing', (
      tester,
    ) async {
      personal.setJob(
        clip,
        JobState.cancelled,
        errorCode: 'no_audio_track',
        origin: TranscriptionOrigin.auto,
      );
      await pump(tester, events: [clip]);
      expect(find.byType(NotionTranscribeSplitButton), findsNothing);
      expect(find.textContaining('audio'), findsNothing);
    });

    testWidgets('a manual request on a silent clip explains why', (
      tester,
    ) async {
      personal.setJob(clip, JobState.failed, errorCode: 'no_audio_track');
      await pump(tester, events: [clip]);
      expect(find.text('This video has no sound'), findsOneWidget);
    });

    testWidgets('a kind switched off leaves the manual button', (tester) async {
      personal.setJob(
        voice,
        JobState.cancelled,
        errorCode: 'auto_skipped_kind',
        origin: TranscriptionOrigin.auto,
      );
      await pump(tester);
      expect(find.text('Transcribe'), findsOneWidget);
      expect(find.byIcon(Icons.info_outline_rounded), findsNothing);
    });
  });
}
