// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption/encryption.dart';
import 'package:matrix/matrix.dart';

class _Database implements DatabaseApi {
  @override
  Future<void> transaction(Future<void> Function() action) => action();
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Encryption extends Encryption {
  _Encryption(Client client) : super(client: client);
  @override
  Future<Event> decryptRoomEvent(
    Event event, {
    bool store = false,
    EventUpdateType updateType = EventUpdateType.timeline,
  }) async => Event.fromJson({
    ...event.toJson(),
    'type': event.eventId == 'missing-key'
        ? EventTypes.Encrypted
        : 'com.beeper.message_send_status',
    'content': {'status': 'SUCCESS'},
  }, event.room);
}

class _Client extends Client {
  _Client() : super('offline preview fixture', database: _Database());
  @override
  String get userID => '@owner:example.invalid';
  @override
  late final Encryption encryption = _Encryption(this);
  final pages = <GetRoomEventsResponse>[];
  final cursors = <String?>[];
  Completer<void>? gate;
  @override
  Future<GetRoomEventsResponse> getRoomEvents(
    String roomId,
    Direction dir, {
    String? from,
    String? to,
    int? limit,
    String? filter,
  }) async {
    cursors.add(from);
    await gate?.future;
    return pages.removeAt(0);
  }

  @override
  Future<void> handleSync(SyncUpdate sync, {Direction? direction}) async {}
}

MatrixEvent _event(String id, String type) => MatrixEvent(
  eventId: id,
  type: type,
  content: {'msgtype': 'm.text', 'body': 'Hello'},
  senderId: '@owner:example.invalid',
  originServerTs: DateTime.utc(2026),
);

void main() {
  late _Client client;
  late Room room;
  setUp(() {
    client = _Client();
    room = Room(id: '!fixture:example.invalid', client: client);
  });

  test('encrypted send reports are skipped across pages', () async {
    client.pages.addAll([
      GetRoomEventsResponse(
        start: 'start',
        end: 'older',
        chunk: [_event('status', EventTypes.Encrypted)],
      ),
      GetRoomEventsResponse(
        start: 'older',
        chunk: [_event('message', EventTypes.Message)],
      ),
    ]);
    expect((await room.refreshLastEvent())?.eventId, 'message');
    expect(room.lastEvent?.body, 'Hello');
    expect(client.cursors, [null, 'older']);
  });

  test('refreshes share a request and preserve a newer live send', () async {
    client.gate = Completer<void>();
    client.pages.add(
      GetRoomEventsResponse(
        start: 'start',
        chunk: [_event('old', EventTypes.Message)],
      ),
    );
    final first = room.refreshLastEvent();
    final second = room.refreshLastEvent();
    final live = Event.fromMatrixEvent(
      _event('live', EventTypes.Message),
      room,
    );
    room.lastEvent = live;
    client.gate!.complete();
    expect(await first, same(live));
    expect(await second, same(live));
    expect(client.cursors, [null]);
  });

  test(
    'undecryptable messages remain previews until their key arrives',
    () async {
      client.pages.add(
        GetRoomEventsResponse(
          start: 'start',
          chunk: [_event('missing-key', EventTypes.Encrypted)],
        ),
      );
      expect((await room.refreshLastEvent())?.eventId, 'missing-key');
      expect(room.lastEvent?.type, EventTypes.Encrypted);
    },
  );

  test('a failed refresh releases the shared request for retry', () async {
    client.gate = Completer<void>();
    final failed = room.refreshLastEvent();
    final check = expectLater(failed, throwsStateError);
    client.gate!.completeError(StateError('offline fixture'));
    await check;
    client.gate = null;
    client.pages.add(
      GetRoomEventsResponse(
        start: 'start',
        chunk: [_event('retry', EventTypes.Message)],
      ),
    );
    expect((await room.refreshLastEvent())?.eventId, 'retry');
    expect(client.cursors, [null, null]);
  });

  test(
    'repeated pagination token terminates without a technical preview',
    () async {
      room.lastEvent = Event.fromMatrixEvent(
        _event('cached-status', 'com.beeper.message_send_status'),
        room,
      );
      for (var i = 0; i < 2; i++) {
        client.pages.add(
          GetRoomEventsResponse(
            start: 'start',
            end: 'same',
            chunk: [_event('status-$i', EventTypes.Encrypted)],
          ),
        );
      }
      expect(await room.refreshLastEvent(), isNull);
      expect(room.lastEvent, isNull);
      expect(client.cursors, [null, 'same']);
    },
  );
}
