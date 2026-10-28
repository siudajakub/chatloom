// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'engine.dart';
import 'journal_trust.dart';
import 'ports.dart';
import 'store.dart';
import 'reminder_relay.dart';

/// The worker's view of the private journal room.
///
/// At start (and after a gap in the sync) a temporary [Timeline] pages back
/// to the stored checkpoint and replays what is newer; afterwards only the
/// events the sync delivers are processed, each once. Before, one Timeline
/// kept every journal event since start, and all of them were replayed,
/// trust-checked and decoded again on every 2-second loop.
///
/// Events that cannot be decrypted yet are held (at most [maxHeld], also
/// across restarts) and decrypted again when their room key arrives, instead
/// of pinning the checkpoint: one event that never decrypts no longer makes
/// every restart page back to it.
class WorkerJournal {
  /// Held undecrypted events; beyond this the checkpoint stops advancing, so
  /// none of them is lost.
  static const maxHeld = 128;

  /// Own commands refused only because their device is not trusted now;
  /// checked again when the set of trusted devices changes (this process).
  static const maxUntrusted = 128;

  /// Held events are decrypted again at least this often even without a key
  /// notification; their keys are requested at most this often.
  static const heldRetry = Duration(minutes: 1);
  static const keyRequestInterval = Duration(minutes: 30);

  static const checkpointKey = 'journal';
  static const heldKey = 'journal-held';

  /// An entry that fails while entries after it go through is parked after
  /// this many such passes; parked transient failures are queued again
  /// every [parkedRetry].
  static const maxEntryFailures = 8;
  static const parkedRetry = Duration(hours: 1);

  final Client client;
  final String roomId;
  final Set<String> trustedDevices;
  final WorkerStore store;
  final WorkerEngine engine;
  final DateTime Function() clock;
  bool _busy = false;
  bool authenticatedDecryptionSeen = false;

  final _incoming = <Event>[];
  final _processed = <String>{};
  final _held = <String, Event>{};
  final _untrusted = <String, Event>{};
  final _keyRequests = <String, DateTime>{};
  final _entryFailures = <String, int>{};
  final _keysArrived = <String>{};
  String? _trustFingerprint;
  DateTime? _heldCheckedAt;
  DateTime? _flushNotBefore;
  DateTime? _unparkedAt;
  bool _catchUp = true;

  /// The first catch-up replays every loaded event, as every pass did
  /// before (idempotent by op id): it also proves decryption at start when
  /// nothing arrived since the checkpoint.
  bool _replayedLoaded = false;
  StreamSubscription<Event>? _live;
  StreamSubscription<SyncUpdate>? _gaps;
  StreamSubscription<String>? _sessionKeys;

