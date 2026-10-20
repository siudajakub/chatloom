// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/reminder_notification.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

const _owner = '@synthetic-owner:example.invalid';
const _peer = '@synthetic-peer:example.invalid';

class _Database implements DatabaseApi {
  final events = <String, Event>{};
  bool fail = false;
  @override
  Future<Event?> getEventById(String id, Room room) async {
    if (fail) throw StateError('Synthetic storage failure');
    return events[id];
  }

  @override
  Future<User?> getUser(String userId, Room room) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database operation');
}

class _Client extends Client {
  _Client(_Database database) : super('synthetic reminder', database: database);
  @override
  String? get userID => _owner;
}

Event _event(
  Room room, {
  String id = r'$synthetic-anchor',
  String sender = _peer,
  String type = EventTypes.Message,
  Map<String, Object?>? content,
}) => Event(
  room: room,
  type: type,
  eventId: id,
  senderId: sender,
  originServerTs: DateTime.utc(2026, 10, 17, 9),
  content: content ?? {'msgtype': 'm.text', 'body': 'Call me tomorrow'},
);

void main() {
  late _Database database;
  late Room room;

  setUp(() {
    database = _Database();
    final client = _Client(database);
    room = Room(id: '!synthetic-target:example.invalid', client: client);
    client.rooms.add(room);
  });

  test('title carries the reminder marker and the chat name', () {
    final text = reminderNotificationText(
      previews: true,
      chatName: 'Anna',
      preview: 'Anna: Call me tomorrow',
      messageKnown: true,
    );
    expect(text.title, '⏰ Reminder · Anna');
    expect(text.body, 'Anna: Call me tomorrow');
  });

  test('the app lock hides the chat and the message', () {
    final text = reminderNotificationText(
      previews: true,
      chatName: 'Anna',
      preview: 'Anna: Call me tomorrow',
      messageKnown: true,
      locked: true,
    );
    expect(text.title, '⏰ Reminder');
    expect(text.body, 'Open the app to read');
  });

  test('fallbacks: no message, unreadable message, previews off', () {
    expect(
      reminderNotificationText(
        previews: true,
        chatName: 'Anna',
        preview: null,
        messageKnown: false,
      ).body,
      'Reminder about this chat',
    );
    expect(
      reminderNotificationText(
        previews: true,
        chatName: null,
        preview: null,
        messageKnown: true,
      ),
      isA<ReminderNotificationText>()
          .having((t) => t.title, 'title', '⏰ Reminder')
          .having((t) => t.body, 'body', 'Open to see the message'),
    );
    final hidden = reminderNotificationText(
      previews: false,
      chatName: 'Anna',
      preview: 'Anna: Call me tomorrow',
      messageKnown: true,
    );
    expect(hidden.title, '⏰ Reminder');
    expect(hidden.body, 'Reminder about this chat');
    expect(reminderPublicTitle, 'Reminder');
    expect(reminderPublicBody, 'Unlock to view');
  });

  test('anchor ids are validated', () {
    expect(reminderAnchorEventId({'anchorEventId': r'$abc'}), r'$abc');
    expect(reminderAnchorEventId({'anchorEventId': 'abc'}), isNull);
    expect(reminderAnchorEventId({'anchorEventId': '\$${'a' * 255}'}), isNull);
    expect(reminderAnchorEventId({'anchorEventId': 42}), isNull);
    expect(reminderAnchorEventId(null), isNull);
  });

  test('previews name the sender, or "You" for own messages', () {
    expect(
      reminderMessagePreview(_event(room), own: false),
      'Synthetic-peer: Call me tomorrow',
    );
    expect(
      reminderMessagePreview(_event(room, sender: _owner), own: true),
      'You: Call me tomorrow',
    );
    expect(
      reminderMessagePreview(
        _event(
          room,
          type: EventTypes.Sticker,
          content: {'body': 'cat', 'url': 'mxc://example.invalid/sticker'},
        ),
        own: true,
      ),
      'You: Sticker',
    );
    expect(
      reminderMessagePreview(
        _event(
          room,
          type: EventTypes.Encrypted,
          content: {'algorithm': 'm.megolm.v1.aes-sha2'},
        ),
        own: false,
      ),
      isNull,
    );
  });

  test('the anchored message wins; without an anchor, the latest', () async {
    final anchored = _event(room);
    final latest = _event(room, id: r'$synthetic-latest');
    room.lastEvent = latest;
    database.events[anchored.eventId] = anchored;
    expect(
      (await resolveReminderMessage(room, anchored.eventId))?.eventId,
      anchored.eventId,
    );
    expect((await resolveReminderMessage(room, null))?.eventId, latest.eventId);
    room.lastEvent = null;
    expect(await resolveReminderMessage(room, null), isNull);
  });

  test('an unresolved anchor never falls back to the latest message', () async {
    final anchored = _event(room);
    room.lastEvent = _event(room, id: r'$synthetic-latest');
    database.fail = true;
    expect(await resolveReminderMessage(room, anchored.eventId), isNull);
    database.fail = false;
    expect(
      await resolveReminderMessage(
        room,
        anchored.eventId,
        timeout: Duration.zero,
      ),
      isNull,
    );
    expect(
      await resolveReminderMessage(
        room,
        r'$synthetic-missing',
        timeout: const Duration(seconds: 1),
      ),
      isNull,
    );
    // The presenter marks an anchored reminder as "message known", so the
    // body asks to open the chat instead of quoting another message.
    expect(
      reminderNotificationText(
        previews: true,
        chatName: 'Anna',
        preview: null,
        messageKnown: true,
      ).body,
      'Open to see the message',
    );
  });
}
