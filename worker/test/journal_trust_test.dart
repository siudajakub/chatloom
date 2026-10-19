// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/encryption.dart';
import 'package:matrix/encryption/utils/session_key.dart';
import 'package:matrix/matrix.dart';
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
  @override
  Future<SessionKey?> loadInboundGroupSession(
    String roomId,
    String sessionId,
  ) async => sessions[sessionId];
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
}
