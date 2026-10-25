// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'package:chatloom/personal/ui/conversation_content_controller.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'conversation_test_support.dart';

class Source implements ContentSource {
  final Room room;
  final rows = <Event>[];
  bool fails = false;
  int remoteCalls = 0;
  Completer<List<Event>>? gate;
  ContentBatch batch = const ContentBatch([]);
  Source(this.room);
  @override
  Object get identity => (room.client, room.id);
  @override
  String get name => 'Fictional source';
  @override
  bool get available => true;
  @override
  String? get initialCursor => 'initial';
  @override
  Future<ContentBatch> local(int limit) async {
    if (fails) throw StateError('offline');
    if (gate != null) return ContentBatch(await gate!.future);
    return ContentBatch([
      ...rows.where((e) => e.status != EventStatus.synced),
      ...rows.where((e) => e.status == EventStatus.synced).take(limit),
    ], localComplete: rows.where((e) => e.status.isSynced).length <= limit);
  }

  @override
  Future<ContentBatch> older(String? cursor) async {
    remoteCalls++;
    if (fails) throw StateError('offline');
    return batch;
  }
}

class SparseDatabase implements DatabaseApi {
  late List<Event> events;
  final missing = {0, 2, 15, 79, 80, 159};
  bool failUser = false;
  @override
  Future<User?> getUser(String id, Room room) async {
    if (failUser) throw StateError("synthetic database failure");
    return null;
  }

  Event? insertOnRead;
  @override
  Future<Event?> getEventById(String id, Room room) async {
    if (insertOnRead != null) {
      events.insert(0, insertOnRead!);
      insertOnRead = null;
    }
    if (missing.contains(int.parse(id.substring(1)))) return null;
    return events.where((e) => e.eventId == id).firstOrNull;
  }

