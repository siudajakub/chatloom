// SPDX-License-Identifier: AGPL-3.0-or-later
// The worker's own Matrix sync as an automatic-transcription source.
// SDK objects only; no homeserver, database or provider.
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/matrix_sources.dart';
import 'package:personal_worker/src/matrix_transport.dart';
import 'package:test/test.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('unexpected database access');
}

/// Serves the SDK-stored (later decrypted) copy of an event.
class _Room extends Room {
  final stored = <String, Event>{};
  _Room(String id, Client client) : super(id: id, client: client);
  @override
  Future<Event?> getEventById(String eventID) async => stored[eventID];
}

void main() {
  late Client client;
  late _Room room;
  late MatrixLiveSources feed;
  var now = DateTime.utc(2026, 10, 19, 12);

  Event message(
    String id,
    Map<String, dynamic> content, {
    String sender = '@anna:example.invalid',
    String type = EventTypes.Message,
    Room? inRoom,
  }) => Event(
    room: inRoom ?? room,
    eventId: id,
    type: type,
    senderId: sender,
    originServerTs: now,
    content: content,
  );

  Map<String, dynamic> video({Map<String, dynamic> info = const {}}) => {
    'msgtype': 'm.video',
    'body': 'clip.mp4',
    'info': {'mimetype': 'video/mp4', 'duration': 42000, ...info},
  };

  setUp(() {
    now = DateTime.utc(2026, 10, 19, 12);
    client = Client('live feed fixture', database: _UnusedDatabase());
    room = _Room('!cloud:beeper.com', client);
    room.setState(
      StrippedStateEvent(
        type: 'm.bridge',
        content: {
          'protocol': {'id': 'whatsapp'},
        },
        senderId: '@bridge:example.invalid',
        stateKey: 'whatsapp',
      ),
    );
    client.rooms.add(room);
    feed = MatrixLiveSources(
      client,
      journalRoomId: '!journal:example.invalid',
      excludedRoom: (id) => id == '!excluded:beeper.local',
      clock: () => now,
    );
  });

  test('incoming speech media becomes an identifier-only item', () async {
    feed.observe(message(r'$clip', video()));
    feed.observe(
      message(r'$voice', {
        'msgtype': 'm.audio',
        'body': 'Voice message',
        'org.matrix.msc3245.voice': <String, dynamic>{},
        'info': {'duration': 3000},
      }),
    );
    feed.observe(
      message(r'$file', {
        'msgtype': 'm.file',
        'body': 'memo.m4a',
        'info': {'mimetype': 'audio/mp4'},
      }),
    );
    final items = await feed.drain();
    expect(items.map((i) => (i.eventId, i.kind)), [
      (r'$clip', AutoTranscriptionKind.video),
      (r'$voice', AutoTranscriptionKind.voice),
      (r'$file', AutoTranscriptionKind.audio),
    ]);
    expect(items.first.network, 'whatsapp');
    expect(items.first.durationMs, 42000);
    expect(items.first.timestamp, now);
    expect(items.first.roomId, room.id);
    expect(await feed.drain(), isEmpty, reason: 'drained once');
    // The same event delivered again (sync retry) is not reported twice.
    feed.observe(message(r'$clip', video()));
    expect(await feed.drain(), isEmpty);
  });

  test('a video shared from Instagram is reported as a reel', () async {
    feed.observe(
      message(r'$reel', {
        ...video(),
        'external_url': 'https://www.instagram.com/reel/Cfixture/',
      }),
    );
    feed.observe(message(r'$clip', video()));
    final items = await feed.drain();
    expect(items.map((i) => (i.eventId, i.kind)), [
      (r'$reel', AutoTranscriptionKind.reel),
      (r'$clip', AutoTranscriptionKind.video),
    ]);
    // On demand a reel is transcribed like any other video.
    expect(
      MatrixFeatureTransport.transcriptionSourceRejection(
        message(r'$reel-request', {
          ...video(info: {'size': 900000}),
          'external_url': 'https://www.instagram.com/reel/Cfixture/',
        }),
      ),
      isNull,
    );
  });

  test('silent loops, text, edits, journal, local and disappearing chats '
      'are ignored', () async {
    feed.observe(message(r'$gif', video(info: {'fi.mau.gif': true})));
    feed.observe(message(r'$text', {'msgtype': 'm.text', 'body': 'hi'}));
    feed.observe(
      message(r'$edit', {
        ...video(),
        'm.relates_to': {'rel_type': 'm.replace', 'event_id': r'$clip'},
      }),
    );
    feed.observe(
      message(r'$protected', {...video(), 'protected_content': true}),
    );
    feed.observe(
      message(
        r'$journal',
        video(),
        inRoom: Room(id: '!journal:example.invalid', client: client),
      ),
    );
    feed.observe(
      message(
        r'$excluded',
        video(),
        inRoom: Room(id: '!excluded:beeper.local', client: client),
      ),
    );
    final left = Room(
      id: '!left:beeper.com',
      client: client,
      membership: Membership.leave,
    );
    feed.observe(message(r'$left', video(), inRoom: left));
    expect(await feed.drain(), isEmpty);
    room.setState(
      StrippedStateEvent(
        type: beeperDisappearingTimerKey,
        content: {'type': 'after_read', 'timer': 60000},
        senderId: '@bridge:example.invalid',
        stateKey: '',
      ),
    );
    feed.observe(message(r'$vanishing', video()));
    expect(await feed.drain(), isEmpty);
  });

  test('own messages are never reported', () async {
    client.setUserId('@self:example.invalid');
    feed.observe(message(r'$own', video(), sender: '@self:example.invalid'));
    expect(await feed.drain(), isEmpty);
  });

  test('an event decrypted later is picked up from the SDK store', () async {
    feed.observe(
      message(r'$enc', {
        'algorithm': 'm.megolm.v1.aes-sha2',
      }, type: EventTypes.Encrypted),
    );
    expect(await feed.drain(), isEmpty);
    room.stored[r'$enc'] = message(r'$enc', video());
    // Re-reads are throttled.
    expect(await feed.drain(), isEmpty);
    now = now.add(MatrixLiveSources.pendingKeysRetry);
    final items = await feed.drain();
    expect(items.single.eventId, r'$enc');
    expect(items.single.kind, AutoTranscriptionKind.video);
  });

  test('a stored copy that is still encrypted is decrypted with keys that '
      'arrived later (key backup, forwarded keys)', () async {
    final decrypted = <String>[];
    feed = MatrixLiveSources(
      client,
      journalRoomId: '!journal:example.invalid',
      clock: () => now,
      decrypt: (event) async {
        decrypted.add(event.eventId);
        return message(event.eventId, video());
      },
    );
    final encrypted = message(r'$backup', {
      'algorithm': 'm.megolm.v1.aes-sha2',
    }, type: EventTypes.Encrypted);
    feed.observe(encrypted);
    expect(await feed.drain(), isEmpty);
    // The SDK store still holds the encrypted copy: only the feed's own
    // decryption with the now-present key finds the video.
    room.stored[r'$backup'] = encrypted;
    now = now.add(MatrixLiveSources.pendingKeysRetry);
    final items = await feed.drain();
    expect(decrypted, [r'$backup']);
    expect(items.single.eventId, r'$backup');
    expect(items.single.kind, AutoTranscriptionKind.video);
  });

  test(
    'an inactive feed drops what it receives and wakes on new items',
    () async {
      final wake = feed.wakeup;
      feed.observe(message(r'$first', video()));
      await wake.timeout(const Duration(seconds: 1));
      feed.active = false;
      expect(await feed.drain(), isEmpty);
      feed.observe(message(r'$while-off', video()));
      feed.active = true;
      expect(await feed.drain(), isEmpty);
    },
  );
}
