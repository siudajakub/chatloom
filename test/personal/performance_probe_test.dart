// SPDX-License-Identifier: AGPL-3.0-or-later
// PF-10: bounded, numeric-only timing summaries and their timing points.
import 'dart:async';
import 'dart:convert';

import 'package:chatloom/personal/performance_probe.dart';
import 'package:chatloom/personal/performance_probe_client.dart';
import 'package:chatloom/personal/ui/performance_page.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

import '../notion/conversation_test_support.dart';

class _Inner extends http.BaseClient {
  final requests = <String>[];
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    requests.add('${request.method} ${request.url.path}');
    return http.StreamedResponse(
      Stream.value(utf8.encode('{"chunk":[]}')),
      200,
      request: request,
    );
  }
}

int _count(String name) =>
    PersonalPerformanceProbe.summaries()
        .where((s) => s.name == name)
        .firstOrNull
        ?.count ??
    0;

void main() {
  setUp(PersonalPerformanceProbe.reset);

  test('nearest-rank percentiles', () {
    final sorted = [for (var i = 1; i <= 100; i++) i.toDouble()];
    expect(percentile(sorted, 0.5), 50);
    expect(percentile(sorted, 0.9), 90);
    expect(percentile(sorted, 0.99), 99);
    expect(percentile([7], 0.99), 7);
    expect(percentile([], 0.5), 0);
  });

  test('samples are bounded per operation and in number of operations', () {
    for (var i = 0; i < 1000; i++) {
      PersonalPerformanceProbe.record('op', Duration(milliseconds: i % 10));
    }
    final summary = PersonalPerformanceProbe.summaries().single;
    expect(summary.count, 1000);
    expect(summary.max, 9);
    final samples = PerformanceSamples(capacity: 4);
    for (var i = 0; i < 10; i++) {
      samples.add(i.toDouble());
    }
    expect(samples.kept, 4);
    expect(samples.summary('x').p50, 7);
    for (var i = 0; i < PersonalPerformanceProbe.maxOperations + 10; i++) {
      PersonalPerformanceProbe.record('label$i', Duration.zero);
    }
    expect(
      PersonalPerformanceProbe.summaries(),
      hasLength(PersonalPerformanceProbe.maxOperations),
    );
  });

  test('a span records each phase once, then nothing after finish', () {
    final span = PersonalPerformanceProbe.span('send');
    span
      ..mark('durable')
      ..mark('durable')
      ..finish('acked')
      ..mark('late');
    expect(_count('send.durable'), 1);
    expect(_count('send.acked'), 1);
    expect(_count('send.late'), 0);
  });

  test('the zone span reaches async code and stream listeners', () async {
    final events = StreamController<int>.broadcast();
    final span = PersonalPerformanceProbe.span('send');
    await PersonalPerformanceProbe.runInSpan(span, () async {
      await Future<void>.delayed(Duration.zero);
      events.stream.listen(
        (_) => PersonalPerformanceProbe.currentSpan?.mark('bubble'),
      );
      PersonalPerformanceProbe.currentSpan?.mark('durable');
    });
    expect(PersonalPerformanceProbe.currentSpan, isNull);
    events.add(1);
    await Future<void>.delayed(Duration.zero);
    expect(_count('send.durable'), 1);
    expect(_count('send.bubble'), 1);
    await events.close();
  });

  test('frame recorder: percentiles and budget misses', () {
    final frames = FrameRecorder(capacity: 10);
    const budget = Duration(microseconds: 8333);
    for (var i = 1; i <= 20; i++) {
      frames.addDurations(
        build: Duration(milliseconds: i),
        raster: const Duration(milliseconds: 2),
        budget: budget,
      );
    }
    final summary = frames.summary()!;
    expect(summary.frames, 20);
    expect(summary.missed, 12); // 9 … 20 ms
    expect(summary.buildP50, 15); // last 10 kept: 11 … 20
    expect(summary.budgetMs, closeTo(8.33, 0.01));
    expect(summary.describe(), isNot(contains('!')));
  });

  test('report holds labels and numbers only', () {
    PersonalPerformanceProbe.record(
      'chat_open.rows',
      const Duration(milliseconds: 420),
    );
    final report = PersonalPerformanceProbe.report();
    expect(report, contains('chat_open.rows: n=1 p50=420 ms'));
    expect(report, isNot(contains('example')));
  });

  test('timing client measures members and send, passes others', () async {
    final inner = _Inner();
    final client = PerformanceTimingClient(inner);
    final base = Uri.parse('https://example.invalid');
    final members = await client.send(
      http.Request(
        'GET',
        base.replace(path: '/_matrix/client/v3/rooms/!r:x/members'),
      ),
    );
    expect(_count('members.fetch'), 0, reason: 'body not read yet');
    await members.stream.drain<void>();
    expect(_count('members.fetch'), 1);
    await client.send(
      http.Request(
        'PUT',
        base.replace(
          path: '/_matrix/client/v3/rooms/!r:x/send/m.room.message/t1',
        ),
      ),
    );
    expect(_count('send.http'), 1);
    await client.send(
      http.Request('GET', base.replace(path: '/_matrix/client/v3/sync')),
    );
    await client.send(
      http.Request(
        'PUT',
        base.replace(path: '/_matrix/client/v3/rooms/!r:x/typing/@u:x'),
      ),
    );
    expect(PersonalPerformanceProbe.summaries(), hasLength(2));
    expect(inner.requests, hasLength(4));
  });

  testWidgets('sync processing and receive → inbox row are measured', (
    tester,
  ) async {
    final client = ConversationClient();
    final room = ConversationRoom(client, '!probe:example.invalid');
    ClientPerformanceProbe.watch(client);
    ClientPerformanceProbe.watch(client); // idempotent
    client.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.processing));
    client.onSync.add(
      SyncUpdate(
        nextBatch: 'b1',
        rooms: RoomsUpdate(
          join: {
            room.id: JoinedRoomUpdate(
              timeline: TimelineUpdate(
                events: [
                  MatrixEvent(
                    type: EventTypes.Message,
                    content: {'msgtype': 'm.text', 'body': 'Fictional'},
                    senderId: '@anna:example.invalid',
                    eventId: r'$probe',
                    originServerTs: DateTime.utc(2026),
                  ),
                ],
              ),
            ),
          },
        ),
      ),
    );
    client.onSyncStatus.add(const SyncStatusUpdate(SyncStatus.finished));
    await tester.pump();
    expect(_count('sync.process'), 1);
    ClientPerformanceProbe.inboxPublished(
      client,
      const Duration(milliseconds: 3),
    );
    await tester.pump();
    expect(_count('inbox.publish'), 1);
    expect(_count('receive.row'), 1);
    // A publish without a new incoming message is not a receive.
    ClientPerformanceProbe.inboxPublished(client, Duration.zero);
    await tester.pump();
    expect(_count('receive.row'), 1);
  });

  testWidgets('Performance page shows summaries and clears them', (
    tester,
  ) async {
    PersonalPerformanceProbe.record(
      'send.bubble',
      const Duration(milliseconds: 80),
    );
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: const PerformancePage(),
      ),
    );
    expect(find.text('Send → bubble on screen'), findsOneWidget);
    expect(find.textContaining('median 80 ms'), findsOneWidget);
    await tester.tap(find.text('Measure frame times'));
    await tester.pump();
    expect(PersonalPerformanceProbe.recordingFrames, isTrue);
    await tester.tap(find.text('Measure frame times'));
    await tester.pump();
    expect(PersonalPerformanceProbe.recordingFrames, isFalse);
    await tester.ensureVisible(find.text('Clear'));
    await tester.tap(find.text('Clear'));
    await tester.pump();
    expect(find.text('No timings yet'), findsOneWidget);
  });
}