  @override
  Future<List<String>> getEventIdList(
    Room room, {
    int start = 0,
    int? limit,
    bool includeSending = false,
  }) async =>
      events.map((e) => e.eventId).take(limit ?? events.length).toList();
  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    int? limit,
    bool onlySending = false,
  }) async => events
      .skip(start)
      .take(limit ?? events.length)
      .where((e) => !missing.contains(int.parse(e.eventId.substring(1))))
      .toList();
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'SDK history failure releases loading and retries the same database boundary',
    () async {
      final db = SparseDatabase();
      final client = Client('failure fixture', database: db);
      final room = Room(
        id: '!failure:example.invalid',
        client: client,
        membership: Membership.join,
      );
      client.rooms.add(room);
      db.events = [
        for (var i = 0; i < 260; i++)
          Event(
            room: room,
            eventId: '\$$i',
            type: EventTypes.Message,
            content: {'msgtype': MessageTypes.Text, 'body': 'same'},
            senderId: '@fixture:example.invalid',
            originServerTs: DateTime.utc(2026),
          ),
      ];
      final first = await db.getEventList(room, limit: 80);
      final t = Timeline(
        room: room,
        chunk: TimelineChunk(events: first),
      );
      db.failUser = true;
      await expectLater(t.requestHistory(historyCount: 80), throwsStateError);
      expect(t.isRequestingHistory, isFalse);
      expect(t.events.length, first.length);
      db.failUser = false;
      db.insertOnRead = Event(
        room: room,
        eventId: r'$999',
        type: EventTypes.Message,
        content: {'msgtype': MessageTypes.Text, 'body': 'sync during read'},
        senderId: '@fixture:example.invalid',
        originServerTs: DateTime.utc(2026),
      );
      await t.requestHistory(historyCount: 80);
      expect(t.events.map((e) => e.eventId), containsAll([r'$81', r'$158']));
      t.cancelSubscriptions();
    },
  );
  test(
    'missing database rows never truncate the remaining synced ID range',
    () async {
      final db = SparseDatabase();
      final client = Client('sparse fixture', database: db);
      final room = Room(
        id: '!sparse:example.invalid',
        client: client,
        membership: Membership.join,
      );
      client.rooms.add(room);
      db.events = [
        for (var i = 0; i < 260; i++)
          Event(
            room: room,
            eventId: '\$$i',
            type: EventTypes.Message,
            senderId: '@fixture:example.invalid',
            originServerTs: DateTime.utc(2026),
            content: {'msgtype': MessageTypes.Text, 'body': 'same'},
          ),
      ];
      final c = ConversationContentController([
        MatrixContentSource(room),
      ], unlocked: () => true);
      await c.load();
      expect(c.localEnd, isFalse);
      expect(c.events.length, 76);
      for (var i = 0; i < 3; i++) {
        await c.load();
      }
      expect(c.events.length, 254);
      expect(c.localEnd, isTrue);
      c.dispose();
    },
  );
  test(
    'privacy epoch survives a lock-unlock round trip during await',
    () async {
      final source = Source(
        ConversationRoom(ConversationClient(), '!epoch:example.invalid'),
      )..gate = Completer<List<Event>>();
      var generation = 0;
      final c = ConversationContentController(
        [source],
        unlocked: () => true,
        privacyGeneration: () => generation,
      );
      final pending = c.load();
      generation += 2;
      source.gate!.complete([
        (source.room as ConversationRoom).message(r'$late', 'old'),
      ]);
      await pending;
      expect(c.events, isEmpty);
      c.dispose();
    },
  );
  test(
    'redaction removes loaded media without duplicate live sync records',
    () async {
      final source = Source(
        ConversationRoom(ConversationClient(), '!redaction:example.invalid'),
      );
      final e = (source.room as ConversationRoom).message(
        r'$media',
        'photo',
        content: {'msgtype': MessageTypes.Image},
      );
      source.rows.add(e);
      final c = ConversationContentController([source], unlocked: () => true);
      await c.load();
      c.accept(source, e);
      expect(c.events.length, 1);
      c.accept(
        source,
        Event(
          room: source.room,
          eventId: r'$redaction',
          type: EventTypes.Redaction,
          content: {'redacts': e.eventId},
          redacts: e.eventId,
          senderId: '@owner:example.invalid',
          originServerTs: DateTime.utc(2026),
        ),
      );
      expect(c.events.where(sharedMedia), isEmpty);
      c.dispose();
    },
  );
  test(
    'a redaction received before a pending local page cannot reappear',
    () async {
      final room = ConversationRoom(
        ConversationClient(),
        '!late-redaction:example.invalid',
      );
      final source = Source(room)..gate = Completer<List<Event>>();
      final event = room.message(
        r'$late-photo',
        'photo',
        content: {'msgtype': MessageTypes.Image},
      );
      final c = ConversationContentController([source], unlocked: () => true);
      final pending = c.load();
      c.accept(
        source,
        Event(
          room: room,
          eventId: r'$remove-late',
          type: EventTypes.Redaction,
          content: {'redacts': event.eventId},
          redacts: event.eventId,
          senderId: '@owner:example.invalid',
          originServerTs: DateTime.utc(2026),
        ),
      );
      source.gate!.complete([event]);
      await pending;
      expect(c.events.where(sharedMedia), isEmpty);
      c.dispose();
    },
  );
  test(
    'real SDK first-page SENDING is outside limit; prefix pagination keeps every synced event',
    () async {
      final raw = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
      final db = await MatrixSdkDatabase.init(
        'content-fixture',
        database: raw,
        sqfliteFactory: databaseFactoryFfi,
      );
      final client = Client('fixture', database: db);
      final room = Room(
        id: '!fixture:example.invalid',
        client: client,
        membership: Membership.join,
      );
      client.rooms.add(room);
      Future<void> store(String id, {bool sending = false}) =>
          db.storeEventUpdate(
            room.id,
            Event(
              room: room,
              eventId: id,
              type: EventTypes.Message,
              senderId: '@fixture:example.invalid',
              originServerTs: DateTime.utc(2026),
              content: {'msgtype': MessageTypes.Text, 'body': id},
              status: sending ? EventStatus.sending : EventStatus.synced,
            ),
            EventUpdateType.timeline,
            client,
          );
      for (var i = 0; i < 250; i++) {
        await store('\$event-$i');
      }
      await store('sending', sending: true);
      final first = await db.getEventList(room, limit: 80);
      expect(first.length, 81);
      expect(first.where((e) => e.status != EventStatus.synced), hasLength(1));
      // Old raw-page-length offset skips one synced record here.
      final oldSecond = await db.getEventList(
        room,
        start: first.length,
        limit: 80,
      );
      final expectedSecond = await db.getEventList(room, start: 80, limit: 80);
      expect(oldSecond.first.eventId, isNot(expectedSecond.first.eventId));
      final timeline = Timeline(
        room: room,
        chunk: TimelineChunk(events: first),
      );
      await timeline.requestHistory(historyCount: 80);
      expect(
        timeline.events.map((e) => e.eventId),
        contains(expectedSecond.first.eventId),
      );
      timeline.cancelSubscriptions();
      final controller = ConversationContentController([
        MatrixContentSource(room),
      ], unlocked: () => true);
      for (var i = 0; i < 4; i++) {
        await controller.load();
      }
      expect(controller.events.length, 251);
      expect(controller.localEnd, isTrue);
      controller.dispose();
      await db.close();
    },
  );
  test(
    'sync growth, more than 240 rows, redaction and sending retain unique source events',
    () async {
      final client = ConversationClient();
      final room = ConversationRoom(client, '!one:example.invalid');
      final source = Source(room);
      for (var i = 0; i < 260; i++) {
        source.rows.add(room.message('\$e$i', 'same text'));
      }
      source.rows.insert(
        0,
        room.message('sending', 'draft', status: EventStatus.sending),
      );
      final controller = ConversationContentController([
        source,
      ], unlocked: () => true);
      await controller.load();
      expect(controller.events.length, 81);
      source.rows.insert(0, room.message(r'$new-sync', 'new'));
      for (var i = 0; i < 3; i++) {
        await controller.load();
      }
      expect(controller.events.length, 262);
      expect(controller.events.map((e) => e.eventId).toSet(), hasLength(262));
      expect(source.remoteCalls, 0);
      controller.dispose();
    },
  );
  test(
    'one failed source does not block another; retry keeps results, identical IDs on accounts stay distinct',
    () async {
      final a = Source(
        ConversationRoom(ConversationClient(), '!same:example.invalid'),
      );
      final b = Source(
        ConversationRoom(
          ConversationClient('@other:example.invalid'),
          '!same:example.invalid',
        ),
      );
      a.fails = true;
      b.rows.add((b.room as ConversationRoom).message(r'$same', 'B'));
      final c = ConversationContentController([a, b], unlocked: () => true);
      await c.load();
      expect(c.events.single.body, 'B');
      expect(c.sources.first.error, isNotNull);
      a.fails = false;
      a.rows.add((a.room as ConversationRoom).message(r'$same', 'A'));
      await c.load();
      expect(c.events.length, 2);
      expect(c.sources.first.error, isNull);
      c.dispose();
    },
  );
  test(
    'empty matching pages and encrypted events do not signal EOF; cyclic token stops, EOF cannot restart',
    () async {
      final room = ConversationRoom(
        ConversationClient(),
        '!one:example.invalid',
      );
      final source = Source(room);
      final encrypted = Event(
        room: room,
        eventId: r'$encrypted',
        type: EventTypes.Encrypted,
        content: {},
        originServerTs: DateTime.utc(2026),
        senderId: '@fixture:example.invalid',
      );
      source.batch = ContentBatch([encrypted], next: 'next');
      final c = ConversationContentController([source], unlocked: () => true);
      await c.load(remote: true);
      expect(c.encrypted, 1);
      expect(c.remoteEnd, isFalse);
      source.batch = const ContentBatch([], next: 'initial');
      await c.load(remote: true); // A -> B -> A must be detected.
      expect(c.sources.single.error, isNotNull);
      source.batch = const ContentBatch([]);
      await c.load(remote: true);
      expect(c.remoteEnd, isTrue);
      final count = source.remoteCalls;
      await c.load(remote: true);
      expect(source.remoteCalls, count);
      expect(c.encrypted, 1);
      c.dispose();
    },
  );
  test('dispose and lock invalidate pending loads and taps coalesce', () async {
    final room = ConversationRoom(ConversationClient(), '!one:example.invalid');
    final source = Source(room)..gate = Completer<List<Event>>();
    var unlocked = true;
    final c = ConversationContentController([source], unlocked: () => unlocked);
    final pending = c.load();
    await c.load();
    unlocked = false;
    source.gate!.complete([room.message(r'$late', 'private')]);
    await pending;
    expect(c.events, isEmpty);
    unlocked = true;
    expect(c.events, isEmpty);
    c.dispose();
    final other = Source(room)..gate = Completer<List<Event>>();
    final d = ConversationContentController([other], unlocked: () => true);
    final pendingDispose = d.load();
    d.dispose();
    other.gate!.complete([]);
    await pendingDispose;
  });
  test('classification keeps audio in files and all distinct formatted URLs', () {
    final room = ConversationRoom(ConversationClient(), '!one:example.invalid');
    final event = room.message(
      r'$links',
      'See https://example.org/a, https://example.org/a and https://example.org/b).',
      content: {
        'msgtype': MessageTypes.Text,
        'body':
            'See https://example.org/a, https://example.org/a and https://example.org/b).',
        'formatted_body':
            '<a href="https://example.org/c?a=1&amp;b=2">title</a> https://example.org/d https://example.org/e',
      },
    );
    expect(sharedLinks(event), [
      'https://example.org/a',
      'https://example.org/b',
      'https://example.org/c?a=1&b=2',
      'https://example.org/d',
      'https://example.org/e',
    ]);
    final audio = room.message(
      r'$audio',
      'voice',
      content: {'msgtype': MessageTypes.Audio},
    );
    expect(sharedFile(audio), isTrue);
    expect(sharedMedia(audio), isFalse);
    expect(sharedMessage(audio), isFalse);
  });
  test('voice notes and rounds are messages, not files or media', () {
    final room = ConversationRoom(ConversationClient(), '!one:example.invalid');
    final voice = room.message(
      r'$voice',
      'Voice message',
      content: {
        'msgtype': MessageTypes.Audio,
        'body': 'Voice message',
        'org.matrix.msc3245.voice': <String, dynamic>{},
      },
    );
    final round = room.message(
      r'$round',
      'Video message',
      outgoing: true,
      content: {
        'msgtype': MessageTypes.Video,
        'body': 'Video message',
        'info': {'fi.mau.telegram.round_message': true, 'duration': 7000},
      },
    );
    final video = room.message(
      r'$video',
      'clip.mp4',
      content: {'msgtype': MessageTypes.Video, 'body': 'clip.mp4'},
    );
    expect(
      [sharedVoice(voice), sharedFile(voice), sharedMedia(voice)],
      [true, false, false],
    );
    expect(
      [sharedRound(round), sharedMedia(round), sharedFile(round)],
      [true, false, false],
    );
    expect([sharedMessage(voice), sharedMessage(round)], [true, true]);
    expect([sharedMedia(video), sharedMessage(video)], [true, false]);
    expect(sharedSenderMatches(round, SharedSender.me), isTrue);
    expect(sharedSenderMatches(round, SharedSender.others), isFalse);
    expect(sharedSenderMatches(voice, SharedSender.others), isTrue);
    expect(sharedSenderMatches(voice, SharedSender.everyone), isTrue);
  });
  test('mentions, permalinks and reply fallbacks are not shared links', () {
    final room = ConversationRoom(ConversationClient(), '!one:example.invalid');
    final reply = room.message(
      r'$reply',
      'x',
      content: {
        'msgtype': MessageTypes.Text,
        'body':
            '> <@anna:example.invalid> see https://quoted.example.org/q\n\nHi Anna, https://example.org/new',
        'formatted_body':
            '<mx-reply><blockquote><a href="https://matrix.to/#/!one:example.invalid/\$orig">In reply to</a> '
            '<a href="https://matrix.to/#/@anna:example.invalid">@anna</a> https://quoted.example.org/q</blockquote></mx-reply>'
            'Hi <a href="https://matrix.to/#/@anna:example.invalid">Anna</a>, https://example.org/new',
      },
    );
    expect(sharedLinks(reply), ['https://example.org/new']);
    // Cached per event object: the same list on every projection rebuild.
    expect(identical(sharedLinks(reply), sharedLinks(reply)), isTrue);
  });
  test('local pages grow so sparse media needs few reads', () async {
    final room = ConversationRoom(ConversationClient(), '!one:example.invalid');
    final source = Source(room);
    for (var i = 0; i < 3000; i++) {
      source.rows.add(room.message('\$g$i', 'text'));
    }
    final c = ConversationContentController([source], unlocked: () => true);
    final limits = <int>[];
    for (var i = 0; i < 5; i++) {
      await c.load();
      limits.add(c.sources.single.localLimit);
    }
    expect(limits, [80, 160, 320, 640, 1280]);
    final first = c.events;
    expect(identical(first, c.events), isTrue);
    c.accept(source, room.message(r'$late', 'late', minute: 59));
    expect(identical(first, c.events), isFalse);
    c.dispose();
  });
}
