// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/encryption.dart';
import 'package:matrix/encryption/utils/session_key.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

/// Device trust as journal replay and settlement see it during one pass.
abstract interface class JournalTrust {
  /// Written by a verified device of the expected user (see [megolmTrust]).
  bool trusts(Event event);

  /// For an event that is not trusted now: whether a later device
  /// verification, key arrival or re-decryption can still make it trusted.
  /// False means the event can never be trusted and need not be held.
  bool mayLaterTrust(Event event);
}

/// Megolm sender authentication for one set of events, captured once.
///
/// The verified device set is fixed when the snapshot is created; the inbound
/// sessions are loaded by [capture]. Every verdict is computed once per event
/// and then reused, so a replay batch and the watermark settlement of the same
/// pass can never disagree about an event (M1). The rule itself is
/// [megolmTrust] in `personal_core`; this class only reads the SDK.
class MegolmTrustSnapshot implements JournalTrust {
  MegolmTrustSnapshot._(
    this._client,
    this.userId,
    this.devices,
    this.fingerprint,
  );

  /// The verified devices of [userId] (default: the account owner) now.
  /// [include] narrows them further (for example to pinned device ids).
  factory MegolmTrustSnapshot.devices(
    Client client, {
    String? userId,
    bool Function(DeviceKeys device)? include,
  }) {
    final id = userId ?? client.userID;
    final devices = verifiedDevices(client, id, include: include);
    return MegolmTrustSnapshot._(
      client,
      id,
      List.unmodifiable(devices),
      verifiedDevicesFingerprint(id, devices),
    );
  }

  final Client _client;
  final String? userId;
  final List<VerifiedDeviceKeys> devices;

  /// Changes whenever a device of [userId] is verified, revoked or re-keyed.
  final String fingerprint;

  String? _roomId;
  bool _captured = false;
  final _sessions = <String, MegolmSessionFacts?>{};
  final _redecrypted = <String, Event>{};
  final _undecryptableWithSession = <String>{};
  final _failedProof = <String>{};
  final _newestDirect = <String, int>{};
  final _verdicts = <String, MegolmTrust>{};

  static List<VerifiedDeviceKeys> verifiedDevices(
    Client client,
    String? userId, {
    bool Function(DeviceKeys device)? include,
  }) {
    if (userId == null) return const [];
    final list = client.userDeviceKeys[userId];
    return [
      for (final device in list?.deviceKeys.values ?? const <DeviceKeys>[])
        if (device.verified &&
            device.curve25519Key != null &&
            device.ed25519Key != null &&
            (include?.call(device) ?? true))
          VerifiedDeviceKeys(device.curve25519Key!, device.ed25519Key!),
    ];
  }

  /// Fingerprint of the owner's verified devices right now.
  static String fingerprintOf(Client client) => verifiedDevicesFingerprint(
    client.userID,
    verifiedDevices(client, client.userID),
  );

  /// One event, e.g. a reminder wake hint or a bridge media state.
  static Future<bool> verify(Event event, {String? userId}) async {
    final client = event.room.client;
    await client.userDeviceKeysLoading;
    final snapshot = MegolmTrustSnapshot.devices(client, userId: userId);
    await snapshot.capture(event.room, [event]);
    return snapshot.trusts(event);
  }

  /// Undecrypted events among the captured ones which decrypt now that their
  /// session is present, by event id. Callers replay these instead.
  Map<String, Event> get redecrypted => Map.unmodifiable(_redecrypted);

