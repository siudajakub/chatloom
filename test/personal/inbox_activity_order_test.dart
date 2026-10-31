// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/pages/chat_list/inbox_controller.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import '../notion/conversation_test_support.dart';

/// Accepts the writes of Client.handleSync and of a local echo.
class _SyncDatabase implements DatabaseApi {
  static const _writes = {
    #storeEventUpdate,
    #storeRoomUpdate,
    #storeAccountData,
    #storeRoomAccountData,
    #storeLatestReceiptState,
    #deleteTimelineForRoom,
    #markUserProfileAsOutdated,
  };
  @override
  Future<void> transaction(Future<void> Function() action) => action();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      _writes.contains(invocation.memberName)
      ? Future<void>.value()
      : throw StateError('Unexpected database access');
}

const _owner = '@owner:example.invalid';
const _anna = '@anna:example.invalid';

class _Client extends Client {
  _Client() : super('offline inbox order fixture', database: _SyncDatabase());
  @override
  String get userID => _owner;
  @override
  Map<String, List<String>> get directChats => {
    _anna: rooms.map((r) => r.id).toList(),
  };

  /// Preview refreshes stay pending (offline).
  int refreshes = 0;
  @override
  Future<GetRoomEventsResponse> getRoomEvents(
    String roomId,
    Direction dir, {
    String? from,
    String? to,
    int? limit,
    String? filter,
  }) {
    refreshes++;
    return Completer<GetRoomEventsResponse>().future;
  }

  /// Sends stay in flight: only the local echo exists.
  @override
  Future<String> sendMessage(
    String roomId,
    String eventType,
    String txnId,
    Map<String, Object?> body,
  ) => Completer<String>().future;
}

// Local time: the SDK reads timestamps as local DateTimes.
final _t0 = DateTime(2026, 10, 30, 12);
DateTime _at(int minute) => _t0.add(Duration(minutes: minute));

MatrixEvent _message(
  String id,
  int minute, {
  Map<String, Object?>? relatesTo,
}) => MatrixEvent(
  eventId: id,
  type: EventTypes.Message,
  senderId: _anna,
  originServerTs: _at(minute),
  content: {
    'msgtype': MessageTypes.Text,
    'body': 'Fictional $id',
    if (relatesTo != null) ...{
      'm.new_content': {'msgtype': MessageTypes.Text, 'body': 'Edited'},
      'm.relates_to': relatesTo,
    },
  },
);

MatrixEvent _edit(String id, String original, int minute) => _message(
  id,
  minute,
  relatesTo: {'rel_type': RelationshipTypes.edit, 'event_id': original},
);

MatrixEvent _reaction(String id, String target, int minute) => MatrixEvent(
  eventId: id,
  type: EventTypes.Reaction,
  senderId: _anna,
  originServerTs: _at(minute),
  content: {
    'm.relates_to': {
      'rel_type': RelationshipTypes.reaction,
      'event_id': target,
      'key': '👍',
    },
  },
);

BasicEvent _typing() => BasicEvent(
  type: 'm.typing',
  content: {
    'user_ids': [_anna],
  },
);

BasicEvent _receipt(String eventId) => BasicEvent(
  type: 'm.receipt',
  content: {
    eventId: {
      'm.read': {
        _anna: {'ts': _at(59).millisecondsSinceEpoch},
      },
    },
  },
);

var _syncs = 0;

Future<void> _sync(
  Room room, {
  List<MatrixEvent>? timeline,
  bool limited = false,
  List<BasicEvent>? ephemeral,
}) async {
  await room.client.handleSync(
    SyncUpdate(
      nextBatch: 'order-${++_syncs}',
      rooms: RoomsUpdate(
        join: {
          room.id: JoinedRoomUpdate(
            timeline: timeline == null && !limited
                ? null
                : TimelineUpdate(events: timeline, limited: limited),
            ephemeral: ephemeral,
          ),
        },
      ),
    ),
  );
  // onSync is delivered asynchronously to the inbox controller.
  await pumpEventQueue();
}

Event _placeholder(Room room, String id, DateTime time) => Event(
  type: EventTypes.refreshingLastEvent,
  content: {'body': 'Refreshing last event...'},
  room: room,
  eventId: id,
  senderId: _owner,
  originServerTs: time,
);

