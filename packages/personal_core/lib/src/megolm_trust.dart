// SPDX-License-Identifier: AGPL-3.0-or-later

/// Who really encrypted a megolm event: the rule shared by the app and the
/// worker for the private journal (and other channels where a verified device
/// of a known user must have written an event).
///
/// The `sender_key` in a megolm envelope is chosen by whoever encrypted the
/// event and is not authenticated by Matrix: the SDK picks the inbound session
/// by room and session id only. Anyone holding the account's access token (a
/// double-puppeting bridge, the homeserver) can encrypt an event as the owner
/// with a session of an unverified device of theirs and copy a verified
/// device's curve25519 key into the envelope. The only authenticated sender is
/// the device that delivered the session itself over Olm, so trust is derived
/// from the inbound session which decrypted the event:
///
/// 1. The event is the owner's, its original is `m.room.encrypted` with a
///    well-formed megolm envelope, and it was decrypted.
/// 2. The inbound session for the envelope's room and session id exists and
///    its recorded sender curve25519 key equals the envelope's `sender_key`.
/// 3. The session was delivered directly (an Olm `m.room_key`): no forwarding
///    chain and none of the fields only forwarded or key-backup sessions carry.
///    Forwarded and backup sessions are self-asserted. The online key backup
///    (`m.megolm_backup.v1.curve25519-aes-sha2`) is writable by every holder of
///    the access token and its content is not authenticated; the SDK has no
///    backup-trust signal, and it stores the forwarder (not the originator) as a
///    forwarded session's sender key, so neither kind can be tied to a verified
///    originator. They fail closed here (ordinary chats are unaffected).
/// 4. That very session decrypted this event: its replay-protection index maps
///    a message index to this event id and timestamp. A session replaced later
///    (the SDK swaps in one with a lower first index) cannot vouch for events
///    an earlier session decrypted.
/// 5. A verified device has BOTH identity keys of the session: curve25519 ==
///    the session's sender key and ed25519 == its claimed ed25519 key.
library;

const megolmAlgorithm = 'm.megolm.v1.aes-sha2';

/// Identity keys of one verified device, from its signed device keys.
class VerifiedDeviceKeys {
  final String curve25519;
  final String ed25519;
  const VerifiedDeviceKeys(this.curve25519, this.ed25519);

  @override
  bool operator ==(Object other) =>
      other is VerifiedDeviceKeys &&
      other.curve25519 == curve25519 &&
      other.ed25519 == ed25519;

  @override
  int get hashCode => Object.hash(curve25519, ed25519);
}

/// Stable description of a verified device set: it changes whenever a device
/// is verified, revoked or its keys change.
String verifiedDevicesFingerprint(
  String? userId,
  Iterable<VerifiedDeviceKeys> devices,
) {
  final keys = [for (final d in devices) '${d.curve25519}|${d.ed25519}']
    ..sort();
  return [userId ?? '', ...keys].join('\n');
}

/// The authenticated parts of a megolm envelope.
class MegolmEnvelope {
  final String senderKey;
  final String sessionId;
  const MegolmEnvelope(this.senderKey, this.sessionId);

  /// Null unless [content] is a megolm envelope with a sender key and session.
  static MegolmEnvelope? parse(Map<String, Object?>? content) {
    if (content == null || content['algorithm'] != megolmAlgorithm) {
      return null;
    }
    final senderKey = content['sender_key'];
    final sessionId = content['session_id'];
    if (senderKey is! String ||
        senderKey.isEmpty ||
        sessionId is! String ||
        sessionId.isEmpty) {
      return null;
    }
    return MegolmEnvelope(senderKey, sessionId);
  }
}

/// What the Matrix SDK recorded about one inbound megolm session.
class MegolmSessionFacts {
  final String roomId;
  final String sessionId;

  /// Curve25519 key stored with the session: the Olm sender of an `m.room_key`
  /// (authenticated), else whatever a forwarder or the key backup claimed.
  final String senderKey;
  final String? claimedEd25519;

  /// Delivered by key forwarding, key backup or an import, not by an Olm
  /// `m.room_key` from its creator.
  final bool imported;

  /// Live replay-protection index of the session: message index → the
  /// `eventId|originServerTs` it decrypted.
  final Map<String, String> decryptions;

  const MegolmSessionFacts({
    required this.roomId,
    required this.sessionId,
    required this.senderKey,
    required this.claimedEd25519,
    required this.imported,
    required this.decryptions,
  });

  /// From the SDK's `SessionKey` fields. A direct `m.room_key` session keeps
  /// the event content (`algorithm`, `room_id`, `session_id`, `session_key`):
  /// forwarded sessions always get a forwarding chain (the receiver appends the
  /// forwarder), key-backup sessions always carry `sender_key` (and normally
  /// `sender_claimed_keys`). Anything carrying those markers is imported.
  factory MegolmSessionFacts.fromSdk({
    required String roomId,
    required String sessionId,
    required String senderKey,
    required Map<String, String> senderClaimedKeys,
    required List<String> forwardingChain,
    required Map<String, Object?> content,
    required Map<String, String> indexes,
  }) {
    final chain = content['forwarding_curve25519_key_chain'];
    return MegolmSessionFacts(
      roomId: roomId,
      sessionId: sessionId,
      senderKey: senderKey,
      claimedEd25519: senderClaimedKeys['ed25519'],
      imported:
          forwardingChain.isNotEmpty ||
          (chain is List && chain.isNotEmpty) ||
          content.containsKey('sender_key') ||
          content.containsKey('sender_claimed_keys') ||
          content.containsKey('sender_claimed_ed25519_key'),
      decryptions: indexes,
    );
  }

