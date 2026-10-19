// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:personal_core/personal_core.dart';
import 'package:test/test.dart';

const _owner = '@synthetic:example.org';
const _room = '!synthetic-journal:example.org';
const _worker = VerifiedDeviceKeys('curve-worker', 'ed-worker');
const _phone = VerifiedDeviceKeys('curve-phone', 'ed-phone');
const _ts = 1760000000000;

Map<String, Object?> _envelope({
  String senderKey = 'curve-worker',
  String sessionId = 'session-a',
}) => {
  'algorithm': megolmAlgorithm,
  'sender_key': senderKey,
  'session_id': sessionId,
  'ciphertext': 'synthetic',
};

MegolmSessionFacts _session({
  String senderKey = 'curve-worker',
  String? claimed = 'ed-worker',
  String sessionId = 'session-a',
  List<String> chain = const [],
  Map<String, Object?> content = const {
    'algorithm': megolmAlgorithm,
    'room_id': _room,
    'session_id': 'session-a',
    'session_key': 'synthetic',
  },
  bool decryptedThis = true,
}) => MegolmSessionFacts.fromSdk(
  roomId: _room,
  sessionId: sessionId,
  senderKey: senderKey,
  senderClaimedKeys: {if (claimed != null) 'ed25519': claimed},
  forwardingChain: chain,
  content: content,
  indexes: {
    if (decryptedThis)
      'key-3':
          r'$result|'
          '$_ts',
  },
);

MegolmTrust _verdict({
  String sender = _owner,
  bool decrypted = true,
  String? originalType = 'm.room.encrypted',
  Map<String, Object?>? envelope,
  MegolmSessionFacts? session,
  bool noSession = false,
  List<VerifiedDeviceKeys> devices = const [_worker, _phone],
}) => megolmTrust(
  senderId: sender,
  expectedSenderId: _owner,
  decrypted: decrypted,
  originalType: originalType,
  envelopeContent: envelope ?? _envelope(),
  roomId: _room,
  eventId: r'$result',
  originServerTsMs: _ts,
  session: noSession ? null : session ?? _session(),
  verifiedDevices: devices,
);