/// Inbox order (2026-10-30): a chat's place follows its newest message only.
/// Preview placeholders, typing/receipt updates and edits never move it; an
/// own message moves it to the top of its band at once.
void main() {
  late _Client client;
  late ConversationRoom older, newer;
  late PersonalClient personal;
  late InboxController inbox;

  List<Room> order() {
    inbox.refresh();
    return inbox.projection.select(inbox.index);
  }

  DateTime? activity(Room room) => inbox.index.recordFor(room)?.lastActivity;

  setUp(() async {
    client = _Client();
    older = ConversationRoom(client, '!older:example.invalid');
    newer = ConversationRoom(client, '!newer:example.invalid');
    await _sync(older, timeline: [_message('older', 1)]);
    await _sync(newer, timeline: [_message('newer', 2)]);
    personal = PersonalClient.of(client);
    inbox = InboxController(client, personal);
    expect(order(), [newer, older]);
  });

  tearDown(() {
    inbox.dispose();
    personal.dispose();
  });

  test(
    'typing-only updates keep a chat with a pending preview in place',
    () async {
      // The preview refresh of `older` is pending behind a placeholder.
      older.lastEvent = _placeholder(older, 'placeholder', _at(1));
      inbox.markChanged(rooms: [older.id]);
      expect(order(), [newer, older]);

      await _sync(older, ephemeral: [_typing()]);
      final recreated = older.lastEvent!;
      expect(recreated.type, EventTypes.refreshingLastEvent);
      expect(recreated.eventId, isNot('placeholder'));
      expect(recreated.originServerTs, _at(1), reason: 'not now()');
      expect(order(), [newer, older]);
      expect(activity(older), _at(1));

      // A reaction (not a preview event) does not advance the time either.
      await _sync(older, timeline: [_reaction('like', 'older', 30)]);
      expect(older.lastEvent!.originServerTs, _at(1));
      expect(order(), [newer, older]);
    },
  );

  test('a gappy sync without messages keeps the last message time', () async {
    await _sync(
      older,
      limited: true,
      timeline: [_reaction('like', 'older', 30)],
    );
    expect(older.lastEvent!.type, EventTypes.refreshingLastEvent);
    expect(older.lastEvent!.originServerTs, _at(1));
    expect(order(), [newer, older]);
    expect(client.refreshes, greaterThan(0));
  });

  test('a placeholder never gives a chat a newer time than its row had', () {
    older.lastEvent = _placeholder(older, 'late', _at(50));
    inbox.markChanged(rooms: [older.id]);
    expect(order(), [newer, older]);
    expect(activity(older), _at(1));
    // Also across a full rebuild (private metadata change).
    inbox.markChanged(all: true);
    expect(order(), [newer, older]);
  });

  test('editing the last message does not move the chat', () async {
    await _sync(older, timeline: [_edit('edit', 'older', 10)]);
    expect(older.lastEvent!.eventId, 'edit', reason: 'preview shows the edit');
    expect(activity(older), _at(1));
    expect(order(), [newer, older]);

    // An edit of the edit still keeps the original message's time, also
    // after the room (with its last event) is stored and loaded again.
    await _sync(older, timeline: [_edit('edit-2', 'older', 20)]);
    expect(older.lastEvent!.eventId, 'edit-2');
    expect(activity(older), _at(1));
    final restored = Room.fromJson(older.toJson(), client);
    expect(InboxProjection.activityTime(restored.lastEvent), _at(1));
    expect(order(), [newer, older]);

    // A new message moves it as usual.
    await _sync(older, timeline: [_message('reply', 30)]);
    expect(order(), [older, newer]);
  });

  test('receipt-only updates refresh a row whose last event changed', () async {
    final generation = inbox.generation;
    await _sync(older, ephemeral: [_receipt('older')]);
    inbox.refresh();
    expect(inbox.generation, generation, reason: 'nothing to publish');

    // The SDK replaced the last event outside a timeline update.
    older.lastEvent = Event.fromMatrixEvent(_message('late', 10), older);
    await _sync(older, ephemeral: [_receipt('older')]);
    expect(order(), [older, newer]);
    expect(activity(older), _at(10));
  });

  test('an own local echo moves the chat to the top of its band', () async {
    final unread = ConversationRoom(client, '!unread:example.invalid');
    await _sync(unread, timeline: [_message('unread', 0)]);
    unread.notificationCount = 1;
    inbox.markChanged(rooms: [unread.id]);
    expect(order(), [unread, newer, older]);

    unawaited(older.sendTextEvent('Fictional reply'));
    await pumpEventQueue();
    expect(older.lastEvent!.status, EventStatus.sending);
    expect(order(), [unread, older, newer]);
  });

  test('a merged person takes the newest time of its chats', () async {
    final third = ConversationRoom(client, '!third:example.invalid');
    await _sync(third, timeline: [_message('third', 3)]);
    personal.values['person:p'] = PersonGroup(
      id: 'p',
      name: 'Fictional person',
      members: [personal.ref(older), personal.ref(newer)],
      defaultRoomId: older.id,
    ).toJson().cast<String, dynamic>();
    inbox.markChanged(all: true);
    expect(order(), [third, older]);
    expect(activity(older), _at(2));

    await _sync(older, timeline: [_message('person', 5)]);
    expect(order(), [older, third]);
    expect(activity(newer), _at(5));

    // Typing in the other chat with a pending preview, and an edit of the
    // newest message, keep the person's time.
    newer.lastEvent = _placeholder(newer, 'pending', _at(2));
    await _sync(newer, ephemeral: [_typing()]);
    await _sync(older, timeline: [_edit('person-edit', 'person', 40)]);
    expect(activity(older), _at(5));
    await _sync(third, timeline: [_message('third-2', 6)]);
    expect(order(), [third, older]);
  });
}