  /// Whether this session's replay index records decrypting this event.
  bool decrypted(String eventId, int originServerTsMs) {
    final value = '$eventId|$originServerTsMs';
    for (final entry in decryptions.values) {
      if (entry == value) return true;
    }
    return false;
  }
}

enum MegolmTrust {
  trusted,

  /// Not sent by the expected user.
  wrongSender,

  /// Not end-to-end encrypted originally.
  notEncrypted,

  /// Still `m.room.encrypted`: no plaintext to trust.
  undecrypted,

  /// No megolm algorithm, sender key or session id in the envelope.
  malformedEnvelope,

  /// No inbound session for the envelope's room and session id (yet).
  missingSession,

  /// The session's own room or id disagrees with the envelope.
  sessionMismatch,

  /// The envelope names a different sender key than the session records.
  envelopeMismatch,

  /// Forwarded, key-backup or imported session: originator unauthenticated.
  importedSession,

  /// The session's replay index does not record this event (not re-proven).
  unproven,

  /// Re-decrypting the original with the session failed or disagreed.
  notDecryptedBySession,

  /// No verified device has both of the session's identity keys (yet).
  unverifiedDevice;

  /// Whether a later device verification, key arrival or re-decryption can
  /// still turn this verdict into [trusted]. Every other verdict is final for
  /// the event: re-applying the rule to it can only fail again.
  bool get mayChange =>
      this == MegolmTrust.unverifiedDevice ||
      this == MegolmTrust.missingSession ||
      this == MegolmTrust.unproven;
}

/// The trust rule (see the library documentation).
MegolmTrust megolmTrust({
  required String senderId,
  required String? expectedSenderId,
  required bool decrypted,
  required String? originalType,
  required Map<String, Object?>? envelopeContent,
  required String roomId,
  required String eventId,
  required int originServerTsMs,
  required MegolmSessionFacts? session,
  required Iterable<VerifiedDeviceKeys> verifiedDevices,
}) {
  if (expectedSenderId == null || senderId != expectedSenderId) {
    return MegolmTrust.wrongSender;
  }
  if (originalType != 'm.room.encrypted') return MegolmTrust.notEncrypted;
  if (!decrypted) return MegolmTrust.undecrypted;
  final envelope = MegolmEnvelope.parse(envelopeContent);
  if (envelope == null) return MegolmTrust.malformedEnvelope;
  if (session == null) return MegolmTrust.missingSession;
  if (session.roomId != roomId || session.sessionId != envelope.sessionId) {
    return MegolmTrust.sessionMismatch;
  }
  if (session.senderKey != envelope.senderKey) {
    return MegolmTrust.envelopeMismatch;
  }
  if (session.imported) return MegolmTrust.importedSession;
  if (!session.decrypted(eventId, originServerTsMs)) {
    return MegolmTrust.unproven;
  }
  final ed25519 = session.claimedEd25519;
  if (ed25519 == null || ed25519.isEmpty) return MegolmTrust.unverifiedDevice;
  for (final device in verifiedDevices) {
    if (device.curve25519 == session.senderKey && device.ed25519 == ed25519) {
      return MegolmTrust.trusted;
    }
  }
  return MegolmTrust.unverifiedDevice;
}

/// Whether an own event that is still undecrypted can never become trusted,
/// so a journal may settle it instead of holding it.
///
/// - Another sender or a malformed envelope never passes [megolmTrust].
/// - [sessionPresent]: an inbound session for its id exists and a decryption
///   attempt with it failed in this pass. The ciphertext predates the
///   session's first known index (or is corrupt): only a session with a lower
///   first index could decrypt it, and senders share a session directly only
///   at their current index, so that can only be an imported session, which is
///   never trusted.
/// - [newestDirectFromSender]: this client decrypted a newer event (later
///   server timestamp) from the same sender key with a session it received
///   directly. A sender shares a session with a device before encrypting with
///   it and to-device messages reach a device in order, so a direct key for
///   this event's older session, had it ever been sent to this device, would
///   have arrived before that newer one. Losing a key in transit only makes
///   the event undecryptable, never trusted, so settling it is safe.
bool megolmUndecryptableForGood({
  required String senderId,
  required String? expectedSenderId,
  required Map<String, Object?>? envelopeContent,
  required int originServerTsMs,
  required bool sessionPresent,
  required int? newestDirectFromSender,
}) {
  if (expectedSenderId == null || senderId != expectedSenderId) return true;
  if (MegolmEnvelope.parse(envelopeContent) == null) return true;
  if (sessionPresent) return true;
  return newestDirectFromSender != null &&
      newestDirectFromSender > originServerTsMs;
}

/// Structural equality of decoded JSON values.
bool jsonValueEquals(Object? a, Object? b) {
  if (a is Map && b is Map) {
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (!b.containsKey(entry.key) ||
          !jsonValueEquals(entry.value, b[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (a is List && b is List) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!jsonValueEquals(a[i], b[i])) return false;
    }
    return true;
  }
  return a == b;
}
