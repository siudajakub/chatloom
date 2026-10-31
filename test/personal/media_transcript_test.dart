// SPDX-License-Identifier: AGPL-3.0-or-later
// The live transcript of the full-screen players: which transcript it shows
// (done only, never requested), exact worker timestamps versus the estimate,
// and the show/hide toggle. Fictional fixtures only.
import 'package:chatloom/personal/media_transcript.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import '../notion/conversation_test_support.dart';

class _FakePersonal extends PersonalClient {
  _FakePersonal(super.client)
    : super.forTesting(openStore: () => throw StateError('No fixture store'));

  final jobs = <String, TranscriptionJob>{};
  int requests = 0;

  @override
  Map<String, TranscriptionJob> get transcripts => jobs;
  @override
  String transcriptId(Event e) => 'transcript:${e.eventId}';
  @override
  Future<void> transcribe(Event e, {String? language}) async => requests++;

  void setJob(Event e, JobState state, {String? text, Object? timing}) {
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
      text: text,
      durationSeconds: 6,
      timing: timing,
    );
    notifyListeners();
  }
}

const _text = 'Hello Anna. How are you today?';

Widget _app(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(Brightness.dark),
  home: Scaffold(
    backgroundColor: NotionMediaColors.viewer,
    body: SizedBox(height: 400, child: child),
  ),
);

void main() {
  late ConversationClient client;
  late Event voice;
  late _FakePersonal personal;

  setUp(() {
    client = ConversationClient();
    final room = ConversationRoom(client, '!voice:example.invalid');
    voice = room.message(
      r'$voice',
      'voice.ogg',
      content: {
        'msgtype': MessageTypes.Audio,
        'body': 'voice.ogg',
        'url': 'mxc://example.invalid/voice',
        'info': {'duration': 6000},
      },
    );
    personal = _FakePersonal(client);
    MediaTranscriptPreference.visible.value = true;
  });

  testWidgets('shows only a finished transcript and never asks for one', (
    tester,
  ) async {
    final seen = <MediaTranscript?>[];
    await tester.pumpWidget(
      _app(
        MediaTranscriptBuilder(
          event: voice,
          personalClient: personal,
          builder: (context, transcript) {
            seen.add(transcript);
            return Text(transcript?.text ?? 'none');
          },
        ),
      ),
    );
    expect(find.text('none'), findsOneWidget);
    personal.setJob(voice, JobState.processing);
    await tester.pump();
    expect(find.text('none'), findsOneWidget);
    personal.setJob(voice, JobState.done, text: _text);
    await tester.pump();
    expect(find.text(_text), findsOneWidget);
    // Unrelated sync notifications do not rebuild the player.
    final builds = seen.length;
    personal.notifyListeners();
    await tester.pump();
    expect(seen, hasLength(builds));
    expect(personal.requests, 0);
  });

  testWidgets('estimates line times without worker timestamps', (tester) async {
    final position = ValueNotifier(Duration.zero);
    addTearDown(position.dispose);
    await tester.pumpWidget(
      _app(
        MediaSyncedTranscript(
          transcript: const MediaTranscript(text: _text, durationSeconds: 6),
          position: position,
        ),
      ),
    );
    await tester.pump();
    expect(find.text(MediaSyncedTranscript.approximateCaption), findsOneWidget);
    // Two short sentences share one estimated line.
    expect(find.text(_text), findsOneWidget);
  });

  testWidgets('uses exact worker timestamps and lights words', (tester) async {
    const s = Duration(seconds: 1);
    TranscriptSpan span(double from, double to, int start, int end) =>
        TranscriptSpan(
          start: s * from,
          end: s * to,
          textStart: start,
          textEnd: end,
        );
    final timing = TranscriptTiming.encode(
      segments: [span(.5, 1.6, 0, 11), span(2.4, 4, 12, 30)],
      words: [
        span(.5, .9, 0, 5),
        span(1, 1.6, 6, 11),
        span(2.4, 2.6, 12, 15),
        span(2.7, 2.9, 16, 19),
        span(3, 3.2, 20, 23),
        span(3.3, 4, 24, 30),
      ],
    );
    final position = ValueNotifier(const Duration(milliseconds: 2800));
    addTearDown(position.dispose);
    await tester.pumpWidget(
      _app(
        MediaSyncedTranscript(
          transcript: MediaTranscript(text: _text, timing: timing),
          position: position,
        ),
      ),
    );
    await tester.pump();
    expect(find.text(MediaSyncedTranscript.approximateCaption), findsNothing);
    final current = tester.widget<RichText>(
      find.byWidgetPredicate(
        (w) => w is RichText && w.text.toPlainText() == 'How are you today?',
      ),
    );
    final spans = <String>[];
    current.text.visitChildren((span) {
      if (span is TextSpan && span.text != null) spans.add(span.text!);
      return true;
    });
    expect(spans, ['How are', ' you today?']);
  });

  testWidgets('the toggle hides and shows the transcript for every player', (
    tester,
  ) async {
    await tester.pumpWidget(_app(const MediaTranscriptToggle()));
    expect(find.byTooltip('Hide transcript'), findsOneWidget);
    await tester.tap(find.byType(IconButton));
    await tester.pump();
    expect(MediaTranscriptPreference.visible.value, isFalse);
    expect(find.byTooltip('Show transcript'), findsOneWidget);
    await tester.tap(find.byType(IconButton));
    await tester.pumpAndSettle();
    expect(MediaTranscriptPreference.visible.value, isTrue);
  });

  test('prefers the player length, then the worker, then the message', () {
    const transcript = MediaTranscript(text: _text, durationSeconds: 8);
    Duration end(TranscriptTiming? timing) => timing!.lines.last.end;
    expect(
      end(transcript.timingFor(const Duration(seconds: 10))),
      const Duration(seconds: 10),
    );
    expect(end(transcript.timingFor(null)), const Duration(seconds: 8));
    expect(
      end(
        const MediaTranscript(
          text: _text,
        ).timingFor(null, declared: const Duration(seconds: 5)),
      ),
      const Duration(seconds: 5),
    );
    expect(const MediaTranscript(text: _text).timingFor(null), isNull);
    expect(
      MediaTranscript.of(
        const TranscriptionJob(
          id: 'x',
          source: SourceEventRef(
            conversation: ConversationRef(accountId: 'a', roomId: 'r'),
            eventId: 'e',
          ),
          state: JobState.done,
          text: '  ',
        ),
      ),
      isNull,
    );
  });
}
