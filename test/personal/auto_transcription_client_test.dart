// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline: in-memory private store, fixture rooms, no journal or network.
// Every test must finish in seconds; never wait on real storage from a
// fake-async widget test.
@Timeout(Duration(seconds: 60))
library;

import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/storage/personal_store.dart';
import 'package:chatloom/personal/ui/chat_preferences_page.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/personal/ui/transcription_settings.dart';
import 'package:chatloom/personal/worker_readiness.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

class _Store implements PersonalStore {
  final records = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, Map<String, dynamic>>> readPrefix(String prefix) async => {
    for (final entry in records.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };
  @override
  Future<Map<String, dynamic>?> get(String key) async => records[key];
  @override
  Future<void> put(String key, Map<String, dynamic> value) async =>
      records[key] = value;
  @override
  Future<void> delete(String key) async => records.remove(key);
  @override
  Future<void> close() async {}
}

/// Stored room state the SDK reads when a room is post-loaded.
class _StateDatabase extends ConversationDatabase {
  final stored = <String, List<Event>>{};
  int reads = 0;
  @override
  Future<List<Event>> getUnimportantRoomEventStatesForRoom(
    List<String> events,
    Room room,
  ) async {
    reads++;
    return stored[room.id] ?? const [];
  }
}

class _StateClient extends Client {
  _StateClient(_StateDatabase database)
    : super('offline state fixture', database: database);
  @override
  String get userID => '@owner:example.invalid';
}

/// Real replica and policy logic; only journal readiness is simulated.
class _Personal extends PersonalClient {
  _Personal(super.client, _Store store)
    : super.forTesting(openStore: () async => store);
  bool fakeReady = true;
  bool fakeWorkerOnline = true;
  int notifications = 0;
  @override
  Future<void> load() async {}
  @override
  bool get ready => fakeReady;
  @override
  bool get workerOnline => fakeWorkerOnline;
  @override
  void notifyListeners() {
    notifications++;
    super.notifyListeners();
  }

