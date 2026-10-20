// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/journal_trust.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/encryption/utils/session_key.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

const _owner = '@synthetic:example.org';
const _roomId = '!synthetic-journal:example.org';
final _t0 = DateTime.utc(2026, 10, 18, 8);

class _Device implements DeviceKeys {
  _Device(this.curve25519Key, this.ed25519Key, {this.verified = true});
  @override
  final String? curve25519Key;
  @override
  final String? ed25519Key;
  @override
  final bool verified;
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
    this.sessionId, {
    required this.senderKey,
    String? ed25519,
    List<String> chain = const [],
    Map<String, dynamic>? content,
  }) : senderClaimedKeys = {'ed25519': ?ed25519},
       forwardingCurve25519KeyChain = chain,
       content =
           content ??
           {
             'algorithm': megolmAlgorithm,
             'room_id': _roomId,
             'session_id': sessionId,
             'session_key': 'synthetic',
             if (chain.isNotEmpty) 'forwarding_curve25519_key_chain': chain,
           };
  @override
  final String sessionId;
  @override
  String get roomId => _roomId;
  @override
  final String senderKey;
  @override
  Map<String, String> senderClaimedKeys;
  @override
  final List<String> forwardingCurve25519KeyChain;
  @override
  Map<String, dynamic> content;
  @override
  Map<String, String> indexes = {};
  @override
  bool get isValid => true;

  /// Ciphertexts this session decrypts, and to what content.
  final plaintexts = <String, Map<String, dynamic>>{};

  void decrypted(Event event) => indexes['key-${indexes.length}'] =
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
  ) async => roomId == _roomId ? sessions[sessionId] : null;
  @override
  SessionKey? getInboundGroupSession(String roomId, String sessionId) =>
      roomId == _roomId ? sessions[sessionId] : null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Encryption implements Encryption {
  @override
  final _KeyManager keyManager = _KeyManager();
  int decryptions = 0;

  /// Decrypts like the SDK: with the current session, recording its index.
  @override
  Future<Event> decryptRoomEvent(
    Event event, {
    bool store = false,
    EventUpdateType updateType = EventUpdateType.timeline,
  }) async {
    decryptions++;
    final session = keyManager.sessions[event.content['session_id']];
    final plaintext = session?.plaintexts[event.content['ciphertext']];
    if (session == null || plaintext == null) {
      return Event(
        room: event.room,
        eventId: event.eventId,
        type: EventTypes.Encrypted,
        senderId: event.senderId,
        originServerTs: event.originServerTs,
        content: {
          ...event.content,
          'msgtype': MessageTypes.BadEncrypted,
          'can_request_session': true,
        },
        originalSource: event,
      );
    }
    session.decrypted(event);
    return Event(
      room: event.room,
      eventId: event.eventId,
      type: personalEventType,
      senderId: event.senderId,
      originServerTs: event.originServerTs,
      content: plaintext,
      originalSource: event,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client implements Client {
  @override
  String? userID = _owner;
  @override
  final Map<String, DeviceKeysList> userDeviceKeys = {
    _owner: _Keys(),
    '@bridgebot:example.org': _Keys(),
  };
  @override
  Future<dynamic>? userDeviceKeysLoading = Future<void>.value();
  final crypto = _Encryption();
  @override
  Encryption? get encryption => crypto;

  void device(
    String curve,
    String ed25519, {
    String user = _owner,
    bool verified = true,
  }) => userDeviceKeys[user]!.deviceKeys[curve] = _Device(
    curve,
    ed25519,
    verified: verified,
  );

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
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A journal result encrypted with [session] (envelope [senderKey], which a
/// forger may set to anything) that the SDK decrypted with [decryptedBy].
Event _result(
  _Room room,
  String id, {
  required String session,
  required String senderKey,
  _Session? decryptedBy,
  String sender = _owner,
  DateTime? at,
}) {
  final content = PersonalOperation(
    opId: id,
    kind: 'metadata.result',
    entityId: 'org:$id',
    createdAt: at ?? _t0,
    payload: {'revision': 1},
  ).toJson().cast<String, dynamic>();
  final original = MatrixEvent(
    type: EventTypes.Encrypted,
    content: {
      'algorithm': megolmAlgorithm,
      'sender_key': senderKey,
      'session_id': session,
      'ciphertext': 'cipher-$id',
    },
    senderId: sender,
    eventId: '\$$id',
    originServerTs: at ?? _t0,
  );
  final event = Event(
    room: room,
    eventId: '\$$id',
    type: personalEventType,
    senderId: sender,
    originServerTs: at ?? _t0,
    content: content,
    originalSource: original,
  );
  decryptedBy?.plaintexts['cipher-$id'] = content;
  decryptedBy?.decrypted(event);
  return event;
}

Event _undecrypted(
  _Room room,
  String id, {
  required String session,
  required String senderKey,
  DateTime? at,
}) {
  final original = MatrixEvent(
    type: EventTypes.Encrypted,
    content: {
      'algorithm': megolmAlgorithm,
      'sender_key': senderKey,
      'session_id': session,
      'ciphertext': 'cipher-$id',
    },
    senderId: _owner,
    eventId: '\$$id',
    originServerTs: at ?? _t0,
  );
  return Event(
    room: room,
    eventId: '\$$id',
    type: EventTypes.Encrypted,
    senderId: _owner,
    originServerTs: at ?? _t0,
    content: {
      ...original.content,
      'msgtype': MessageTypes.BadEncrypted,
      'can_request_session': true,
    },
    originalSource: original,
  );
}

Future<MegolmTrustSnapshot> _capture(
  _Client client,
  _Room room,
  List<Event> events, {
  String? userId,
}) async {
  final trust = MegolmTrustSnapshot.devices(client, userId: userId);
  await trust.capture(room, events);
  return trust;
}

void main() {
  late _Client client;
  late _Room room;
  late _Session worker;
  setUp(() {
    client = _Client()
      ..device('curve-worker', 'ed-worker')
      ..device('curve-phone', 'ed-phone');
    room = _Room(client);
    worker = _Session(
      'session-worker',
      senderKey: 'curve-worker',
      ed25519: 'ed-worker',
    );
    client.crypto.keyManager.sessions[worker.sessionId] = worker;
  });

  test('a result from the verified worker session is trusted', () async {
    final event = _result(
      room,
      'ok',
      session: worker.sessionId,
      senderKey: 'curve-worker',
      decryptedBy: worker,
    );
    final trust = await _capture(client, room, [event]);
    expect(trust.verdict(event), MegolmTrust.trusted);
    expect(trust.trusts(event), isTrue);
    expect(await MegolmTrustSnapshot.verify(event), isTrue);
    expect(client.crypto.decryptions, 0, reason: 'Index proof, no re-decrypt');
  });

  test(
    'forged envelope sender_key with an unverified device session is refused',
    () async {
      // A token holder's unverified device delivered this session over Olm;
      // the envelope claims the verified worker's curve25519 key.
      client.device('curve-bridge', 'ed-bridge', verified: false);
      final forged = _Session(
        'session-forged',
        senderKey: 'curve-bridge',
        ed25519: 'ed-bridge',
      );
      client.crypto.keyManager.sessions[forged.sessionId] = forged;
      final event = _result(
        room,
        'forged',
        session: forged.sessionId,
        senderKey: 'curve-worker',
        decryptedBy: forged,
      );
      final trust = await _capture(client, room, [event]);
      expect(trust.verdict(event), MegolmTrust.envelopeMismatch);
      expect(trust.trusts(event), isFalse);
      expect(trust.mayLaterTrust(event), isFalse);
      expect(await MegolmTrustSnapshot.verify(event), isFalse);

      // Honest envelope, unverified device: held until verified.
      final honest = _result(
        room,
        'honest',
        session: forged.sessionId,
        senderKey: 'curve-bridge',
        decryptedBy: forged,
      );
      final again = await _capture(client, room, [honest]);
      expect(again.verdict(honest), MegolmTrust.unverifiedDevice);
      expect(again.mayLaterTrust(honest), isTrue);
    },
  );

  test('the ed25519 claim must match the verified device too', () async {
    worker.senderClaimedKeys = {'ed25519': 'ed-phone'};
    final event = _result(
      room,
      'cross',
      session: worker.sessionId,
      senderKey: 'curve-worker',
      decryptedBy: worker,
    );
    final trust = await _capture(client, room, [event]);
    expect(trust.verdict(event), MegolmTrust.unverifiedDevice);
  });

  test(
    'forwarded and key-backup sessions are refused for the journal',
    () async {
      final forwarded = _Session(
        'session-forwarded',
        senderKey: 'curve-phone',
        ed25519: 'ed-worker',
        chain: ['curve-phone'],
      );
      final backup = _Session(
        'session-backup',
        senderKey: 'curve-worker',
        ed25519: 'ed-worker',
        content: {
          'algorithm': megolmAlgorithm,
          'sender_key': 'curve-worker',
          'sender_claimed_keys': {'ed25519': 'ed-worker'},
          'forwarding_curve25519_key_chain': <String>[],
          'session_key': 'synthetic',
          'session_id': 'session-backup',
          'room_id': _roomId,
        },
      );
      client.crypto.keyManager.sessions
        ..[forwarded.sessionId] = forwarded
        ..[backup.sessionId] = backup;
      final viaForward = _result(
        room,
        'forward',
        session: forwarded.sessionId,
        senderKey: 'curve-phone',
        decryptedBy: forwarded,
      );
      final viaBackup = _result(
        room,
        'backup',
        session: backup.sessionId,
        senderKey: 'curve-worker',
        decryptedBy: backup,
      );
      final trust = await _capture(client, room, [viaForward, viaBackup]);
      expect(trust.verdict(viaForward), MegolmTrust.importedSession);
      expect(trust.verdict(viaBackup), MegolmTrust.importedSession);
      expect(trust.mayLaterTrust(viaBackup), isFalse);
    },
  );

  test('a missing session is untrusted but may still arrive', () async {
    final event = _result(
      room,
      'orphan',
      session: 'session-unknown',
      senderKey: 'curve-worker',
    );
    final trust = await _capture(client, room, [event]);
    expect(trust.verdict(event), MegolmTrust.missingSession);
    expect(trust.mayLaterTrust(event), isTrue);
  });

  test(
    'a session swapped in after decryption re-proves by decrypting again',
    () async {
      // Decrypted earlier by a session that has since been replaced: the
      // current one has no index entry for it.
      final event = _result(
        room,
        'swapped',
        session: worker.sessionId,
        senderKey: 'curve-worker',
      );
      // The current (genuine) session cannot decrypt that ciphertext.
      final forgedLater = await _capture(client, room, [event]);
      expect(forgedLater.verdict(event), MegolmTrust.notDecryptedBySession);
      expect(forgedLater.mayLaterTrust(event), isFalse);
      expect(client.crypto.decryptions, 1);

      // It can, to the same content: the index lagged (another process).
      worker.plaintexts['cipher-swapped'] = Map.of(event.content);
      final lagging = await _capture(client, room, [event]);
      expect(lagging.verdict(event), MegolmTrust.trusted);

      // It decrypts to something else: refused.
      final other = _result(
        room,
        'other',
        session: worker.sessionId,
        senderKey: 'curve-worker',
      );
      worker.plaintexts['cipher-other'] = {'kind': 'different'};
      final differs = await _capture(client, room, [other]);
      expect(differs.verdict(other), MegolmTrust.notDecryptedBySession);
    },
  );

  test('undecrypted events: re-decrypted, held or settled for good', () async {
    final lateSession = _Session(
      'session-late',
      senderKey: 'curve-phone',
      ed25519: 'ed-phone',
    );
    // Its key is present now and decrypts it.
    final arrived = _undecrypted(
      room,
      'arrived',
      session: lateSession.sessionId,
      senderKey: 'curve-phone',
    );
    lateSession.plaintexts['cipher-arrived'] = PersonalOperation(
      opId: 'arrived',
      kind: 'metadata.result',
      entityId: 'org:arrived',
      createdAt: _t0,
      payload: {'revision': 1},
    ).toJson().cast<String, dynamic>();
    client.crypto.keyManager.sessions[lateSession.sessionId] = lateSession;
    // Its session is present but cannot decrypt it (below the first index).
    final belowIndex = _undecrypted(
      room,
      'below',
      session: worker.sessionId,
      senderKey: 'curve-worker',
    );
    // No session; the worker has sent newer events with a direct session.
    final older = _undecrypted(
      room,
      'older',
      session: 'session-old',
      senderKey: 'curve-worker',
      at: _t0,
    );
    final newer = _result(
      room,
      'newer',
      session: worker.sessionId,
      senderKey: 'curve-worker',
      decryptedBy: worker,
      at: _t0.add(const Duration(minutes: 5)),
    );
    // No session and nothing newer from that device: a key may still come.
    final waiting = _undecrypted(
      room,
      'waiting',
      session: 'session-waiting',
      senderKey: 'curve-other',
    );
    final foreign = _undecrypted(
      room,
      'foreign',
      session: 'session-x',
      senderKey: 'curve-worker',
    );
    final foreignSender = Event(
      room: room,
      eventId: foreign.eventId,
      type: EventTypes.Encrypted,
      senderId: '@intruder:example.org',
      originServerTs: _t0,
      content: foreign.content,
    );
    final trust = await _capture(client, room, [
      arrived,
      belowIndex,
      older,
      newer,
      waiting,
      foreignSender,
    ]);
    final decrypted = trust.redecrypted[arrived.eventId]!;
    expect(decrypted.type, personalEventType);
    expect(trust.verdict(decrypted), MegolmTrust.trusted);
    expect(trust.redecrypted.containsKey(belowIndex.eventId), isFalse);
    expect(trust.mayLaterTrust(belowIndex), isFalse);
    expect(trust.mayLaterTrust(older), isFalse);
    expect(trust.mayLaterTrust(waiting), isTrue);
    expect(trust.mayLaterTrust(foreignSender), isFalse);
  });

  test(
    'verdicts are fixed per snapshot (same answer for batch and settle)',
    () async {
      final event = _result(
        room,
        'pending-device',
        session: 'session-phone2',
        senderKey: 'curve-phone2',
      );
      final phone2 = _Session(
        'session-phone2',
        senderKey: 'curve-phone2',
        ed25519: 'ed-phone2',
      )..decrypted(event);
      client.crypto.keyManager.sessions[phone2.sessionId] = phone2;
      final trust = await _capture(client, room, [event]);
      expect(trust.trusts(event), isFalse);
      client.device('curve-phone2', 'ed-phone2');
      expect(trust.trusts(event), isFalse, reason: 'Snapshot taken before');
      expect(
        MegolmTrustSnapshot.fingerprintOf(client),
        isNot(trust.fingerprint),
      );
      final next = await _capture(client, room, [event]);
      expect(next.trusts(event), isTrue);
    },
  );

  test('bridge media states use the bridge bot devices', () async {
    const bot = '@bridgebot:example.org';
    client.device('curve-bot', 'ed-bot', user: bot);
    final session = _Session(
      'session-bot',
      senderKey: 'curve-bot',
      ed25519: 'ed-bot',
    );
    client.crypto.keyManager.sessions[session.sessionId] = session;
    final state = _result(
      room,
      'state',
      session: session.sessionId,
      senderKey: 'curve-bot',
      decryptedBy: session,
      sender: bot,
    );
    expect(await MegolmTrustSnapshot.verify(state, userId: bot), isTrue);
    expect(await MegolmTrustSnapshot.verify(state), isFalse);
    final forgedBot = _result(
      room,
      'forged-state',
      session: worker.sessionId,
      senderKey: 'curve-bot',
      decryptedBy: worker,
      sender: bot,
    );
    expect(await MegolmTrustSnapshot.verify(forgedBot, userId: bot), isFalse);
  });
}
