// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:flutter_test/flutter_test.dart';

import '../notion/conversation_test_support.dart';

void main() {
  test('ordinary inbox preserves pin/unread order and query filtering', () {
    final client = ConversationClient();
    final personal = PersonalClient.of(client);
    addTearDown(personal.dispose);
    final pinned = ConversationRoom(client, '!pinned:example.invalid');
    final unread = ConversationRoom(client, '!unread:example.invalid');
    final recent = ConversationRoom(client, '!recent:example.invalid');
    final archived = ConversationRoom(client, '!archived:example.invalid');
    final low = ConversationRoom(client, '!low:example.invalid');
    for (final (i, room) in client.rooms.indexed) {
      room.lastEvent = (room as ConversationRoom).message(
        '\$fixture-$i',
        'Fictional preview',
        minute: i + 1,
      );
    }
    personal.values['org:${pinned.id}'] = {
      'nickname': 'Target pinned',
      'pinOrder': 0,
    };
    personal.values['org:${unread.id}'] = {'nickname': 'Target unread'};
    unread.notificationCount = 2;
    personal.values['org:${archived.id}'] = {'archived': true};
    personal.values['org:${low.id}'] = {'lowPriority': true};
    final projection = InboxProjection.snapshot(personal);
    final index = projection.buildIndex(client.rooms);

    expect(projection.select(index), [pinned, unread, recent]);
    expect(projection.select(index, query: 'target'), [pinned, unread]);
    expect(projection.select(index, query: 'missing'), isEmpty);
  });

  test(
    'completed reminders retain the broader selection with query matching',
    () {
      final client = ConversationClient();
      final personal = PersonalClient.of(client);
      addTearDown(personal.dispose);
      final ordinary = ConversationRoom(client, '!ordinary:example.invalid');
      final due = ConversationRoom(client, '!due:example.invalid');
      final otherAccount = ConversationRoom(client, '!other:example.invalid');
      personal.values['org:${due.id}'] = {
        'nickname': 'Target reminder',
        'lowPriority': true,
      };
      personal.values['org:${otherAccount.id}'] = {'lowPriority': true};
      personal.reminders['due'] = {
        'state': 'done',
        'conversation': personal.ref(due).toJson(),
        'dueAt': '2026-11-01T12:00:00.000Z',
      };
      personal.reminders['other'] = {
        'state': 'done',
        'conversation': {
          ...personal.ref(otherAccount).toJson(),
          'accountId': '@other:example.invalid',
        },
        'dueAt': '2026-11-01T12:00:00.000Z',
      };
      final projection = InboxProjection.snapshot(personal);
      final index = projection.buildIndex(client.rooms);

      expect(projection.select(index), unorderedEquals([ordinary, due]));
      expect(projection.select(index, query: 'target'), [due]);
      expect(projection.select(index, query: 'missing'), isEmpty);
    },
  );
}