  Iterable<PersonalOperation> get requests =>
      pending.values.where((op) => op.kind == 'transcript.request');
}

Event voice(
  Room room,
  String id, {
  Duration age = const Duration(seconds: 20),
  bool outgoing = false,
  bool marker = true,
  String? transactionId,
}) => Event(
  room: room,
  eventId: id,
  type: EventTypes.Message,
  senderId: outgoing ? room.client.userID! : '@anna:example.invalid',
  originServerTs: DateTime.now().subtract(age),
  // The sending device's remote echo carries its transaction id.
  unsigned: transactionId == null ? null : {'transaction_id': transactionId},
  content: {
    'msgtype': MessageTypes.Audio,
    'body': 'Voice message',
    'url': 'mxc://example.invalid/voice',
    'info': {'duration': 12000, 'mimetype': 'audio/ogg'},
    if (marker) 'org.matrix.msc3245.voice': <String, dynamic>{},
  },
);

Event round(Room room, String id, {Map<String, dynamic> extra = const {}}) =>
    Event(
      room: room,
      eventId: id,
      type: EventTypes.Message,
      senderId: '@anna:example.invalid',
      originServerTs: DateTime.now(),
      content: {
        'msgtype': 'm.video',
        'body': 'Round',
        'url': 'mxc://example.invalid/round',
        'info': {
          'mimetype': 'video/mp4',
          'w': 384,
          'h': 384,
          'duration': 9000,
          roundMessageMarker: true,
          ...extra,
        },
      },
    );

Event video(
  Room room,
  String id, {
  Map<String, dynamic> info = const {},
  Duration age = const Duration(seconds: 20),
}) => Event(
  room: room,
  eventId: id,
  type: EventTypes.Message,
  senderId: '@anna:example.invalid',
  originServerTs: DateTime.now().subtract(age),
  content: {
    'msgtype': 'm.video',
    'body': 'clip.mp4',
    'url': 'mxc://example.invalid/clip',
    'info': {'mimetype': 'video/mp4', 'duration': 30000, ...info},
  },
);

/// A reel shared from Instagram, as mautrix-meta delivers it: the post's own
/// video with the post's link as `external_url` (see personal_core).
Event reel(Room room, String id) => Event(
  room: room,
  eventId: id,
  type: EventTypes.Message,
  senderId: '@anna:example.invalid',
  originServerTs: DateTime.now().subtract(const Duration(seconds: 20)),
  content: {
    'msgtype': 'm.video',
    'body': 'Caption of the shared post',
    'url': 'mxc://example.invalid/reel',
    'info': {'mimetype': 'video/mp4', 'duration': 30000},
    'external_url': 'https://www.instagram.com/reel/Cfixture/',
  },
);

Future<void> flushTimers() =>
    Future<void>.delayed(const Duration(milliseconds: 20));

String baselineKey(Client client) =>
    'account:${client.userID}:autoTranscriptionBaseline';

WorkerReadiness heartbeat(String? auto, {int? media, bool? live}) =>
    WorkerReadiness(
      receivedAt: DateTime.now(),
      autoTranscription: auto,
      transcriptionMedia: media,
      autoTranscriptionLive: live,
    );

void main() {
  late ConversationClient client;
  late ConversationRoom cloud;
  late ConversationRoom local;
  late _Store store;
  late _Personal personal;

  setUp(() async {
    client = ConversationClient();
    cloud = ConversationRoom(client, '!cloud:example.invalid');
    local = ConversationRoom(
      client,
      '!telegram:beeper.local',
      network: 'telegram',
    );
    store = _Store();
    // This device first saw the default policy with a scanning worker an
    // hour ago (see the baseline tests below).
    store.records[baselineKey(client)] = {
      'since': DateTime.now()
          .subtract(const Duration(hours: 1))
          .toUtc()
          .toIso8601String(),
    };
    personal = _Personal(client, store);
    personal.workerReadiness = heartbeat('scan');
    await personal.loadLocal();
    await personal.loadAutoTranscriptionBaseline();
  });
  tearDown(() {
    personal.fakeReady = false;
    personal.cancelAutoTranscriptionTimers();
  });

  test(
    'policy defaults to automatic and round-trips through metadata',
    () async {
      expect(personal.transcriptionPolicy.auto, isTrue);
      expect(personal.transcriptionDefaultLanguage, isNull);
      await personal.setTranscriptionPolicy(
        TranscriptionPolicy.defaults.copyWith(defaultLanguage: () => 'hy'),
      );
      expect(
        personal.values[transcriptionPolicyEntity]?['defaultLanguage'],
        'hy',
      );
      expect(personal.transcriptionDefaultLanguage, 'hy');
      expect(
        personal.pending.values.single.kind,
        'metadata.put',
        reason: 'Saved as private journal metadata for the worker and devices',
      );
    },
  );

  test('voice notes, other audio, rounds and videos qualify', () {
    expect(
      PersonalClient.autoTranscriptionKind(voice(cloud, r'$v')),
      AutoTranscriptionKind.voice,
    );
    expect(
      PersonalClient.autoTranscriptionKind(voice(cloud, r'$f', marker: false)),
      AutoTranscriptionKind.audio,
      reason: 'An audio file without the voice marker is other audio',
    );
    expect(
      PersonalClient.autoTranscriptionKind(video(cloud, r'$clip')),
      AutoTranscriptionKind.video,
    );
    expect(
      PersonalClient.autoTranscriptionKind(
        video(cloud, r'$gif', info: {'fi.mau.gif': true}),
      ),
      isNull,
      reason: 'GIF-style loops carry no speech',
    );
    expect(
      PersonalClient.autoTranscriptionKind(round(local, r'$r')),
      AutoTranscriptionKind.round,
    );
    expect(
      PersonalClient.autoTranscriptionKind(
        round(local, r'$once', extra: {'fi.mau.telegram.view_once': true}),
      ),
      isNull,
    );
    expect(
      PersonalClient.autoTranscriptionKind(local.message(r'$t', 'hello')),
      isNull,
    );
  });

  test(
    'cloud voice is pending and requested at once with the default language',
    () async {
      await personal.setTranscriptionPolicy(
        TranscriptionPolicy.defaults.copyWith(defaultLanguage: () => 'hy'),
      );
      final event = voice(cloud, r'$cloud');
      expect(personal.autoTranscriptPending(event), isTrue);
      await flushTimers();
      final request = personal.requests.single;
      expect(request.payload['origin'], 'auto');
      expect(request.payload['language'], 'hy');
      expect(request.entityId, personal.transcriptId(event));
      expect(
        request.entityId,
        transcriptEntityId(personal.source(event)),
        reason: 'Client and worker derive the same entity',
      );
      // The optimistic job replaces the pending hint; no second request.
      expect(personal.autoTranscriptPending(event), isFalse);
      await flushTimers();
      expect(personal.requests, hasLength(1));
    },
  );

  test('nothing automatic unless the worker reports its switch on', () async {
    // An old worker (no field) ignores `origin: auto` and would run the
    // request as an unlimited manual job; 'off' means the operator said no.
    for (final auto in [null, 'off']) {
      personal.workerReadiness = heartbeat(auto);
      expect(personal.autoTranscriptionAvailable, isFalse);
      for (final event in [
        voice(cloud, '\$cloud-$auto'),
        voice(local, '\$local-$auto'),
        voice(
          local,
          '\$late-$auto',
          age: const Duration(minutes: 2, seconds: 30),
        ),
      ]) {
        expect(personal.autoTranscriptPending(event), isFalse);
        expect(
          personal.autoTranscriptionBlockFor(event, DateTime.now()),
          'worker_off',
        );
      }
      await flushTimers();
      expect(personal.requests, isEmpty, reason: 'worker reports $auto');
    }
    // A catch-up scheduled while the switch was on re-checks it when firing.
    personal.workerReadiness = heartbeat('scan');
    expect(personal.autoTranscriptPending(voice(cloud, r'$flip')), isTrue);
    personal.workerReadiness = heartbeat('off');
    await flushTimers();
    expect(personal.requests, isEmpty);
    // The user's explicit request is unaffected.
    await personal.transcribe(voice(cloud, r'$manual'));
    expect(personal.requests.single.payload.containsKey('origin'), isFalse);
  });

  test('a never-saved policy starts its window when first seen', () async {
    final fresh = _Store();
    final device = _Personal(client, fresh)
      ..workerReadiness = heartbeat('scan');
    addTearDown(() {
      device.fakeReady = false;
      device.cancelAutoTranscriptionTimers();
    });
    await device.loadLocal();
    final before = voice(cloud, r'$before', age: const Duration(minutes: 1));
    // Unknown window start: no spinner, no request, and the start is
    // recorded now (locally, never as journal metadata).
    expect(device.autoTranscriptPending(before), isFalse);
    expect(
      device.autoTranscriptionBlockFor(before, DateTime.now()),
      'before_enabled',
    );
    await device.loadAutoTranscriptionBaseline();
    expect(fresh.records[baselineKey(client)]?['since'], isA<String>());
    expect(device.pending, isEmpty);
    expect(device.autoTranscriptPending(before), isFalse);
    expect(
      device.autoTranscriptionBlockFor(before, DateTime.now()),
      'before_enabled',
    );
    await Future<void>.delayed(const Duration(milliseconds: 5));
    final after = voice(cloud, r'$after', age: Duration.zero);
    expect(device.autoTranscriptPending(after), isTrue);
    await flushTimers();
    expect(device.requests.map((op) => op.payload['source']['eventId']), [
      r'$after',
    ]);
    // A restart keeps the recorded start instead of moving it.
    final saved = fresh.records[baselineKey(client)]!['since'];
    final restarted = _Personal(client, fresh)
      ..workerReadiness = heartbeat('scan');
    await restarted.loadLocal();
    await restarted.loadAutoTranscriptionBaseline();
    expect(fresh.records[baselineKey(client)]!['since'], saved);
    expect(
      restarted.autoTranscriptionBlockFor(before, DateTime.now()),
      'before_enabled',
    );
    restarted.fakeReady = false;
    restarted.cancelAutoTranscriptionTimers();
  });

  test(
    'chats with a disappearing timer are never sent automatically',
    () async {
      cloud.state(beeperDisappearingTimerKey, {
        'type': 'after_read',
        'timer': 86400000,
      });
      final event = voice(cloud, r'$disappearing');
      expect(
        personal.autoTranscriptionBlockFor(event, DateTime.now()),
        'disappearing',
      );
      expect(personal.autoTranscriptPending(event), isFalse);
      // Malformed state fails closed; mautrix's explicit off ({}) allows it.
      cloud.state(beeperDisappearingTimerKey, {'type': 7});
      expect(
        personal.autoTranscriptionBlockFor(event, DateTime.now()),
        'disappearing',
      );
      await flushTimers();
      expect(personal.requests, isEmpty);
      cloud.state(beeperDisappearingTimerKey, {});
      expect(personal.autoTranscriptionBlockFor(event, DateTime.now()), isNull);
      // A disappearing message itself is not a candidate at all.
      expect(
        PersonalClient.autoTranscriptionKind(
          round(
            local,
            r'$timed',
            extra: {
              beeperDisappearingTimerKey: {'type': 'after_send', 'timer': 1000},
            },
          ),
        ),
        isNull,
      );
    },
  );

  test(
    'a chat not opened yet counts as disappearing until its state is read',
    () async {
      // The SDK keeps the timer state out of memory until a room is
      // post-loaded; "not loaded" must never read as "off".
      final database = _StateDatabase();
      final stateClient = _StateClient(database);
      final stateStore = _Store()
        ..records[baselineKey(stateClient)] = {
          'since': DateTime.now()
              .subtract(const Duration(hours: 1))
              .toUtc()
              .toIso8601String(),
        };
      final statePersonal = _Personal(stateClient, stateStore)
        ..workerReadiness = heartbeat('scan');
      await statePersonal.loadLocal();
      await statePersonal.loadAutoTranscriptionBaseline();
      addTearDown(() {
        statePersonal.fakeReady = false;
        statePersonal.cancelAutoTranscriptionTimers();
      });
      final timed = ConversationRoom(stateClient, '!timed:example.invalid')
        ..partial = true;
      database.stored[timed.id] = [
        Event(
          room: timed,
          type: beeperDisappearingTimerKey,
          stateKey: '',
          eventId: r'$timer',
          senderId: '@bridge:example.invalid',
          originServerTs: DateTime.utc(2026),
          content: {'type': 'after_send', 'timer': 3600000},
        ),
      ];
      final plain = ConversationRoom(stateClient, '!plain:example.invalid')
        ..partial = true;
      final hidden = voice(timed, r'$hidden');
      final open = voice(plain, r'$open');
      expect(
        statePersonal.autoTranscriptionBlockFor(hidden, DateTime.now()),
        'disappearing',
      );
      expect(
        statePersonal.autoTranscriptionBlockFor(open, DateTime.now()),
        'disappearing',
        reason: 'unknown until read, even without a stored timer',
      );
      expect(statePersonal.autoTranscriptPending(open), isFalse);
      final before = statePersonal.notifications;
      await pumpEventQueue();
      expect(timed.partial, isFalse);
      expect(plain.partial, isFalse);
      expect(database.reads, 2, reason: 'one local read per room');
      expect(
        statePersonal.notifications,
        greaterThan(before),
        reason: 'panels decide again',
      );
      expect(
        statePersonal.autoTranscriptionBlockFor(hidden, DateTime.now()),
        'disappearing',
        reason: 'the stored timer',
      );
      expect(
        statePersonal.autoTranscriptionBlockFor(open, DateTime.now()),
        isNull,
      );
      await flushTimers();
      expect(statePersonal.requests, isEmpty, reason: 'never the timed one');
    },
  );

  test('a chat whose state cannot be read stays blocked', () async {
    // The fixture database refuses every read: fail closed, no loop.
    cloud.partial = true;
    final event = voice(cloud, r'$unreadable');
    expect(
      personal.autoTranscriptionBlockFor(event, DateTime.now()),
      'disappearing',
    );
    await pumpEventQueue();
    expect(cloud.partial, isTrue);
    expect(
      personal.autoTranscriptionBlockFor(event, DateTime.now()),
      'disappearing',
    );
    await flushTimers();
    expect(personal.requests, isEmpty);
  });

  test('videos wait for a worker that transcribes them', () async {
    // The current worker (no capability field) refuses videos.
    final clip = video(cloud, r'$clip');
    expect(personal.transcribableKind(clip), isNull);
    expect(
      personal.autoTranscriptionBlockFor(clip, DateTime.now()),
      'worker_off',
    );
    expect(personal.autoTranscriptPending(clip), isFalse);
    await expectLater(personal.transcribe(clip), throwsStateError);
    await flushTimers();
    expect(personal.requests, isEmpty);
    // Voice and other m.audio stay available with an older worker.
    expect(
      personal.transcribableKind(voice(cloud, r'$a', marker: false)),
      AutoTranscriptionKind.audio,
    );
    // A media-capable worker without its own sync feed: asked at once.
    personal.workerReadiness = heartbeat('scan', media: 2);
    expect(personal.transcribableKind(clip), AutoTranscriptionKind.video);
    expect(personal.autoTranscriptPending(clip), isTrue);
    await flushTimers();
    expect(personal.requests.single.payload['origin'], 'auto');
  });

  test('a worker watching its own sync gets a grace period in cloud rooms '
      'and per-kind switches apply', () async {
    personal.workerReadiness = heartbeat('scan', media: 2, live: true);
    final clip = video(
      cloud,
      r'$fresh-clip',
      age: const Duration(seconds: 2),
    );
    expect(personal.autoTranscriptPending(clip), isTrue);
    await flushTimers();
    expect(personal.requests, isEmpty, reason: 'the worker picks it up');
    await personal.setTranscriptionPolicy(
      TranscriptionPolicy.defaults.withKind(AutoTranscriptionKind.video, false),
    );
    expect(
      personal.autoTranscriptionBlockFor(
        video(cloud, r'$off-clip'),
        DateTime.now(),
      ),
      'kind_disabled',
    );
    expect(personal.autoTranscriptPending(video(cloud, r'$off-clip')), isFalse);
    expect(
      personal.autoTranscriptionBlockFor(voice(cloud, r'$v2'), DateTime.now()),
      isNull,
    );
  });

  test(
    'Instagram reels are offered on demand, never requested automatically',
    () async {
      final shared = reel(cloud, r'$reel');
      expect(
        PersonalClient.autoTranscriptionKind(shared),
        AutoTranscriptionKind.reel,
      );
      // A worker that refuses videos refuses reels too.
      expect(personal.transcribableKind(shared), isNull);
      personal.workerReadiness = heartbeat('scan', media: 2);
      expect(personal.transcribableKind(shared), AutoTranscriptionKind.reel);
      expect(personal.workerSeparatesReels, isFalse);
      expect(
        personal.autoTranscriptionBlockFor(shared, DateTime.now()),
        'kind_disabled',
      );
      expect(personal.autoTranscriptPending(shared), isFalse);
      await flushTimers();
      expect(personal.requests, isEmpty, reason: 'no automatic request');
      // Other Instagram videos keep the video policy.
      expect(personal.autoTranscriptPending(video(cloud, r'$clip')), isTrue);
      await flushTimers();
      expect(personal.requests.single.payload['origin'], 'auto');
      // On demand, a reel is requested like any other media.
      await personal.transcribe(shared);
      final manual = personal.requests.singleWhere(
        (op) => op.entityId == personal.transcriptId(shared),
      );
      expect(manual.payload.containsKey('origin'), isFalse);
      // Switched on, reels are automatic as well.
      personal.workerReadiness = heartbeat('scan', media: 3);
      expect(personal.workerSeparatesReels, isTrue);
      await personal.setTranscriptionPolicy(
        TranscriptionPolicy.defaults.withKind(AutoTranscriptionKind.reel, true),
      );
      expect(
        personal.autoTranscriptionBlockFor(
          reel(cloud, r'$reel2'),
          DateTime.now(),
        ),
        isNull,
      );
    },
  );

  group('unconfirmed changes and conflicts', () {
    test('a change the running worker never answers is re-issued', () async {
      await personal.setTranscriptionPolicy(
        TranscriptionPolicy.defaults.copyWith(maxSeconds: 60),
      );
      final first = personal.pending.values.single;
      expect(personal.isUnconfirmed(first), isFalse);
      // Let the publication attempt finish, then stop this client.
      await flushTimers();
      personal.fakeReady = false;
      // Published long before the worker's current heartbeat.
      final replicaKey =
          'account:${client.userID}:replica:$transcriptionPolicyEntity';
      final record = Map<String, dynamic>.from(store.records[replicaKey]!);
      record['attempted'] = [first.opId];
      record['attemptedAt'] = {
        first.opId: DateTime.now()
            .subtract(const Duration(minutes: 30))
            .millisecondsSinceEpoch,
      };
      store.records[replicaKey] = record;
      final reloaded = _Personal(client, store)
        ..workerReadiness = heartbeat('scan');
      addTearDown(() => reloaded.fakeReady = false);
      await reloaded.loadLocal();
      final stuck = reloaded.pending.values.single;
      expect(reloaded.publishedAt(stuck), isNotNull);
      expect(reloaded.isUnconfirmed(stuck), isTrue);
      // A worker without a fresh heartbeat is offline, not unconfirmed.
      reloaded.workerReadiness = WorkerReadiness(
        receivedAt: DateTime.now().subtract(const Duration(hours: 1)),
        autoTranscription: 'scan',
      );
      expect(reloaded.isUnconfirmed(stuck), isFalse);
      reloaded.workerReadiness = heartbeat('scan');
      await reloaded.resendPending(stuck.opId);
      final fresh = reloaded.pending.values.single;
      expect(fresh.opId, isNot(stuck.opId));
      expect(fresh.payload['value'], stuck.payload['value']);
      expect(reloaded.reissueCount(fresh), 1);
    });

    test(
      'echo conflicts saved by older versions are settled on start',
      () async {
        final key = 'account:${client.userID}:replica:org:fixture';
        store.records[key] = {
          'revision': 3,
          'generation': 1,
          'commands': <String, dynamic>{},
          'attempted': <String>[],
          'appliedResults': <String>[],
          'serverValue': {'archived': true},
          'localValue': {'archived': true},
          'conflict': {
            'state': 'conflict',
            'revision': 4,
            'existingValue': {'archived': true},
            'proposedValue': {'archived': true},
          },
        };
        store.records['account:${client.userID}:replica:transcript:fixture'] = {
          'revision': 2,
          'generation': 0,
          'commands': <String, dynamic>{},
          'attempted': <String>[],
          'appliedResults': <String>[],
          'jobKind': 'transcript',
          'job': {'state': 'processing', 'errorCode': 'already_exists'},
          'conflict': {'state': 'conflict', 'errorCode': 'already_exists'},
        };
        final reloaded = _Personal(client, store);
        addTearDown(() => reloaded.fakeReady = false);
        await reloaded.loadLocal();
        expect(reloaded.conflicts, isEmpty);
        expect(reloaded.values['org:fixture'], {'archived': true});
        expect(reloaded.revisions['org:fixture'], 4);
      },
    );
  });

  test('heartbeat capabilities parse defensively', () {
    final at = DateTime.now();
    final parsed = WorkerReadiness.fromPayload({
      'autoTranscription': 'scan',
      'transcriptionMedia': 2,
      'autoTranscriptionLive': true,
    }, at);
    expect(parsed.transcriptionMedia, 2);
    expect(parsed.autoTranscriptionLive, isTrue);
    final odd = WorkerReadiness.fromPayload({
      'transcriptionMedia': '2',
      'autoTranscriptionLive': 'yes',
    }, at);
    expect(odd.transcriptionMedia, isNull);
    expect(odd.autoTranscriptionLive, isNull);
  });

  test('local bridge rooms give the worker scan a short grace period', () async {
    expect(
      PersonalClient.autoTranscriptCatchUpDelay,
      lessThanOrEqualTo(const Duration(seconds: 15)),
      reason: 'A message missed by the worker must not sit on a spinner for '
          'minutes in an open chat',
    );
    final fresh = voice(local, r'$fresh', age: const Duration(seconds: 2));
    expect(personal.autoTranscriptPending(fresh), isTrue);
    await flushTimers();
    expect(personal.requests, isEmpty);
    // Past the grace period the visible device asks instead.
    final late = voice(
      local,
      r'$late',
      age: PersonalClient.autoTranscriptCatchUpDelay + const Duration(seconds: 1),
    );
    expect(personal.autoTranscriptPending(late), isTrue);
    await flushTimers();
    expect(personal.requests.single.payload['source']['eventId'], r'$late');
    // Older than the pending window: no spinner, but still caught up.
    final older = voice(local, r'$older', age: const Duration(minutes: 30));
    expect(personal.autoTranscriptPending(older), isFalse);
    await flushTimers();
    expect(personal.requests, hasLength(2));
  });

  test(
    'muted, disabled, offline and old messages are left alone',
    () async {
      expect(
        personal.autoTranscriptPending(
          voice(cloud, r'$old', age: const Duration(hours: 25)),
        ),
        isFalse,
      );
      personal.fakeWorkerOnline = false;
      expect(
        personal.autoTranscriptPending(voice(cloud, r'$offline')),
        isFalse,
      );
      personal.fakeWorkerOnline = true;
      await personal.put('org:${cloud.id}', {'muted': true});
      expect(personal.autoTranscriptPending(voice(cloud, r'$muted')), isFalse);
      await personal.setTranscriptionPolicy(
        TranscriptionPolicy.defaults.withChatOverride(cloud.id, true),
      );
      expect(
        personal.autoTranscriptPending(voice(cloud, r'$always')),
        isTrue,
        reason: 'Per-chat Always outranks the chat mute',
      );
      await flushTimers();
      expect(personal.requests.map((op) => op.payload['source']['eventId']), [
        r'$always',
      ]);
      // A scheduled catch-up re-checks the policy when it fires.
      final scheduled = voice(cloud, r'$scheduled');
      expect(personal.autoTranscriptPending(scheduled), isTrue);
      await personal.setTranscriptionPolicy(
        TranscriptionPolicy.defaults.withAuto(false, DateTime.now()),
      );
      expect(personal.autoTranscriptPending(voice(local, r'$off')), isFalse);
      await flushTimers();
      expect(personal.requests, hasLength(1));
    },
  );

  group('own messages', () {
    test('are requested right after sending, from the sending device', () async {
      final sent = voice(
        cloud,
        r'$sent',
        outgoing: true,
        age: const Duration(seconds: 1),
        transactionId: 'txn-sent',
      );
      expect(personal.autoTranscriptionBlockFor(sent, DateTime.now()), isNull);
      expect(personal.autoTranscriptPending(sent), isTrue);
      await flushTimers();
      final request = personal.requests.single;
      expect(request.payload['source']['eventId'], r'$sent');
      expect(
        request.payload['origin'],
        'auto',
        reason: 'The worker applies its switch, length and daily limits',
      );
      // Another device of the account (no transaction id) leaves the request
      // to the sender for a moment.
      final elsewhere = voice(
        cloud,
        r'$elsewhere',
        outgoing: true,
        age: const Duration(seconds: 1),
      );
      expect(personal.autoTranscriptPending(elsewhere), isTrue);
      await flushTimers();
      expect(personal.requests, hasLength(1));
      // Never swept up later: an older own message keeps the button.
      final older = voice(
        cloud,
        r'$older-own',
        outgoing: true,
        age: const Duration(minutes: 4),
        transactionId: 'txn-older',
      );
      expect(personal.autoTranscriptPending(older), isFalse);
      await flushTimers();
      expect(personal.requests, hasLength(1));
    });

    test('wait a moment in local bridge rooms for the local index', () async {
      final sent = voice(
        local,
        r'$sent-local',
        outgoing: true,
        age: Duration.zero,
        transactionId: 'txn-local',
      );
      expect(personal.autoTranscriptPending(sent), isTrue);
      await flushTimers();
      expect(personal.requests, isEmpty);
      expect(
        PersonalClient.ownLocalRequestDelay,
        lessThan(PersonalClient.autoTranscriptCatchUpDelay),
      );
    });

    test('follow the synced switch; muted chats still count, disappearing '
        'chats never', () async {
      await personal.put('org:${cloud.id}', {'muted': true});
      final muted = voice(
        cloud,
        r'$own-muted',
        outgoing: true,
        age: const Duration(seconds: 1),
        transactionId: 'txn-muted',
      );
      expect(personal.autoTranscriptPending(muted), isTrue);
      await flushTimers();
      expect(
        personal.requests.map((op) => op.payload['source']['eventId']),
        [r'$own-muted'],
      );
      await personal.setTranscriptionPolicy(
        TranscriptionPolicy.defaults.withOutgoing(false),
      );
      final off = voice(
        cloud,
        r'$own-off',
        outgoing: true,
        age: const Duration(seconds: 1),
        transactionId: 'txn-off',
      );
      expect(
        personal.autoTranscriptionBlockFor(off, DateTime.now()),
        'outgoing',
      );
      expect(personal.autoTranscriptPending(off), isFalse);
      await personal.setTranscriptionPolicy(TranscriptionPolicy.defaults);
      local.state(beeperDisappearingTimerKey, {
        'type': 'after_send',
        'timer': 60000,
      });
      final vanishing = voice(
        local,
        r'$own-vanishing',
        outgoing: true,
        age: Duration.zero,
        transactionId: 'txn-vanishing',
      );
      expect(
        personal.autoTranscriptionBlockFor(vanishing, DateTime.now()),
        'disappearing',
      );
      expect(personal.autoTranscriptPending(vanishing), isFalse);
      await flushTimers();
      expect(
        personal.requests.map((op) => op.payload['source']['eventId']),
        [r'$own-muted'],
      );
    });

    test('the confirmed send is requested without a bubble on screen', () async {
      personal.workerReadiness = heartbeat('scan', media: 3);
      client.onTimelineEvent.add(
        voice(
          cloud,
          r'$echo',
          outgoing: true,
          age: Duration.zero,
          transactionId: 'txn-echo',
        ),
      );
      // Local echoes (no event id yet), text and incoming media are ignored
      // here; incoming media is the bubble's and the worker's business.
      client.onTimelineEvent.add(
        voice(cloud, 'txn-pending', outgoing: true, age: Duration.zero),
      );
      client.onTimelineEvent.add(
        voice(cloud, r'$incoming', age: Duration.zero),
      );
      client.onTimelineEvent.add(cloud.message(r'$text', 'hello'));
      // An own video is shared, not recorded: on demand only.
      client.onTimelineEvent.add(
        Event(
          room: cloud,
          eventId: r'$own-clip',
          type: EventTypes.Message,
          senderId: client.userID,
          originServerTs: DateTime.now(),
          unsigned: {'transaction_id': 'txn-clip'},
          content: {
            'msgtype': 'm.video',
            'body': 'clip.mp4',
            'url': 'mxc://example.invalid/clip',
            'info': {'mimetype': 'video/mp4', 'duration': 30000},
          },
        ),
      );
      await flushTimers();
      expect(
        personal.requests.map((op) => op.payload['source']['eventId']),
        [r'$echo'],
      );
    });

    test('nothing is asked for while the worker switch is off', () async {
      personal.workerReadiness = heartbeat('off');
      client.onTimelineEvent.add(
        voice(
          cloud,
          r'$echo-off',
          outgoing: true,
          age: Duration.zero,
          transactionId: 'txn-echo-off',
        ),
      );
      await flushTimers();
      expect(personal.requests, isEmpty);
    });
  });

  test('an expired pending window notifies so the spinner clears', () async {
    final event = voice(
      local,
      r'$expiring',
      age: const Duration(minutes: 2, seconds: 59, milliseconds: 800),
    );
    expect(personal.autoTranscriptPending(event), isTrue);
    // The worker disappears before this device could ask.
    personal.fakeWorkerOnline = false;
    final before = personal.notifications;
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(personal.notifications, greaterThan(before));
    expect(personal.requests, isEmpty);
    personal.fakeWorkerOnline = true;
    expect(personal.autoTranscriptPending(event), isFalse);
  });

  group('settings', () {
    Future<void> mount(WidgetTester tester, Widget child) async {
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: Scaffold(body: SingleChildScrollView(child: child)),
        ),
      );
      await tester.pump();
    }

    // Widget tests run in a fake-async zone: the client and its replica must
    // be created inside it, so every storage future completes on pump().
    Future<_Personal> fakeZonePersonal() async {
      final created = _Personal(client, _Store());
      await created.loadLocal();
      return created;
    }

    testWidgets('Transcriptions section edits the synced policy', (
      tester,
    ) async {
      final personal = await fakeZonePersonal();
      final runs = <Future<void>>[];
      await mount(
        tester,
        ListenableBuilder(
          listenable: personal,
          builder: (context, _) => TranscriptionSettingsSection(
            personal: personal,
            run: (action) {
              final future = action();
              runs.add(future);
              return future;
            },
          ),
        ),
      );
      expect(find.text('Transcribe automatically'), findsOneWidget);
      expect(find.textContaining('sent to OpenAI'), findsOneWidget);
      expect(find.text('Your own messages'), findsOneWidget);
      expect(find.text('Telegram'), findsOneWidget);
      expect(find.text('Automatic: 0 completed'), findsOneWidget);
      expect(
        tester
            .widget<NotionSettingsToggle>(
              find.byKey(const ValueKey('transcription-auto')),
            )
            .value,
        isTrue,
      );

      Future<void> saved() async {
        await tester.pumpAndSettle();
        await Future.wait(runs);
        await tester.pump();
      }

      await tester.tap(find.byKey(const ValueKey('transcription-outgoing')));
      await saved();
      expect(personal.transcriptionPolicy.outgoing, isFalse);
      await tester.tap(find.byKey(const ValueKey('transcription-outgoing')));
      await saved();
      expect(personal.transcriptionPolicy.outgoing, isTrue);

      await tester.tap(find.text('Default language'));
      await tester.pumpAndSettle();
      expect(find.text('Հայերեն'), findsOneWidget);
      expect(find.text('Polski'), findsOneWidget);
      await tester.tap(find.text('Armenian'));
      await saved();
      expect(personal.transcriptionDefaultLanguage, 'hy');

      await tester.tap(find.text('Maximum length'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('10 min'));
      await saved();
      expect(personal.transcriptionPolicy.maxSeconds, 600);

      await tester.tap(find.text('Daily limit'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('\$0.25'));
      await saved();
      expect(personal.transcriptionPolicy.dailyBudgetUsd, 0.25);

      NotionSettingsToggle telegram() => tester.widget<NotionSettingsToggle>(
        find.byKey(const ValueKey('transcription-network-telegram')),
      );

      // With automatic transcription off, network toggles keep showing the
      // saved choice but cannot be changed.
      await tester.tap(find.byKey(const ValueKey('transcription-auto')));
      await saved();
      expect(personal.transcriptionPolicy.auto, isFalse);
      expect(telegram().value, isTrue);
      expect(telegram().onChanged, isNull);
      await tester.tap(find.byKey(const ValueKey('transcription-auto')));
      await saved();
      expect(personal.transcriptionPolicy.auto, isTrue);

      await tester.tap(
        find.byKey(const ValueKey('transcription-network-telegram')),
      );
      await saved();
      expect(personal.transcriptionPolicy.networkEnabled('telegram'), isFalse);

      await tester.tap(find.byKey(const ValueKey('transcription-auto')));
      await saved();
      expect(personal.transcriptionPolicy.auto, isFalse);
      expect(telegram().value, isFalse);
      expect(personal.transcriptionPolicy.defaultLanguage, 'hy');
    });

    testWidgets('Instagram reels are on demand and say so', (tester) async {
      final personal = await fakeZonePersonal();
      personal.workerReadiness = heartbeat('scan', media: 2);
      final runs = <Future<void>>[];
      await mount(
        tester,
        ListenableBuilder(
          listenable: personal,
          builder: (context, _) => TranscriptionSettingsSection(
            personal: personal,
            run: (action) {
              final future = action();
              runs.add(future);
              return future;
            },
          ),
        ),
      );
      NotionSettingsToggle reels() => tester.widget<NotionSettingsToggle>(
        find.byKey(const ValueKey('transcription-kind-reel')),
      );
      expect(find.text('Instagram reels'), findsOneWidget);
      expect(reels().value, isFalse);
      expect(
        reels().subtitle,
        'On demand · tap Transcribe under a reel · until the background '
        'service is updated, reels follow Videos',
      );
      expect(
        find.textContaining('Instagram reels only when you tap Transcribe'),
        findsOneWidget,
      );
      personal.workerReadiness = heartbeat('scan', media: 3);
      personal.notifyListeners();
      await tester.pump();
      expect(
        reels().subtitle,
        'On demand · tap Transcribe under a reel · '
        'Reels, posts and stories shared from Instagram',
      );
      await tester.tap(find.byKey(const ValueKey('transcription-kind-reel')));
      await tester.pumpAndSettle();
      await Future.wait(runs);
      await tester.pump();
      expect(
        personal.transcriptionPolicy.kindEnabled(AutoTranscriptionKind.reel),
        isTrue,
      );
      expect(
        personal.transcriptionPolicy.kindEnabled(AutoTranscriptionKind.video),
        isTrue,
      );
      expect(reels().subtitle, startsWith('Automatic'));
    });

    test('usage costs use cents and never round small spend to zero', () {
      expect(transcriptionUsageLabel(0), '\$0.00');
      expect(transcriptionUsageLabel(.0012), '< \$0.01');
      expect(transcriptionUsageLabel(.0123), '\$0.01');
      expect(transcriptionUsageLabel(1), '\$1.00');
    });

    testWidgets('per-chat override row saves Always and Never', (tester) async {
      final personal = await fakeZonePersonal();
      SharedPreferences.setMockInitialValues({});
      final preferences = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(800, 2600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: ConversationMatrix(client, preferences),
          child: MaterialApp(
            theme: ThemeData.dark(),
            home: ChatPreferencesPage(personal: personal, room: cloud),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Automatic transcription'), findsOneWidget);
      // The page shows a progress bar while saving: no pumpAndSettle then.
      Future<void> choose(String current, String next) async {
        await tester.tap(find.text(current).last);
        await tester.pumpAndSettle();
        await tester.tap(find.text(next).last);
        for (var i = 0; i < 4; i++) {
          await tester.pump(const Duration(milliseconds: 300));
        }
      }

      await choose('Default', 'Never');
      expect(personal.transcriptionPolicy.chatOverrides, {cloud.id: false});
      await choose('Never', 'Always');
      expect(personal.transcriptionPolicy.chatOverrides, {cloud.id: true});
    });
  });
}
