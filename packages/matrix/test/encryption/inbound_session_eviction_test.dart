// SPDX-FileCopyrightText: 2026 Personal Chat contributors
//
// SPDX-License-Identifier: AGPL-3.0-or-later

import 'dart:convert';

import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:test/test.dart';
import 'package:vodozemac/vodozemac.dart' as vod;

import '../fake_client.dart';

/// ChatLoom: the key manager keeps a bounded number of inbound group sessions
/// in memory. Evicted sessions must decrypt, keep their replay indexes and
/// compare with incoming keys exactly as if they had stayed in memory.
void main() {
  group('Inbound group session eviction', tags: 'olm', () {
    Logs().level = Level.error;
    late Client client;
    late int previousMax;
    const roomId = '!evict:example.com';
    const fillerRoomId = '!filler:example.com';

    KeyManager keys() => client.encryption!.keyManager;

    setUpAll(() async {
      await vod.init(wasmPath: './pkg/', libraryPath: './rust/target/debug/');
      client = await getClient();
    });

    setUp(() {
      previousMax = KeyManager.maxCachedInboundGroupSessions;
      KeyManager.maxCachedInboundGroupSessions = 4;
    });

    tearDown(() => KeyManager.maxCachedInboundGroupSessions = previousMax);

    Map<String, dynamic> roomKey(String room, String sessionId, String key) => {
      'algorithm': AlgorithmTypes.megolmV1AesSha2,
      'room_id': room,
      'session_id': sessionId,
      'session_key': key,
    };

    Future<void> drainUploadQueue() async {
      while (true) {
        final queued = await client.database.getInboundGroupSessionsToUpload();
        if (queued.isEmpty) return;
        for (final s in queued) {
          await client.database.markInboundGroupSessionAsUploaded(
            s.roomId,
            s.sessionId,
          );
        }
      }
    }

    /// Stores [count] unrelated sessions, evicting older ones.
    Future<void> fill(int count) async {
      for (var i = 0; i < count; i++) {
        final gs = vod.GroupSession();
        await keys().setInboundGroupSession(
          fillerRoomId,
          gs.sessionId,
          client.identityKey,
          roomKey(fillerRoomId, gs.sessionId, gs.sessionKey),
        );
      }
      await drainUploadQueue();
    }

    String ciphertext(vod.GroupSession gs, String body) => gs.encrypt(
      json.encode({
        'type': EventTypes.Message,
        'room_id': roomId,
        'content': {'msgtype': MessageTypes.Text, 'body': body},
      }),
    );

    Event encrypted(
      Room room,
      String sessionId,
      String ciphertext,
      String eventId,
    ) => Event(
      senderId: '@alice:example.com',
      type: EventTypes.Encrypted,
      room: room,
      eventId: eventId,
      originServerTs: DateTime.fromMillisecondsSinceEpoch(1700000000000),
      content: {
        'algorithm': AlgorithmTypes.megolmV1AesSha2,
        'ciphertext': ciphertext,
        'device_id': 'ALICEDEVICE',
        'sender_key': client.identityKey,
        'session_id': sessionId,
      },
    );

    Future<Map<String, dynamic>> storedIndexes(String sessionId) async {
      final stored = await client.database.getInboundGroupSession(
        roomId,
        sessionId,
      );
      return json.decode(stored!.indexes) as Map<String, dynamic>;
    }

    Future<void> waitForStoredIndex(String sessionId, String index) async {
      for (var i = 0; i < 400; i++) {
        if ((await storedIndexes(sessionId)).containsKey(index)) return;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      fail('replay index $index was never stored');
    }

    test('evicted sessions decrypt again from the database', () async {
      final room = Room(id: roomId, client: client);
      final events = <Event>[];
      for (var i = 0; i < 12; i++) {
        final gs = vod.GroupSession();
        await keys().setInboundGroupSession(
          roomId,
          gs.sessionId,
          client.identityKey,
          roomKey(roomId, gs.sessionId, gs.sessionKey),
        );
        events.add(
          encrypted(room, gs.sessionId, ciphertext(gs, 'msg $i'), '\$e$i'),
        );
      }
      expect(keys().debugCachedInboundGroupSessions, lessThanOrEqualTo(4));
      expect(
        keys().getInboundGroupSession(
          roomId,
          events.first.content['session_id'] as String,
        ),
        isNull,
      );
      for (var i = 0; i < events.length; i++) {
        final decrypted = await client.encryption!.decryptRoomEvent(events[i]);
        expect(decrypted.type, EventTypes.Message);
        expect(decrypted.body, 'msg $i');
      }
      // Sessions stay held (above the bound) until their replay-index writes
      // land; after that the next store evicts them again.
      for (final event in events) {
        await waitForStoredIndex(
          event.content['session_id'] as String,
          'key-0',
        );
      }
      await fill(1);
      expect(keys().debugCachedInboundGroupSessions, lessThanOrEqualTo(4));
    });

    test('concurrent decryption never loses a session it loaded', () async {
      final room = Room(id: roomId, client: client);
      final events = <Event>[];
      for (var i = 0; i < 12; i++) {
        final gs = vod.GroupSession();
        await keys().setInboundGroupSession(
          roomId,
          gs.sessionId,
          client.identityKey,
          roomKey(roomId, gs.sessionId, gs.sessionKey),
        );
        events.add(
          encrypted(room, gs.sessionId, ciphertext(gs, 'c$i'), '\$c$i'),
        );
      }
      await fill(10);
      // All twelve reload at once, three times the bound, and all decrypt.
      final decrypted = await Future.wait(
        events.map(client.encryption!.decryptRoomEvent),
      );
      for (var i = 0; i < events.length; i++) {
        expect(decrypted[i].type, EventTypes.Message);
        expect(decrypted[i].body, 'c$i');
      }
      await drainUploadQueue();
    });

    test('replay indexes survive eviction', () async {
      final room = Room(id: roomId, client: client);
      final gs = vod.GroupSession();
      final sessionId = gs.sessionId;
      await keys().setInboundGroupSession(
        roomId,
        sessionId,
        client.identityKey,
        roomKey(roomId, sessionId, gs.sessionKey),
      );
      final payload = ciphertext(gs, 'hello');
      final first = encrypted(room, sessionId, payload, '\$first');

      expect((await client.encryption!.decryptRoomEvent(first)).body, 'hello');
      // The index write is still pending: storing other sessions now must
      // not drop this one from memory.
      final stores = <Future<void>>[];
      for (var i = 0; i < 10; i++) {
        final other = vod.GroupSession();
        stores.add(
          keys().setInboundGroupSession(
            fillerRoomId,
            other.sessionId,
            client.identityKey,
            roomKey(fillerRoomId, other.sessionId, other.sessionKey),
          ),
        );
      }
      expect(keys().getInboundGroupSession(roomId, sessionId), isNotNull);
      await Future.wait(stores);
      await waitForStoredIndex(sessionId, 'key-0');

      await fill(10);
      expect(keys().getInboundGroupSession(roomId, sessionId), isNull);
      // The same event still decrypts after a reload.
      expect((await client.encryption!.decryptRoomEvent(first)).body, 'hello');

      await fill(10);
      expect(keys().getInboundGroupSession(roomId, sessionId), isNull);
      // A different event reusing that message index is a replay.
      final replay = await client.encryption!.decryptRoomEvent(
        encrypted(room, sessionId, payload, '\$replay'),
      );
      expect(replay.type, EventTypes.Encrypted);
      expect(replay.content['body'], DecryptException.channelCorrupted);
    });

    test(
      'a duplicate key for an evicted session keeps the stored copy',
      () async {
        final room = Room(id: roomId, client: client);
        final gs = vod.GroupSession();
        final sessionId = gs.sessionId;
        final key = roomKey(roomId, sessionId, gs.sessionKey);
        await keys().setInboundGroupSession(
          roomId,
          sessionId,
          client.identityKey,
          Map.of(key),
        );
        final event = encrypted(room, sessionId, ciphertext(gs, 'hi'), '\$dup');
        expect((await client.encryption!.decryptRoomEvent(event)).body, 'hi');
        await waitForStoredIndex(sessionId, 'key-0');
        await drainUploadQueue();

        await fill(10);
        expect(keys().getInboundGroupSession(roomId, sessionId), isNull);

        // Upstream would compare with the in-memory session and keep it; it
        // must not replace the stored one (resetting indexes, queueing upload).
        await keys().setInboundGroupSession(
          roomId,
          sessionId,
          client.identityKey,
          Map.of(key),
        );
        expect(await storedIndexes(sessionId), contains('key-0'));
        final queued = await client.database.getInboundGroupSessionsToUpload();
        expect(queued.map((s) => s.sessionId), isNot(contains(sessionId)));
      },
    );

    test('incoming keys for evicted sessions compare by first index', () async {
      final gs = vod.GroupSession();
      final sessionId = gs.sessionId;
      final inbound = vod.InboundGroupSession(gs.sessionKey);
      Map<String, dynamic> forwarded(int index) => {
        ...roomKey(roomId, sessionId, inbound.exportAt(index)!),
        'forwarding_curve25519_key_chain': <String>[],
      };
      Future<int?> firstIndex() async => (await keys().loadInboundGroupSession(
        roomId,
        sessionId,
      ))?.inboundGroupSession?.firstKnownIndex;

      await keys().setInboundGroupSession(
        roomId,
        sessionId,
        client.identityKey,
        forwarded(1),
        forwarded: true,
      );
      await fill(10);
      // A worse key does not replace the evicted (stored) session...
      await keys().setInboundGroupSession(
        roomId,
        sessionId,
        client.identityKey,
        forwarded(2),
        forwarded: true,
      );
      expect(await firstIndex(), 1);

      await fill(10);
      // ...a better one does.
      await keys().setInboundGroupSession(
        roomId,
        sessionId,
        client.identityKey,
        forwarded(0),
        forwarded: true,
      );
      expect(await firstIndex(), 0);
      await drainUploadQueue();
    });

    test(
      'evicting our copy of an outbound session does not rotate it',
      () async {
        const sendRoomId = '!726s6s6q:example.com';
        final sess = await keys().createOutboundGroupSession(sendRoomId);
        final sessionId = sess.outboundGroupSession!.sessionId;

        await fill(10);
        expect(keys().getInboundGroupSession(sendRoomId, sessionId), isNull);

        expect(
          await keys().clearOrUseOutboundGroupSession(sendRoomId),
          isFalse,
        );
        expect(
          keys()
              .getOutboundGroupSession(sendRoomId)
              ?.outboundGroupSession
              ?.sessionId,
          sessionId,
        );
        final inbound = keys().getInboundGroupSession(sendRoomId, sessionId);
        expect(inbound, isNotNull);
        expect(inbound!.allowedAtIndex, isNotEmpty);
        keys().clearOutboundGroupSessions();
        await drainUploadQueue();
      },
    );

    test('dispose client', () async {
      await client.dispose(closeDatabase: true);
    });
  });
}
