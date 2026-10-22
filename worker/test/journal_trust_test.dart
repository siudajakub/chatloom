// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:matrix/encryption.dart';
import 'package:matrix/encryption/utils/session_key.dart';
import 'package:matrix/matrix.dart';
// ignore: implementation_imports
import 'package:matrix/src/utils/cached_stream_controller.dart';
import 'package:personal_core/personal_core.dart';
import 'package:personal_worker/src/engine.dart';
import 'package:personal_worker/src/journal.dart';
import 'package:personal_worker/src/journal_trust.dart';
import 'package:personal_worker/src/ports.dart';
import 'package:personal_worker/src/store.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:test/test.dart';

const _owner = '@synthetic:example.invalid';
const _roomId = '!synthetic-journal:example.invalid';
final _t0 = DateTime.utc(2026, 10, 18, 8);

class _Device implements DeviceKeys {
  _Device(
    this.deviceId,
    this.curve25519Key,
    this.ed25519Key, {
    this.verified = true,
  });
  @override
  final String? deviceId;
  @override
  final String? curve25519Key;
  @override
  final String? ed25519Key;
  @override
  final bool verified;
  @override
  bool get blocked => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Keys implements DeviceKeysList {
  @override
  Map<String, DeviceKeys> deviceKeys = {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Session implements SessionKey {
  _Session(
    this.sessionId,
    this.senderKey,
    String ed25519, {
    List<String> chain = const [],
    Map<String, dynamic>? content,
  }) : senderClaimedKeys = {'ed25519': ed25519},
       forwardingCurve25519KeyChain = chain,
       content =
           content ??
           {
             'algorithm': megolmAlgorithm,
             'room_id': _roomId,
             'session_id': sessionId,
             'session_key': 'synthetic',
           };
  @override
  final String sessionId;
  @override
  String get roomId => _roomId;
  @override
  final String senderKey;
  @override
  final Map<String, String> senderClaimedKeys;
  @override
  final List<String> forwardingCurve25519KeyChain;
  @override
  final Map<String, dynamic> content;
  @override
  final Map<String, String> indexes = {};
  @override
  bool get isValid => true;
  final plaintexts = <String, Map<String, dynamic>>{};
  void record(Event event) => indexes['key-${indexes.length}'] =
      '${event.eventId}|${event.originServerTs.millisecondsSinceEpoch}';
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _KeyManager implements KeyManager {
  final sessions = <String, _Session>{};
  int loads = 0;
  @override
  Future<SessionKey?> loadInboundGroupSession(
    String roomId,
    String sessionId,
  ) async {
    loads++;
    return sessions[sessionId];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Encryption implements Encryption {
  @override
  final _KeyManager keyManager = _KeyManager();
  @override
  Future<Event> decryptRoomEvent(
    Event event, {
    bool store = false,
    EventUpdateType updateType = EventUpdateType.timeline,
  }) async {
    final session = keyManager.sessions[event.content['session_id']];
    final plain = session?.plaintexts[event.eventId];
    if (session == null || plain == null) return event;
    final decrypted = Event(
      room: event.room,
      eventId: event.eventId,
      type: personalEventType,
      senderId: event.senderId,
      originServerTs: event.originServerTs,
      content: plain,
      originalSource: event,
    );
    session.record(decrypted);
    return decrypted;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements Client {
  @override
  String? userID = _owner;
  @override
  final Map<String, DeviceKeysList> userDeviceKeys = {_owner: _Keys()};
  @override
  Future<dynamic>? userDeviceKeysLoading = Future<void>.value();
  @override
  final _Encryption encryption = _Encryption();
  @override
  bool get encryptionEnabled => true;
  late final _Room room = _Room(this);
  @override
  Room? getRoomById(String id) => id == _roomId ? room : null;
  @override
  final CachedStreamController<Event> onTimelineEvent =
      CachedStreamController();
  @override
  final CachedStreamController<SyncUpdate> onSync = CachedStreamController();
  final redactions = <String>[];
  @override
  Future<String?> redactEvent(
    String roomId,
    String eventId,
    String txnId, {
    String? reason,
  }) async {
    redactions.add(eventId);
    return r'$redaction';
  }

  void device(String id, {bool verified = true}) =>
      userDeviceKeys[_owner]!.deviceKeys[id] = _Device(
        id,
        'curve-$id',
        'ed-$id',
        verified: verified,
      );

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Timeline implements Timeline {
  _Timeline(this.room);
  @override
  final Room room;
  @override
  final List<Event> events = [];
  @override
  bool get canRequestHistory => false;
  @override
  void requestKeys({
    bool tryOnlineBackup = true,
    bool onlineKeyBackupOnly = true,
  }) {}
  @override
  void cancelSubscriptions() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Room implements Room {
  _Room(this.client);
  @override
  final _Client client;
  @override
  String get id => _roomId;
  @override
  bool get encrypted => true;
  @override
  Membership get membership => Membership.join;
  late final timeline = _Timeline(this);
  @override
  final CachedStreamController<String> onSessionKeyReceived =
      CachedStreamController();
  final stored = <String, Event>{};
  @override
  Future<Event?> getEventById(String eventID) async => stored[eventID];

  /// Bodies the homeserver accepted, by transaction id.
  final sent = <String, Map<String, dynamic>>{};

  /// Thrown instead of sending the body of this op id (failure injection).
  final failures = <String, Object>{};
  final attempts = <String>[];
  @override
  Future<String?> sendEvent(
    Map<String, dynamic> content, {
    String type = EventTypes.Message,
    String? txid,
    Event? inReplyTo,
    String? editEventId,
    String? threadRootEventId,
    String? threadLastEventId,
    bool displayPendingEvent = true,
    bool retryOnTransportFailure = true,
  }) async {
    final opId = content['opId'] as String;
    attempts.add(opId);
    final failure = failures[opId];
    if (failure != null) throw failure;
    sent[txid!] = content;
    return '\$sent-$opId';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    switch (invocation.memberName) {
      case #requestParticipants:
        return Future<List<User>>.value([
          User(_owner, room: this, membership: 'join'),
        ]);
      case #getState:
        return invocation.positionalArguments.first == personalRoomMarker
            ? StrippedStateEvent(
                type: personalRoomMarker,
                senderId: _owner,
                content: {'schema': personalSchemaVersion},
              )
            : null;
      case #getTimeline:
        return Future<Timeline>.value(timeline);
    }
    return super.noSuchMethod(invocation);
  }
}

class _NoTransport implements FeatureTransport {
  @override
  String get accountId => _owner;
  @override
  String get deviceId => 'WORKER';
  @override
  bool get verified => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoTranscriber implements Transcriber {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A command whose envelope names [envelopeDevice] and which the SDK
/// decrypted with [session] (null: decrypted by a session since replaced).
Event _command(
  _Room room,
  String id, {
  required String envelopeDevice,
  required _Session? session,
  String sessionId = 'session-phone',
}) {
  final content = PersonalOperation(
    opId: id,
    kind: 'metadata.put',
    entityId: 'org:$id',
    createdAt: _t0,
    payload: {
      'value': {'n': 1},
    },
  ).toJson().cast<String, dynamic>();
  final event = Event(
    room: room,
    eventId: '\$$id',
    type: personalEventType,
    senderId: _owner,
    originServerTs: _t0,
    content: content,
    originalSource: MatrixEvent(
      type: EventTypes.Encrypted,
      content: {
        'algorithm': megolmAlgorithm,
        'sender_key': 'curve-$envelopeDevice',
        'session_id': session?.sessionId ?? sessionId,
        'ciphertext': 'synthetic',
      },
      senderId: _owner,
      eventId: '\$$id',
      originServerTs: _t0,
    ),
  );
  session?.record(event);
  return event;
}

void main() {
  late _Client client;
  late _Session phone;
  setUp(() {
    client = _Client()
      ..device('PHONE')
      ..device('WORKER');
    phone = _Session('session-phone', 'curve-PHONE', 'ed-PHONE');
    client.encryption.keyManager.sessions[phone.sessionId] = phone;
  });

  Future<WorkerJournalTrust> capture(List<Event> events) async {
    final trust = WorkerJournalTrust.of(client, {'PHONE', 'WORKER'});
    await trust.capture(client.room, events);
    return trust;
  }

  test('a command from the pinned phone session is accepted', () async {
    final event = _command(
      client.room,
      'ok',
      envelopeDevice: 'PHONE',
      session: phone,
    );
    final trust = await capture([event]);
    expect(trust.verdict(event), MegolmTrust.trusted);
    expect(await WorkerJournalTrust.verify(client, event, {'PHONE'}), isTrue);
    expect(
      await WorkerJournalTrust.verify(client, event, {'OTHER'}),
      isFalse,
      reason: 'Verified but not pinned',
    );
  });

  test('a forged envelope sender_key is refused', () async {
    client.device('BRIDGE', verified: false);
    final bridge = _Session('session-bridge', 'curve-BRIDGE', 'ed-BRIDGE');
    client.encryption.keyManager.sessions[bridge.sessionId] = bridge;
    final forged = _command(
      client.room,
      'forged',
      envelopeDevice: 'PHONE',
      session: bridge,
    );
    final trust = await capture([forged]);
    expect(trust.verdict(forged), MegolmTrust.envelopeMismatch);
    expect(trust.trusts(forged), isFalse);
  });

  test('forwarded, backup and missing sessions are refused', () async {
    final forwarded = _Session(
      'session-forwarded',
      'curve-PHONE',
      'ed-PHONE',
      chain: ['curve-PHONE'],
    );
    final backup = _Session(
      'session-backup',
      'curve-PHONE',
      'ed-PHONE',
      content: {
        'algorithm': megolmAlgorithm,
        'sender_key': 'curve-PHONE',
        'session_key': 'synthetic',
      },
    );
    client.encryption.keyManager.sessions
      ..[forwarded.sessionId] = forwarded
      ..[backup.sessionId] = backup;
    final viaForward = _command(
      client.room,
      'forwarded',
      envelopeDevice: 'PHONE',
      session: forwarded,
    );
    final viaBackup = _command(
      client.room,
      'backup',
      envelopeDevice: 'PHONE',
      session: backup,
    );
    final orphan = _command(
      client.room,
      'orphan',
      envelopeDevice: 'PHONE',
      session: null,
      sessionId: 'session-unknown',
    );
    final trust = await capture([viaForward, viaBackup, orphan]);
    expect(trust.verdict(viaForward), MegolmTrust.importedSession);
    expect(trust.verdict(viaBackup), MegolmTrust.importedSession);
    expect(trust.verdict(orphan), MegolmTrust.missingSession);
  });

  test('an event missing from the session index is re-proven', () async {
    final event = _command(
      client.room,
      'reprove',
      envelopeDevice: 'PHONE',
      session: null,
    );
    expect((await capture([event])).trusts(event), isFalse);
    phone.plaintexts[event.eventId] = Map.of(event.content);
    expect((await capture([event])).trusts(event), isTrue);
  });

  test('reconcile accepts only commands of pinned verified sessions', () async {
    client.device('BRIDGE', verified: false);
    final bridge = _Session('session-bridge', 'curve-BRIDGE', 'ed-BRIDGE');
    client.encryption.keyManager.sessions[bridge.sessionId] = bridge;
    client.room.timeline.events.addAll([
      _command(client.room, 'forged', envelopeDevice: 'PHONE', session: bridge),
      _command(client.room, 'genuine', envelopeDevice: 'PHONE', session: phone),
    ]);
    final store = WorkerStore(sqlite3.openInMemory());
    final engine = WorkerEngine(store, _NoTransport(), _NoTranscriber());
    final journal = WorkerJournal(
      client,
      _roomId,
      {'PHONE', 'WORKER'},
      store,
      engine,
    );
    await journal.start();
    expect(journal.authenticatedDecryptionSeen, isTrue);
    expect(store.hasCommand('genuine'), isTrue);
    expect(store.hasCommand('forged'), isFalse);
    expect(store.metadata('org:forged'), isNull);
  });

  test('a journal with only forged commands never proves decryption', () async {
    client.device('BRIDGE', verified: false);
    final bridge = _Session('session-bridge', 'curve-BRIDGE', 'ed-BRIDGE');
    client.encryption.keyManager.sessions[bridge.sessionId] = bridge;
    client.room.timeline.events.add(
      _command(client.room, 'forged', envelopeDevice: 'PHONE', session: bridge),
    );
    final store = WorkerStore(sqlite3.openInMemory());
    final journal = WorkerJournal(
      client,
      _roomId,
      {'PHONE'},
      store,
      WorkerEngine(store, _NoTransport(), _NoTranscriber()),
    );
    await expectLater(journal.start(), throwsA(isA<WorkerFailure>()));
    expect(store.hasCommand('forged'), isFalse);
  });

  group('incremental journal (wave 5)', () {
    late WorkerStore store;
    late WorkerJournal journal;
    setUp(() {
      store = WorkerStore(sqlite3.openInMemory());
      journal = WorkerJournal(
        client,
        _roomId,
        {'PHONE', 'WORKER'},
        store,
        WorkerEngine(store, _NoTransport(), _NoTranscriber()),
      );
    });
    tearDown(() => journal.dispose());

    test(
      'sync events are processed once, not replayed on every pass',
      () async {
        client.room.timeline.events.add(
          _command(
            client.room,
            'first',
            envelopeDevice: 'PHONE',
            session: phone,
          ),
        );
        await journal.start();
        expect(store.hasCommand('first'), isTrue);
        final loads = client.encryption.keyManager.loads;
        // Idle passes touch neither trust nor the engine.
        await journal.reconcile();
        await journal.reconcile();
        expect(client.encryption.keyManager.loads, loads);
        client.onTimelineEvent.add(
          _command(
            client.room,
            'second',
            envelopeDevice: 'PHONE',
            session: phone,
          ),
        );
        await Future<void>.delayed(Duration.zero);
        await journal.reconcile();
        expect(store.hasCommand('second'), isTrue);
        expect(store.checkpoint(WorkerJournal.checkpointKey), r'$second');
        final after = client.encryption.keyManager.loads;
        await journal.reconcile();
        expect(client.encryption.keyManager.loads, after);
      },
    );

    test('an undecryptable command is held instead of pinning the '
        'checkpoint, and applied once its key arrives', () async {
      final late = _command(
        client.room,
        'late',
        envelopeDevice: 'PHONE',
        session: null,
        sessionId: 'session-late',
      );
      final encrypted = Event(
        room: client.room,
        eventId: late.eventId,
        type: EventTypes.Encrypted,
        senderId: _owner,
        originServerTs: _t0,
        content: Map<String, dynamic>.from(late.originalSource!.content),
      );
      // Newest first, as in an SDK timeline.
      client.room.timeline.events.addAll([
        _command(client.room, 'after', envelopeDevice: 'PHONE', session: phone),
        encrypted,
        _command(
          client.room,
          'genuine',
          envelopeDevice: 'PHONE',
          session: phone,
        ),
      ]);
      await journal.start();
      expect(store.hasCommand('genuine'), isTrue);
      expect(store.hasCommand('after'), isTrue);
      expect(store.hasCommand('late'), isFalse);
      expect(journal.heldEvents, 1);
      // Before, the checkpoint stayed before every undecrypted event.
      expect(store.checkpoint(WorkerJournal.checkpointKey), r'$after');
      expect(jsonDecode(store.checkpoint(WorkerJournal.heldKey)!), [
        late.eventId,
      ]);
      // The key arrives (direct share from the phone).
      final session = _Session('session-late', 'curve-PHONE', 'ed-PHONE');
      session.plaintexts[late.eventId] = Map.of(late.content);
      client.encryption.keyManager.sessions[session.sessionId] = session;
      client.room.onSessionKeyReceived.add('session-late');
      await Future<void>.delayed(Duration.zero);
      await journal.reconcile();
      expect(store.hasCommand('late'), isTrue);
      expect(journal.heldEvents, 0);
      expect(store.checkpoint(WorkerJournal.checkpointKey), r'$after');
      expect(jsonDecode(store.checkpoint(WorkerJournal.heldKey)!), isEmpty);
    });

    test('held events survive a restart and are read again by id', () async {
      final late = _command(
        client.room,
        'late',
        envelopeDevice: 'PHONE',
        session: null,
        sessionId: 'session-late',
      );
      final encrypted = Event(
        room: client.room,
        eventId: late.eventId,
        type: EventTypes.Encrypted,
        senderId: _owner,
        originServerTs: _t0,
        content: Map<String, dynamic>.from(late.originalSource!.content),
      );
      client.room.timeline.events.addAll([
        encrypted,
        _command(
          client.room,
          'genuine',
          envelopeDevice: 'PHONE',
          session: phone,
        ),
      ]);
      await journal.start();
      journal.dispose();
      // Restart: the timeline only holds events after the checkpoint.
      client.room.timeline.events.clear();
      client.room.stored[late.eventId] = encrypted;
      final session = _Session('session-late', 'curve-PHONE', 'ed-PHONE');
      session.plaintexts[late.eventId] = Map.of(late.content);
      client.encryption.keyManager.sessions[session.sessionId] = session;
      final restarted = WorkerJournal(
        client,
        _roomId,
        {'PHONE', 'WORKER'},
        store,
        WorkerEngine(store, _NoTransport(), _NoTranscriber()),
      );
      addTearDown(restarted.dispose);
      client.room.timeline.events.add(
        _command(client.room, 'fresh', envelopeDevice: 'PHONE', session: phone),
      );
      await restarted.start();
      expect(store.hasCommand('late'), isTrue);
      expect(store.hasCommand('fresh'), isTrue);
    });
  });

  group('journal publication (CB-01 hardening)', () {
    late WorkerStore store;
    late WorkerJournal journal;
    var now = DateTime.utc(2026, 10, 21, 12);
    void enqueue(String id) => store.enqueue(
      id,
      PersonalOperation(
        opId: id,
        kind: 'worker.heartbeat',
        entityId: 'worker',
        createdAt: now,
        payload: {'healthy': true},
      ).toJson(),
    );
    setUp(() {
      now = DateTime.utc(2026, 10, 21, 12);
      client.room.timeline.events.add(
        _command(
          client.room,
          'genuine',
          envelopeDevice: 'PHONE',
          session: phone,
        ),
      );
      store = WorkerStore(sqlite3.openInMemory());
      journal = WorkerJournal(
        client,
        _roomId,
        {'PHONE', 'WORKER'},
        store,
        WorkerEngine(store, _NoTransport(), _NoTranscriber()),
        clock: () => now,
      );
    });
    tearDown(() => journal.dispose());

    test(
      'an entry refused as too large is parked; the queue continues',
      () async {
        for (final id in ['a', 'b', 'c']) {
          enqueue(id);
        }
        client.room.failures['b'] = EventTooLarge(60000, 70000);
        await journal.flush();
        expect(client.room.sent.values.map((body) => body['opId']), ['a', 'c']);
        expect(store.outboxIds, isEmpty);
        expect(store.parkedCount, 1);
        final parked = store.db.select('SELECT id, error FROM outbox_parked');
        expect(parked.single['id'], 'b');
        expect(parked.single['error'], 'result_too_large');
        // The homeserver's own refusal counts the same.
        enqueue('d');
        client.room.failures['d'] = MatrixException.fromJson({
          'errcode': 'M_TOO_LARGE',
          'error': 'synthetic',
        });
        enqueue('e');
        await journal.flush();
        expect(store.parkedCount, 2);
        expect(client.room.sent.values.last['opId'], 'e');
      },
    );

    test('one entry failing does not block the others; a connection '
        'failure ends the pass', () async {
      for (final id in ['a', 'b', 'c', 'd']) {
        enqueue(id);
      }
      client.room.failures['b'] = Exception('synthetic transport failure');
      await journal.flush();
      expect(client.room.sent.values.map((body) => body['opId']), [
        'a',
        'c',
        'd',
      ]);
      expect(store.outboxIds, ['b']);
      // Keeps failing while others go through: parked, then queued again
      // after a while.
      for (var pass = 0; pass < WorkerJournal.maxEntryFailures; pass++) {
        enqueue('ok$pass');
        await journal.flush();
      }
      expect(store.outboxIds, isEmpty);
      expect(store.parkedCount, 1);
      client.room.failures.remove('b');
      now = now.add(WorkerJournal.parkedRetry);
      await journal.flush();
      expect(store.parkedCount, 0);
      expect(client.room.sent.values.last['opId'], 'b');
      // Everything failing (no connection): two attempts, then the pass ends.
      for (final id in ['x', 'y', 'z']) {
        enqueue(id);
        client.room.failures[id] = Exception('offline');
      }
      client.room.attempts.clear();
      await journal.flush();
      expect(client.room.attempts, ['x', 'y']);
      expect(store.outboxIds, ['x', 'y', 'z']);
    });

    test('rate limiting defers the next pass', () async {
      enqueue('a');
      enqueue('b');
      client.room.failures['a'] = MatrixException.fromJson({
        'errcode': 'M_LIMIT_EXCEEDED',
        'error': 'synthetic',
        'retry_after_ms': 30000,
      });
      await journal.flush();
      expect(client.room.attempts, ['a']);
      client.room.failures.clear();
      await journal.flush();
      expect(client.room.attempts, ['a'], reason: 'not before retry_after');
      now = now.add(const Duration(seconds: 31));
      await journal.flush();
      expect(store.outboxIds, isEmpty);
    });
  });
}
