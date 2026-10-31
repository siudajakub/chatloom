// SPDX-License-Identifier: AGPL-3.0-or-later
// Where this device last showed each chat (incognito reopen position):
// bounded, coalesced, device-local. Fictional offline fixtures; no account,
// no network.

import 'package:chatloom/personal/seen_positions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

import '../notion/conversation_test_support.dart';

/// In-memory stand-in for the encrypted private store.
class _Store implements SeenPositionsStorage {
  Map<String, dynamic>? value;
  int writes = 0;
  Object? failure;
  @override
  Future<Map<String, dynamic>?> read() async {
    if (failure != null) throw failure!;
    return value;
  }

  @override
  Future<void> write(Map<String, dynamic> value) async {
    if (failure != null) throw failure!;
    writes++;
    this.value = value;
  }
}

Room _room(Client client, String id, {String fullyRead = r'$read'}) =>
    Room(id: id, client: client, membership: Membership.join)
      ..roomAccountData['m.fully_read'] = BasicEvent(
        type: 'm.fully_read',
        content: {'event_id': fullyRead},
      );

Event _event(Room room, String id, int minute) => Event(
  room: room,
  eventId: id,
  type: EventTypes.Message,
  senderId: '@anna:example.invalid',
  originServerTs: DateTime.utc(2026, 10, 16, 16, minute),
  content: {'msgtype': MessageTypes.Text, 'body': 'Fictional'},
);

void main() {
  late ConversationClient client;
  late _Store store;
  late SeenPositions seen;

  setUp(() {
    client = ConversationClient();
    store = _Store();
    seen = SeenPositions(
      storageFor: (_) => store,
      writeDelay: const Duration(hours: 1),
    );
  });

  void see(Room room, Event event) =>
      seen.record(room, event.eventId, originServerTs: event.originServerTs);

  test('opens at what is new to this device, never past the server', () {
    final room = _room(client, '!a:example.invalid');
    final shown = _event(room, r'$shown', 10);
    room.lastEvent = shown;
    // Nothing recorded: the server's marker.
    expect(seen.openMarker(room, r'$read'), r'$read');
    see(room, shown);
    // The newest message was on screen: nothing to position at.
    expect(seen.openMarker(room, r'$read'), isEmpty);
    // A newer message (same second as a bridged one is still new).
    room.lastEvent = _event(room, r'$newer', 10);
    expect(seen.openMarker(room, r'$read'), r'$shown');
    room.lastEvent = _event(room, r'$newest', 12);
    expect(seen.openMarker(room, r'$read'), r'$shown');
    // Another app moved the read marker since: the server knows better.
    room.roomAccountData['m.fully_read'] = BasicEvent(
      type: 'm.fully_read',
      content: {'event_id': r'$elsewhere'},
    );
    expect(seen.openMarker(room, r'$elsewhere'), r'$elsewhere');
  });

  test('writes are coalesced and survive a restart', () async {
    seen.load(client);
    await pumpEventQueue();
    final room = _room(client, '!a:example.invalid');
    for (var i = 0; i < 20; i++) {
      see(room, _event(room, '\$m$i', i));
    }
    // Same position again: no change at all.
    see(room, _event(room, r'$m19', 19));
    expect(store.writes, 0);
    seen.flush(client);
    await pumpEventQueue();
    expect(store.writes, 1);
    seen.flush(client);
    await pumpEventQueue();
    expect(store.writes, 1);

    final restarted = SeenPositions(storageFor: (_) => store);
    restarted.load(client);
    await pumpEventQueue();
    room.lastEvent = _event(room, r'$m19', 19);
    expect(restarted.openMarker(room, r'$read'), isEmpty);
    room.lastEvent = _event(room, r'$m20', 20);
    expect(restarted.openMarker(room, r'$read'), r'$m19');
  });

  test('the store writes itself after the delay', () async {
    final delayed = SeenPositions(
      storageFor: (_) => store,
      writeDelay: const Duration(milliseconds: 50),
    )..load(client);
    await pumpEventQueue();
    final room = _room(client, '!a:example.invalid');
    delayed
      ..record(room, r'$one')
      ..record(room, r'$two');
    await pumpEventQueue();
    expect(store.writes, 0);
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(store.writes, 1);
    expect((store.value!['rooms'] as List).single['e'], r'$two');
  });

  test('keeps the most recently seen chats up to the cap', () async {
    seen.load(client);
    await pumpEventQueue();
    final rooms = [
      for (var i = 0; i < SeenPositions.capacity + 5; i++)
        _room(client, '!r$i:example.invalid'),
    ];
    for (final room in rooms) {
      seen.record(room, r'$x', originServerTs: DateTime.utc(2026));
    }
    // Seen again: the oldest chat becomes the newest.
    seen.record(rooms[5], r'$y', originServerTs: DateTime.utc(2026));
    seen.flush(client);
    await pumpEventQueue();
    final stored = (store.value!['rooms'] as List).cast<Map>();
    expect(stored, hasLength(SeenPositions.capacity));
    expect(stored.first['r'], '!r6:example.invalid');
    expect(stored.last['r'], '!r5:example.invalid');
    expect(stored.any((e) => e['r'] == '!r0:example.invalid'), isFalse);
  });

  test('an unopened store keeps positions in memory, writes nothing', () async {
    store
      ..value = {
        'v': 1,
        'rooms': [
          {'r': '!b:example.invalid', 'e': r'$old', 'f': r'$read', 't': 0},
        ],
      }
      ..failure = StateError('Encrypted storage is not open');
    seen.load(client);
    await pumpEventQueue();
    final room = _room(client, '!a:example.invalid');
    room.lastEvent = _event(room, r'$shown', 10);
    see(room, room.lastEvent!);
    expect(seen.openMarker(room, r'$read'), isEmpty);
    seen.flush(client);
    await pumpEventQueue();
    expect(store.writes, 0);

    // Opened later: the stored record is merged under this session's.
    store.failure = null;
    seen.load(client);
    await pumpEventQueue();
    expect(store.writes, 1);
    final stored = (store.value!['rooms'] as List).cast<Map>();
    expect(stored.map((e) => e['r']), [
      '!b:example.invalid',
      '!a:example.invalid',
    ]);
  });

  test('an account without a store is memory only', () {
    final memory = SeenPositions(storageFor: (_) => null);
    final room = _room(client, '!a:example.invalid');
    room.lastEvent = _event(room, r'$shown', 10);
    memory.record(
      room,
      r'$shown',
      originServerTs: room.lastEvent!.originServerTs,
    );
    memory.flush(client);
    expect(memory.openMarker(room, r'$read'), isEmpty);
    // Local (unsent) events are never a position.
    memory.record(room, 'local-txn');
    expect(memory.openMarker(room, r'$read'), isEmpty);
  });
}