  /// Loads the inbound sessions of [events] in [room], retries decryption of
  /// undecrypted ones whose session is present, and re-proves decrypted ones
  /// ([needsProof], default all) whose session index does not record them by
  /// decrypting their original again. Call once, before any verdict.
  Future<void> capture(
    Room room,
    Iterable<Event> events, {
    bool Function(Event event)? needsProof,
  }) async {
    if (_captured) throw StateError('Trust snapshot already captured');
    _captured = true;
    _roomId = room.id;
    final unique = <String, Event>{};
    for (final event in events) {
      if (event.senderId == userId) {
        unique.putIfAbsent(event.eventId, () => event);
      }
    }
    final sessionIds = <String>{};
    for (final event in unique.values) {
      final envelope = MegolmEnvelope.parse(_envelopeOf(event));
      if (envelope != null) sessionIds.add(envelope.sessionId);
    }
    final encryption = sessionIds.isEmpty ? null : _client.encryption;
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
    if (encryption != null) {
      for (final event in unique.values) {
        if (event.type != EventTypes.Encrypted) continue;
        final envelope = MegolmEnvelope.parse(_envelopeOf(event));
        if (envelope == null || _sessions[envelope.sessionId] == null) {
          continue;
        }
        final Event decrypted;
        try {
          decrypted = await encryption.decryptRoomEvent(_encrypted(event));
        } catch (_) {
          continue;
        }
        if (decrypted.type == EventTypes.Encrypted) {
          _undecryptableWithSession.add(event.eventId);
        } else {
          _redecrypted[event.eventId] = decrypted;
        }
      }
      for (final event in [
        for (final event in unique.values) _redecrypted[event.eventId] ?? event,
      ]) {
        if (event.type == EventTypes.Encrypted ||
            !(needsProof?.call(event) ?? true) ||
            _evaluate(event) != MegolmTrust.unproven) {
          continue;
        }
        // The index misses this event (decrypted by another process, an
        // unpersisted index, or a session replaced since): decrypt the
        // original again with the session the rule looks at.
        final Event again;
        try {
          again = await encryption.decryptRoomEvent(_encrypted(event));
        } catch (_) {
          continue;
        }
        if (again.type != event.type ||
            !jsonValueEquals(again.content, event.content)) {
          _failedProof.add(event.eventId);
        }
      }
    }
    for (final event in unique.values) {
      final current = _redecrypted[event.eventId] ?? event;
      if (current.type == EventTypes.Encrypted) continue;
      final verdict = this.verdict(current);
      if (verdict != MegolmTrust.trusted &&
          verdict != MegolmTrust.unverifiedDevice) {
        continue;
      }
      final key = MegolmEnvelope.parse(_envelopeOf(current))!.senderKey;
      final ts = current.originServerTs.millisecondsSinceEpoch;
      final newest = _newestDirect[key];
      if (newest == null || ts > newest) _newestDirect[key] = ts;
    }
  }

  /// The trust verdict, computed once per event and decryption state.
  MegolmTrust verdict(Event event) => _verdicts.putIfAbsent(
    '${event.type == EventTypes.Encrypted ? 'e' : 'd'}${event.eventId}',
    () {
      final verdict = _evaluate(event);
      // A failed re-decryption outranks an index entry it may have written.
      final failed = _failedProof.contains(event.eventId);
      return failed &&
              (verdict == MegolmTrust.trusted ||
                  verdict == MegolmTrust.unverifiedDevice ||
                  verdict == MegolmTrust.unproven)
          ? MegolmTrust.notDecryptedBySession
          : verdict;
    },
  );

  @override
  bool trusts(Event event) => verdict(event) == MegolmTrust.trusted;

  @override
  bool mayLaterTrust(Event event) => event.type == EventTypes.Encrypted
      ? !undecryptableForGood(event)
      : verdict(event).mayChange;

  /// See [megolmUndecryptableForGood].
  bool undecryptableForGood(Event event) {
    final envelope = _envelopeOf(event);
    final parsed = MegolmEnvelope.parse(envelope);
    return megolmUndecryptableForGood(
      senderId: event.senderId,
      expectedSenderId: userId,
      envelopeContent: envelope,
      originServerTsMs: event.originServerTs.millisecondsSinceEpoch,
      sessionPresent: _undecryptableWithSession.contains(event.eventId),
      newestDirectFromSender: parsed == null
          ? null
          : _newestDirect[parsed.senderKey],
    );
  }

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

  /// The megolm session id in [event]'s envelope, if well-formed.
  static String? sessionIdOf(Event event) =>
      MegolmEnvelope.parse(_envelopeOf(event))?.sessionId;

  /// The curve25519 key of the device that encrypted [event], if its
  /// envelope is well-formed. For a [trusts]ed event this is a verified own
  /// device (the trust rule matched it).
  static String? senderKeyOf(Event event) =>
      MegolmEnvelope.parse(_envelopeOf(event))?.senderKey;

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

  /// The megolm envelope: the original of a decrypted event, or the content
  /// of an undecrypted one.
  static Map<String, Object?>? _envelopeOf(Event event) {
    final original = event.originalSource;
    if (original != null && original.type == EventTypes.Encrypted) {
      return original.content;
    }
    return event.type == EventTypes.Encrypted ? event.content : null;
  }

  static Event _encrypted(Event event) {
    final original = event.originalSource;
    return original != null && original.type == EventTypes.Encrypted
        ? Event.fromMatrixEvent(original, event.room)
        : event;
  }
}
