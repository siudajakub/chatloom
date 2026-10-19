// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/encryption.dart';
import 'package:matrix/encryption/utils/session_key.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// Which journal commands the worker accepts: [megolmTrust] (personal_core)
/// with the devices pinned in the worker configuration.
///
/// The envelope `sender_key` is not authenticated, so a command counts as
/// written by a pinned verified device only when the inbound megolm session
/// that decrypted it was delivered directly by that device (curve25519 and
/// ed25519 both match), names the same sender key and recorded decrypting this
/// very event. Forwarded and key-backup sessions are refused: the backup is
/// writable by every holder of the account's access token.
class WorkerJournalTrust {
  WorkerJournalTrust._(this._client, this.userId, this.devices);

  /// Verified, unblocked own devices whose id is in [pinned], now.
  factory WorkerJournalTrust.of(Client client, Set<String> pinned) {
    final userId = client.userID;
    return WorkerJournalTrust._(client, userId, [
      for (final device
          in client.userDeviceKeys[userId]?.deviceKeys.values ??
              const <DeviceKeys>[])
        if (pinned.contains(device.deviceId) &&
            device.verified &&
            !device.blocked &&
            device.curve25519Key != null &&
            device.ed25519Key != null)
          VerifiedDeviceKeys(device.curve25519Key!, device.ed25519Key!),
    ]);
  }

  final Client _client;
  final String? userId;
  final List<VerifiedDeviceKeys> devices;
  String? _roomId;
  bool _captured = false;
  final _sessions = <String, MegolmSessionFacts?>{};
  final _failedProof = <String>{};
  final _verdicts = <String, MegolmTrust>{};

  /// One event, e.g. an authenticated read-back.
  static Future<bool> verify(
    Client client,
    Event event,
    Set<String> pinned,
  ) async {
    await client.userDeviceKeysLoading;
    final trust = WorkerJournalTrust.of(client, pinned);
    await trust.capture(event.room, [event]);
    return trust.trusts(event);
  }

  /// Loads the inbound sessions of the decrypted own [events] in [room] and
  /// re-proves those missing from their session's replay index by decrypting
  /// the original again. Call once, before any verdict.
  Future<void> capture(Room room, Iterable<Event> events) async {
    if (_captured) throw StateError('Trust already captured');
    _captured = true;
    _roomId = room.id;
    final own = <String, Event>{
      for (final event in events)
        if (event.senderId == userId && event.type != EventTypes.Encrypted)
          event.eventId: event,
    };
    final encryption = _client.encryption;
    final sessionIds = <String>{};
    for (final event in own.values) {
      final envelope = MegolmEnvelope.parse(_envelopeOf(event));
      if (envelope != null) sessionIds.add(envelope.sessionId);
    }
    for (final sessionId in sessionIds) {
      SessionKey? session;
      try {
        session = await encryption?.keyManager.loadInboundGroupSession(
          room.id,
          sessionId,
        );
      } catch (_) {
        session = null;
      }
      _sessions[sessionId] = session == null || !session.isValid
          ? null
          : MegolmSessionFacts.fromSdk(
              roomId: session.roomId,
              sessionId: session.sessionId,
              senderKey: session.senderKey,
              senderClaimedKeys: _claimedKeys(session, encryption),
              forwardingChain: session.forwardingCurve25519KeyChain,
              content: session.content,
              indexes: session.indexes,
            );
    }
    if (encryption == null) return;
    for (final event in own.values) {
      final original = event.originalSource;
      if (original == null ||
          original.type != EventTypes.Encrypted ||
          _evaluate(event) != MegolmTrust.unproven) {
        continue;
      }
      final Event again;
      try {
        again = await encryption.decryptRoomEvent(
          Event.fromMatrixEvent(original, room),
        );
      } catch (_) {
        continue;
      }
      if (again.type != event.type ||
          !jsonValueEquals(again.content, event.content)) {
        _failedProof.add(event.eventId);
      }
    }
  }

  MegolmTrust verdict(Event event) => _verdicts.putIfAbsent(event.eventId, () {
    final verdict = _evaluate(event);
    // A failed re-decryption outranks an index entry it may have written.
    final failed = _failedProof.contains(event.eventId);
    return failed &&
            (verdict == MegolmTrust.trusted ||
                verdict == MegolmTrust.unverifiedDevice ||
                verdict == MegolmTrust.unproven)
        ? MegolmTrust.notDecryptedBySession
        : verdict;
  });

  bool trusts(Event event) => verdict(event) == MegolmTrust.trusted;

  MegolmTrust _evaluate(Event event) {
    final envelope = _envelopeOf(event);
    final parsed = MegolmEnvelope.parse(envelope);
    final encrypted = event.type == EventTypes.Encrypted;
    return megolmTrust(
      senderId: event.senderId,
      expectedSenderId: userId,
      decrypted: !encrypted,
      originalType: encrypted
          ? EventTypes.Encrypted
          : event.originalSource?.type,
      envelopeContent: envelope,
      roomId: _roomId ?? event.room.id,
      eventId: event.eventId,
      originServerTsMs: event.originServerTs.millisecondsSinceEpoch,
      session: parsed == null || !_captured
          ? null
          : _sessions[parsed.sessionId],
      verifiedDevices: devices,
    );
  }

  /// The SDK fills a direct session's claimed ed25519 key from the device
  /// list when the session arrives; this device's own outbound sessions may
  /// predate its own device keys there. Only this device can be the Olm
  /// sender (or creator) of a direct session with its own identity key.
  static Map<String, String> _claimedKeys(
    SessionKey session,
    Encryption? encryption,
  ) {
    final claimed = session.senderClaimedKeys;
    if (claimed['ed25519'] != null || encryption == null) return claimed;
    final ownCurve = encryption.identityKey;
    final ownEd25519 = encryption.fingerprintKey;
    if (ownCurve == null ||
        ownEd25519 == null ||
        session.senderKey != ownCurve) {
      return claimed;
    }
    return {...claimed, 'ed25519': ownEd25519};
  }

  static Map<String, Object?>? _envelopeOf(Event event) {
    final original = event.originalSource;
    if (original != null && original.type == EventTypes.Encrypted) {
      return original.content;
    }
    return event.type == EventTypes.Encrypted ? event.content : null;
  }
}
