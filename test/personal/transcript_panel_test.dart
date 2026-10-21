// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline widget tests for the transcription split button and panel.
import 'dart:async';

import 'package:chatloom/pages/chat/conversation_message_gestures.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/transcript_panel.dart';
import 'package:chatloom/personal/ui/notion_transcribe_button.dart';
import 'package:chatloom/personal/worker_readiness.dart';
import 'package:chatloom/ui/notion/notion.dart';
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
  }) => tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
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

  testWidgets('every busy step is the same quiet placeholder', (
    tester,
  ) async {
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
