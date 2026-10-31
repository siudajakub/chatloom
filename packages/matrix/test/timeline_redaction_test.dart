// SPDX-FileCopyrightText: 2026 ChatLoom contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:test/test.dart';

/// The timeline never touches the database here; any access is a bug.
class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access: ${invocation.memberName}');
}

void main() {
  group('Timeline redactions of related events', () {
    Logs().level = Level.error;
    const roomId = '!redactions:example.com';
    const alice = '@alice:example.com';

    late Client client;
    late Room room;
    late Timeline timeline;
    late List<int> changes;

    Event event(String id, Map<String, Object?> content, {String? type}) =>
        Event.fromJson({
          'type': type ?? EventTypes.Message,
          'content': content,
          'sender': alice,
          'status': EventStatus.synced.intValue,
          'event_id': id,
          'origin_server_ts': 1000,
        }, room);

    Event redaction(String id, String redacts) => Event.fromJson({
      'type': EventTypes.Redaction,
      'content': {'redacts': redacts},
      'redacts': redacts,
      'sender': alice,
      'event_id': id,
      'origin_server_ts': 2000,
    }, room);

    Future<void> deliver(Event e) async {
      client.onTimelineEvent.add(e);
      await Future<void>.delayed(Duration.zero);
    }

    Event byId(String id) => timeline.events.firstWhere((e) => e.eventId == id);

    setUp(() {
      client = Client('timeline redactions', database: _NoDatabase());
      room = Room(id: roomId, client: client);
      changes = [];
      final root = event(r'$root', {'msgtype': 'm.text', 'body': 'root'});
      final thread = event(r'$thread', {
        'msgtype': 'm.text',
        'body': 'secret in a thread',
        'm.relates_to': {
          'rel_type': RelationshipTypes.thread,
          'event_id': r'$root',
          'is_falling_back': true,
          'm.in_reply_to': {'event_id': r'$root'},
        },
      });
      final reply = event(r'$reply', {
        'msgtype': 'm.text',
        'body': 'secret reply',
        'm.relates_to': {
          'm.in_reply_to': {'event_id': r'$root'},
        },
      });
      final reaction = event(r'$reaction', {
        'm.relates_to': {
          'rel_type': RelationshipTypes.reaction,
          'event_id': r'$root',
          'key': '👍',
        },
      }, type: EventTypes.Reaction);
      final edit = event(r'$edit', {
        'msgtype': 'm.text',
        'body': '* root edited',
        'm.new_content': {'msgtype': 'm.text', 'body': 'root edited'},
        'm.relates_to': {
          'rel_type': RelationshipTypes.edit,
          'event_id': r'$root',
        },
      });
      timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: [edit, reaction, reply, thread, root]),
        onChange: changes.add,
      );
      // Building the aggregation reports changes too; start clean.
      changes.clear();
    });

    tearDown(() => timeline.cancelSubscriptions());

    test('a thread message loses its content like any message', () async {
      final root = byId(r'$root');
      expect(root.aggregatedEvents(timeline, RelationshipTypes.thread), [
        byId(r'$thread'),
      ]);
      await deliver(redaction(r'$r1', r'$thread'));
      final thread = byId(r'$thread');
      expect(thread.redacted, isTrue);
      expect(thread.body, isNot(contains('secret')));
      expect(thread.content, isEmpty);
      // The root's thread summary and the redacted row both update.
      expect(
        root.aggregatedEvents(timeline, RelationshipTypes.thread),
        isEmpty,
      );
      expect(changes, contains(timeline.events.indexOf(root)));
      expect(changes, contains(timeline.events.indexOf(thread)));
    });

    test('a reply loses its content', () async {
      await deliver(redaction(r'$r2', r'$reply'));
      expect(byId(r'$reply').redacted, isTrue);
      expect(byId(r'$reply').content, isEmpty);
    });

    test(
      'reactions and edits only update the message they belong to',
      () async {
        final root = byId(r'$root');
        expect(
          root.hasAggregatedEvents(timeline, RelationshipTypes.reaction),
          isTrue,
        );
        await deliver(redaction(r'$r3', r'$reaction'));
        expect(
          root.aggregatedEvents(timeline, RelationshipTypes.reaction),
          isEmpty,
        );
        expect(changes, [timeline.events.indexOf(root)]);
        changes.clear();
        await deliver(redaction(r'$r4', r'$edit'));
        expect(
          root.aggregatedEvents(timeline, RelationshipTypes.edit),
          isEmpty,
        );
        expect(changes, [timeline.events.indexOf(root)]);
        // The root itself is untouched.
        expect(root.redacted, isFalse);
        expect(root.body, 'root');
      },
    );
  });
}
