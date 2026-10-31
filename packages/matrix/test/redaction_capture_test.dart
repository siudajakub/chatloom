// SPDX-FileCopyrightText: 2026 ChatLoom contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

// ChatLoom fork: `Client.onBeforeRedaction` sees a redacted message while it
// is still intact in the database, the room preview and open timelines.

import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:test/test.dart';

import 'fake_client.dart';

void main() {
  group('Redaction capture', () {
    const roomId = '!capture:example.com';
    const alice = '@alice:example.com';

    late Client client;

    setUp(() async {
      client = await getClient();
      Logs().level = Level.error;
      await client.abortSync();
      client.rooms.clear();
      await client.database.clearCache();
    });

    tearDown(() async => client.dispose().onError((e, s) {}));

    MatrixEvent message(String id, String body, {int ts = 1000}) => MatrixEvent(
      type: EventTypes.Message,
      content: {'msgtype': MessageTypes.Text, 'body': body},
      senderId: alice,
      eventId: id,
      originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
    );

    MatrixEvent edit(String id, String target, String body, {int ts = 1500}) =>
        MatrixEvent(
          type: EventTypes.Message,
          content: {
            'msgtype': MessageTypes.Text,
            'body': '* $body',
            'm.new_content': {'msgtype': MessageTypes.Text, 'body': body},
            'm.relates_to': {
              'rel_type': RelationshipTypes.edit,
              'event_id': target,
            },
          },
          senderId: alice,
          eventId: id,
          originServerTs: DateTime.fromMillisecondsSinceEpoch(ts),
        );

    MatrixEvent redaction(String id, String target) => MatrixEvent(
      type: EventTypes.Redaction,
      content: {'redacts': target, 'reason': 'test'},
      redacts: target,
      senderId: alice,
      eventId: id,
      originServerTs: DateTime.fromMillisecondsSinceEpoch(3000),
    );

    Future<void> sync(String batch, List<MatrixEvent> events) =>
        client.handleSync(
          SyncUpdate(
            nextBatch: batch,
            rooms: RoomsUpdate(
              join: {
                roomId: JoinedRoomUpdate(
                  timeline: TimelineUpdate(events: events),
                ),
              },
            ),
          ),
        );

    test(
      'runs before the room preview, database and timeline change',
      () async {
        await sync('one', [message(r'$secret', 'original text')]);
        final room = client.getRoomById(roomId)!;
        final timeline = Timeline(
          room: room,
          chunk: TimelineChunk(
            events: [(await client.database.getEventById(r'$secret', room))!],
          ),
        );
        addTearDown(timeline.cancelSubscriptions);

        final seen = <String>[];
        client.onBeforeRedaction = (capture) async {
          expect(capture.toString(), isNot(contains('original')));
          expect(capture.original.eventId, r'$secret');
          expect(capture.original.body, 'original text');
          expect(capture.redaction.eventId, r'$redaction');
          expect(capture.latestEdit, isNull);
          // Nothing has applied the redaction yet.
          final stored = await client.database.getEventById(r'$secret', room);
          expect(stored!.redacted, isFalse);
          expect(stored.body, 'original text');
          expect(room.lastEvent?.redacted, isFalse);
          expect(timeline.events.single.redacted, isFalse);
          seen.add(capture.original.eventId);
        };

        await sync('two', [redaction(r'$redaction', r'$secret')]);
        await Future<void>.delayed(Duration.zero);

        expect(seen, [r'$secret']);
        // ...and afterwards it is applied everywhere as usual.
        final stored = await client.database.getEventById(r'$secret', room);
        expect(stored!.redacted, isTrue);
        expect(stored.content['body'], isNull);
        expect(
          timeline.events.firstWhere((e) => e.eventId == r'$secret').redacted,
          isTrue,
        );
      },
    );

    test('hands over the newest edit by the author', () async {
      await sync('one', [
        message(r'$m', 'first'),
        edit(r'$e1', r'$m', 'second', ts: 1500),
        edit(r'$e2', r'$m', 'third', ts: 1600),
      ]);
      RedactionCapture? captured;
      client.onBeforeRedaction = (capture) async => captured = capture;
      await sync('two', [redaction(r'$r', r'$m')]);
      expect(captured, isNotNull);
      expect(captured!.original.body, 'first');
      expect(captured!.latestEdit?.eventId, r'$e2');
      expect(
        captured!.latestEdit?.content['m.new_content'],
        containsPair('body', 'third'),
      );
    });

    test(
      'nothing is read without a hook; errors never stop the sync',
      () async {
        await sync('one', [message(r'$a', 'a'), message(r'$b', 'b', ts: 1100)]);
        final room = client.getRoomById(roomId)!;
        // Without a hook the redaction applies as upstream.
        await sync('two', [redaction(r'$ra', r'$a')]);
        expect(
          (await client.database.getEventById(r'$a', room))!.redacted,
          isTrue,
        );
        // A failing hook is logged by type and ignored.
        client.onBeforeRedaction = (_) async => throw StateError('boom');
        await sync('three', [redaction(r'$rb', r'$b')]);
        expect(
          (await client.database.getEventById(r'$b', room))!.redacted,
          isTrue,
        );
        // An already redacted message is not handed over again.
        var calls = 0;
        client.onBeforeRedaction = (_) async => calls++;
        await sync('four', [redaction(r'$ra2', r'$a')]);
        expect(calls, 0);
      },
    );
  });
}