void main() {
  test('a direct session of a verified device is trusted', () {
    expect(_verdict(), MegolmTrust.trusted);
  });

  test('a forged envelope sender_key does not borrow a verified device', () {
    // Session delivered over Olm by an unverified device of a token holder;
    // the envelope copies the worker's curve25519 key.
    final forged = _session(
      senderKey: 'curve-attacker',
      claimed: 'ed-attacker',
    );
    expect(_verdict(session: forged), MegolmTrust.envelopeMismatch);
    // Even an honest envelope stays untrusted: the device is not verified.
    expect(
      _verdict(
        envelope: _envelope(senderKey: 'curve-attacker'),
        session: forged,
      ),
      MegolmTrust.unverifiedDevice,
    );
  });

  test('both identity keys must belong to one verified device', () {
    expect(
      _verdict(session: _session(claimed: 'ed-phone')),
      MegolmTrust.unverifiedDevice,
    );
    expect(
      _verdict(session: _session(claimed: null)),
      isNot(MegolmTrust.trusted),
    );
    expect(
      _verdict(devices: const [VerifiedDeviceKeys('curve-worker', 'ed-other')]),
      MegolmTrust.unverifiedDevice,
    );
    expect(_verdict(devices: const []), MegolmTrust.unverifiedDevice);
    expect(MegolmTrust.unverifiedDevice.mayChange, isTrue);
  });

  test('forwarded sessions are refused, even via verified own devices', () {
    expect(
      _verdict(session: _session(chain: ['curve-phone'])),
      MegolmTrust.importedSession,
    );
    expect(
      _verdict(session: _session(chain: ['curve-worker'])),
      MegolmTrust.importedSession,
      reason: 'Indistinguishable from a forged key-backup entry',
    );
    expect(
      _verdict(
        session: _session(
          content: {
            'algorithm': megolmAlgorithm,
            'session_key': 'synthetic',
            'sender_claimed_ed25519_key': 'ed-worker',
            'forwarding_curve25519_key_chain': ['curve-phone'],
          },
        ),
      ),
      MegolmTrust.importedSession,
    );
    expect(MegolmTrust.importedSession.mayChange, isFalse);
  });

  test(
    'key-backup sessions are refused (backup content is unauthenticated)',
    () {
      for (final content in <Map<String, Object?>>[
        {
          'algorithm': megolmAlgorithm,
          'sender_key': 'curve-worker',
          'sender_claimed_keys': {'ed25519': 'ed-worker'},
          'forwarding_curve25519_key_chain': <String>[],
          'session_key': 'synthetic',
        },
        // A forged entry without the optional fields still names sender_key.
        {
          'algorithm': megolmAlgorithm,
          'sender_key': 'curve-worker',
          'session_key': 'synthetic',
        },
      ]) {
        expect(
          _verdict(session: _session(content: content)),
          MegolmTrust.importedSession,
        );
      }
    },
  );

  test('missing, mismatched or replaced sessions are not trusted', () {
    expect(_verdict(noSession: true), MegolmTrust.missingSession);
    expect(MegolmTrust.missingSession.mayChange, isTrue);
    expect(
      _verdict(session: _session(sessionId: 'session-b')),
      MegolmTrust.sessionMismatch,
    );
    expect(
      _verdict(session: _session(decryptedThis: false)),
      MegolmTrust.unproven,
      reason: 'A session replaced after decryption does not vouch for it',
    );
  });

  test('sender, encryption and envelope are checked first', () {
    expect(_verdict(sender: '@other:example.org'), MegolmTrust.wrongSender);
    expect(_verdict(originalType: null), MegolmTrust.notEncrypted);
    expect(_verdict(decrypted: false), MegolmTrust.undecrypted);
    expect(
      _verdict(envelope: {..._envelope(), 'algorithm': 'm.olm.v1'}),
      MegolmTrust.malformedEnvelope,
    );
    expect(
      _verdict(envelope: {..._envelope()}..remove('session_id')),
      MegolmTrust.malformedEnvelope,
    );
    expect(
      megolmTrust(
        senderId: _owner,
        expectedSenderId: null,
        decrypted: true,
        originalType: 'm.room.encrypted',
        envelopeContent: _envelope(),
        roomId: _room,
        eventId: r'$result',
        originServerTsMs: _ts,
        session: _session(),
        verifiedDevices: const [_worker],
      ),
      MegolmTrust.wrongSender,
    );
  });

  test('undecryptable events settle only when keys can no longer help', () {
    bool forGood({
      String sender = _owner,
      Map<String, Object?>? envelope,
      bool sessionPresent = false,
      int? newestDirect,
    }) => megolmUndecryptableForGood(
      senderId: sender,
      expectedSenderId: _owner,
      envelopeContent: envelope ?? _envelope(),
      originServerTsMs: _ts,
      sessionPresent: sessionPresent,
      newestDirectFromSender: newestDirect,
    );
    expect(forGood(), isFalse, reason: 'A direct key may still arrive');
    expect(forGood(newestDirect: _ts), isFalse);
    expect(forGood(newestDirect: _ts + 1), isTrue);
    expect(forGood(sessionPresent: true), isTrue);
    expect(forGood(sender: '@other:example.org'), isTrue);
    expect(forGood(envelope: const {'msgtype': 'm.bad.encrypted'}), isTrue);
  });

  test('device fingerprint covers both keys and ignores order', () {
    final a = verifiedDevicesFingerprint(_owner, const [_worker, _phone]);
    expect(verifiedDevicesFingerprint(_owner, const [_phone, _worker]), a);
    expect(
      verifiedDevicesFingerprint(_owner, const [
        VerifiedDeviceKeys('curve-worker', 'ed-rotated'),
        _phone,
      ]),
      isNot(a),
    );
    expect(verifiedDevicesFingerprint(_owner, const [_worker]), isNot(a));
  });

  test('JSON equality is structural', () {
    expect(
      jsonValueEquals(
        {
          'a': [
            1,
            {'b': 'c'},
          ],
          'd': null,
        },
        {
          'd': null,
          'a': [
            1,
            {'b': 'c'},
          ],
        },
      ),
      isTrue,
    );
    expect(jsonValueEquals({'a': 1}, {'a': 2}), isFalse);
    expect(jsonValueEquals({'a': 1}, {'a': 1, 'b': 1}), isFalse);
    expect(jsonValueEquals([1, 2], [2, 1]), isFalse);
  });
}