  WorkerJournal(
    this.client,
    this.roomId,
    this.trustedDevices,
    this.store,
    this.engine, {
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;

  Future<Room> validate() async {
    final room = client.getRoomById(roomId);
    if (room == null ||
        !room.encrypted ||
        !client.encryptionEnabled ||
        room.membership != Membership.join) {
      throw const WorkerFailure('journal_unavailable');
    }
    final members = await room.requestParticipants([
      Membership.join,
      Membership.invite,
    ]);
    if (members.isEmpty || members.any((u) => u.id != client.userID)) {
      throw const WorkerFailure('journal_membership_changed');
    }
    if (room.getState(personalRoomMarker)?.content['schema'] !=
        personalSchemaVersion) {
      throw const WorkerFailure('journal_marker_missing');
    }
    return room;
  }

  Future<void> start() async {
    final room = await validate();
    // Subscribed before the catch-up, so nothing falls between the two;
    // duplicates are skipped by id. Sync updates are reconciled by the
    // daemon loop, avoiding an unhandled asynchronous validation error in
    // SDK callbacks.
    _live ??= client.onTimelineEvent.stream.listen((event) {
      if (event.room.id == roomId) _incoming.add(event);
    });
    _gaps ??= client.onSync.stream
        .where((sync) => sync.rooms?.join?[roomId]?.timeline?.limited == true)
        .listen((_) => _catchUp = true);
    _sessionKeys ??= room.onSessionKeyReceived.stream.listen(_keysArrived.add);
    await _loadHeld(room);
    await reconcile();
    if (!authenticatedDecryptionSeen) {
      throw const WorkerFailure('journal_decryption_unproven');
    }
  }

  /// Held ids of the previous run, read again by id.
  Future<void> _loadHeld(Room room) async {
    final stored = store.checkpoint(heldKey);
    if (stored == null || stored.isEmpty) return;
    final Object? ids;
    try {
      ids = jsonDecode(stored);
    } on FormatException {
      return;
    }
    if (ids is! List) return;
    for (final id in ids.whereType<String>().take(maxHeld)) {
      try {
        final event = await room.getEventById(id);
        if (event != null && !event.redacted) _held[id] = event;
      } catch (_) {
        // Offline: kept in the stored list until it can be read.
        _held[id] = Event(
          type: EventTypes.Encrypted,
          content: const {},
          eventId: id,
          senderId: client.userID ?? '',
          originServerTs: DateTime.fromMillisecondsSinceEpoch(0),
          room: room,
        );
      }
    }
  }

  Future<void> reconcile() async {
    if (_busy) return;
    _busy = true;
    try {
      final room = await validate();
      final batch = <Event>[];
      if (_catchUp) {
        _catchUp = false;
        try {
          batch.addAll(await _catchUpEvents(room));
        } catch (_) {
          _catchUp = true;
          rethrow;
        }
      }
      batch.addAll(_incoming);
      _incoming.clear();
      final retry = await _retryHeld(room);
      if (batch.isEmpty && retry.isEmpty) return;
      await _process(room, retry, batch);
    } finally {
      _busy = false;
    }
  }

  /// Events newer than the checkpoint, oldest first, from a temporary
  /// timeline that is dropped afterwards.
  Future<List<Event>> _catchUpEvents(Room room) async {
    final timeline = await room.getTimeline();
    try {
      final checkpoint = store.checkpoint(checkpointKey);
      while (timeline.canRequestHistory &&
          (checkpoint == null ||
              !timeline.events.any((e) => e.eventId == checkpoint))) {
        final before = timeline.events.length;
        await timeline.requestHistory(historyCount: 100);
        if (timeline.events.length == before) break;
      }
      final events = timeline.events.reversed.toList();
      final at = checkpoint == null || !_replayedLoaded
          ? -1
          : events.indexWhere((e) => e.eventId == checkpoint);
      _replayedLoaded = true;
      // Replay is idempotent (op ids are durable): without the checkpoint
      // everything loaded is replayed, as before.
      return at < 0 ? events : events.sublist(at + 1);
    } finally {
      timeline.cancelSubscriptions();
    }
  }

  /// Held events whose key arrived (or whose periodic retry is due),
  /// decrypted now; refused commands again when the trusted devices changed.
  Future<List<Event>> _retryHeld(Room room) async {
    final retry = <Event>[];
    final now = clock();
    final due =
        _heldCheckedAt == null || now.difference(_heldCheckedAt!) >= heldRetry;
    if (_held.isNotEmpty && (due || _keysArrived.isNotEmpty)) {
      if (due) _heldCheckedAt = now;
      for (final entry in _held.entries.toList()) {
        var event = entry.value;
        if (event.content.isEmpty) {
          // Could not be read at start: read it now.
          try {
            final stored = await room.getEventById(entry.key);
            if (stored == null || stored.redacted) {
              _held.remove(entry.key);
              continue;
            }
            event = _held[entry.key] = stored;
          } catch (_) {
            continue;
          }
        }
        final session = event.content['session_id'];
        if (!due && !_keysArrived.contains(session)) continue;
        if (event.type == EventTypes.Encrypted) {
          try {
            event = await client.encryption?.decryptRoomEvent(event) ?? event;
          } catch (_) {
            continue;
          }
        }
        if (event.type == EventTypes.Encrypted) {
          _requestKey(event);
          continue;
        }
        _held.remove(entry.key);
        _processed.remove(entry.key);
        retry.add(event);
      }
    }
    _keysArrived.clear();
    final fingerprint = WorkerJournalTrust.of(
      client,
      trustedDevices,
    ).fingerprint;
    if (_trustFingerprint != null &&
        fingerprint != _trustFingerprint &&
        _untrusted.isNotEmpty) {
      for (final id in _untrusted.keys) {
        _processed.remove(id);
      }
      retry.addAll(_untrusted.values);
      _untrusted.clear();
    }
    _trustFingerprint = fingerprint;
    return retry;
  }

  void _requestKey(Event event) {
    final session = event.content['session_id'];
    if (session is! String) return;
    final last = _keyRequests[session];
    final now = clock();
    if (last != null && now.difference(last) < keyRequestInterval) return;
    _keyRequests[session] = now;
    if (_keyRequests.length > 4 * maxHeld) {
      _keyRequests.remove(_keyRequests.keys.first);
    }
    unawaited(Future<void>(() => event.requestKey()).catchError((Object _) {}));
  }

  /// Applies [retry] (held events now readable) and [batch] (new events in
  /// journal order) once each, then moves the checkpoint over [batch].
  Future<void> _process(Room room, List<Event> retry, List<Event> batch) async {
    // Commands count only when the megolm session that decrypted them was
    // delivered directly by a pinned verified device (see journal_trust).
    await client.userDeviceKeysLoading;
    final trust = WorkerJournalTrust.of(client, trustedDevices);
    _trustFingerprint = trust.fingerprint;
    final unique = <String>{};
    final fresh = [
      for (final event in [...retry, ...batch])
        if (!_processed.contains(event.eventId) && unique.add(event.eventId))
          event,
    ];
    await trust.capture(room, [
      for (final event in fresh)
        if (event.type == personalEventType && !event.redacted) event,
    ]);
    final retried = {for (final event in retry) event.eventId};
    String? newest;
    for (final event in fresh) {
      _processed.add(event.eventId);
      if (_processed.length > 4096) _processed.remove(_processed.first);
      if (!retried.contains(event.eventId)) newest = event.eventId;
      if (event.type == EventTypes.Encrypted) {
        // A missing key must not lose a command that could decrypt later.
        if (event.senderId == client.userID) {
          _held.putIfAbsent(event.eventId, () => event);
        }
        _requestKey(event);
        continue;
      }
      if (event.type != personalEventType ||
          event.redacted ||
          event.senderId != client.userID) {
        continue;
      }
      if (!trust.trusts(event)) {
        if (_commandKind(event) && _untrusted.length < maxUntrusted) {
          _untrusted[event.eventId] = event;
        }
        continue;
      }
      authenticatedDecryptionSeen = true;
      PersonalOperation? op;
      try {
        op = PersonalOperation.fromJson(event.content);
        engine.accept(op);
      } on WorkerFailure catch (e) {
        if (op != null) {
          engine.rejectInvalid(op, e.code);
        }
      } catch (_) {
        if (op != null) {
          engine.rejectInvalid(op, 'invalid_command');
        }
      }
    }
    _saveCheckpoint(newest);
  }

  static bool _commandKind(Event event) {
    final kind = event.content['kind'];
    return kind is String &&
        !kind.endsWith('.result') &&
        kind != 'worker.heartbeat';
  }

  /// The checkpoint covers every processed event; undecrypted ones are
  /// listed beside it. With more than [maxHeld] of them it stays where it
  /// is (as before), so a restart still replays them.
  void _saveCheckpoint(String? newest) {
    if (_held.length > maxHeld) return;
    if (newest != null && newest.startsWith(r'$')) {
      store.setCheckpoint(checkpointKey, newest);
    }
    final value = jsonEncode(_held.keys.toList());
    if (store.checkpoint(heldKey) != value) {
      store.setCheckpoint(heldKey, value);
    }
  }

  /// Held undecrypted journal events (diagnostics and tests).
  int get heldEvents => _held.length;

  /// Own devices whose commands were refused as untrusted since the trust
  /// last changed (not pinned, not verified or blocked), found by the
  /// envelope's sender key. Diagnostics only: a device that finds its id in
  /// the heartbeat tells the user that the worker ignores its changes.
  List<String> get untrustedDeviceIds {
    final keys = <String>{
      for (final event in _untrusted.values)
        if (event.originalSource?.content['sender_key'] case final String key)
          key,
    };
    if (keys.isEmpty) return const [];
    return [
      for (final device
          in client.userDeviceKeys[client.userID]?.deviceKeys.values ??
              const <DeviceKeys>[])
        if (keys.contains(device.curve25519Key)) ?device.deviceId,
    ]..sort();
  }

  /// Publishes the queued results in order. An entry the homeserver or the
  /// SDK refuses for good (too large, malformed) is parked and the others
  /// continue; before, it blocked every later result, heartbeat and
  /// reminder forever. A transient failure ends the pass only when the next
  /// entry fails as well (the connection, not the entry); an entry that
  /// keeps failing while later ones go through is parked after
  /// [maxEntryFailures] passes and queued again every [parkedRetry].
  Future<void> flush() async {
    final now = clock();
    final notBefore = _flushNotBefore;
    if (notBefore != null && now.isBefore(notBefore)) return;
    final room = await validate();
    final unparked = _unparkedAt;
    if (unparked == null || now.difference(unparked) >= parkedRetry) {
      _unparkedAt = now;
      store.unparkOutbox('publish_failed');
    }
    final failedThisPass = <String>[];
    for (final id in store.outboxIds) {
      final body = store.outboxEntry(id);
      if (body == null) continue;
      store.recordTranscriptPublicationIntent(body);
      String? eventId;
      Object? failure;
      try {
        eventId = await room.sendEvent(
          body,
          type: personalEventType,
          txid: stableId('journal', id),
          displayPendingEvent: false,
          // Every failure reaches this loop; the next cycle retries with
          // the same transaction id (durable outbox).
          retryOnTransportFailure: false,
        );
      } catch (e) {
        failure = e;
      }
      if (eventId != null) {
        acknowledgePublishedReminderResult(store, body, eventId: eventId);
        _entryFailures.remove(id);
        // Earlier failures of this pass were the entries', not the link's.
        for (final failed in failedThisPass) {
          final count = _entryFailures[failed] =
              (_entryFailures[failed] ?? 0) + 1;
          if (count >= maxEntryFailures) _park(failed, 'publish_failed');
        }
        failedThisPass.clear();
        continue;
      }
      final permanent = permanentPublishFailure(failure);
      if (permanent != null) {
        _park(id, permanent);
        continue;
      }
      if (failure is MatrixException && failure.retryAfterMs != null) {
        _flushNotBefore = clock().add(
          Duration(milliseconds: failure.retryAfterMs!.clamp(0, 300000)),
        );
        return;
      }
      failedThisPass.add(id);
      if (failedThisPass.length >= 2) return;
    }
    // Durable retry uses the same transaction ID on this enrolled device.
    for (final pending in store.pendingTranscriptRedactions) {
      final id = pending['op_id'] as String;
      final accepted = await client.redactEvent(
        room.id,
        pending['event_id'] as String,
        stableId('source-redaction', id),
        reason: 'source_redacted',
      );
      if (accepted?.isNotEmpty == true) {
        store.acknowledgeTranscriptRedaction(id);
      }
    }
  }

  void _park(String id, String code) {
    store.parkOutbox(id, code, clock());
    _entryFailures.remove(id);
    // Content-free: the reason code only.
    stderr.writeln('Journal result parked: $code');
  }

  /// A reason code when [failure] can never succeed for that entry.
  static String? permanentPublishFailure(Object? failure) {
    if (failure is EventTooLarge) return 'result_too_large';
    if (failure is MatrixException) {
      if (failure.errcode == 'M_TOO_LARGE' ||
          failure.response?.statusCode == 413) {
        return 'result_too_large';
      }
      if (const {
        'M_BAD_JSON',
        'M_NOT_JSON',
        'M_INVALID_PARAM',
      }.contains(failure.errcode)) {
        return 'result_refused';
      }
    }
    return null;
  }

  void dispose() {
    unawaited(_live?.cancel());
    unawaited(_gaps?.cancel());
    unawaited(_sessionKeys?.cancel());
    _live = null;
    _gaps = null;
    _sessionKeys = null;
  }
}
