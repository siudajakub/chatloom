// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'engine.dart';
import 'journal_trust.dart';
import 'ports.dart';
import 'store.dart';
import 'reminder_relay.dart';

class WorkerJournal {
  final Client client;
  final String roomId;
  final Set<String> trustedDevices;
  final WorkerStore store;
  final WorkerEngine engine;
  Timeline? _timeline;
  bool _busy = false;
  bool authenticatedDecryptionSeen = false;
  WorkerJournal(
    this.client,
    this.roomId,
    this.trustedDevices,
    this.store,
    this.engine,
  );

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
    // Sync updates are reconciled by the daemon loop, avoiding an unhandled
    // asynchronous validation error in SDK callbacks.
    _timeline = await room.getTimeline();
    await reconcile();
    if (!authenticatedDecryptionSeen) {
      throw const WorkerFailure('journal_decryption_unproven');
    }
  }

  Future<void> reconcile() async {
    if (_busy || _timeline == null) return;
    _busy = true;
    try {
      await validate();
      final timeline = _timeline!;
      final checkpoint = store.checkpoint('journal');
      while (timeline.canRequestHistory &&
          (checkpoint == null ||
              !timeline.events.any((e) => e.eventId == checkpoint))) {
        final before = timeline.events.length;
        await timeline.requestHistory(historyCount: 100);
        if (timeline.events.length == before) break;
      }
      // Replay is cheap and op IDs provide durable de-duplication. A missing key
      // must not advance checkpoint past a command that could later decrypt.
      var undeciphered = false;
      final events = timeline.events.reversed.toList();
      // Commands count only when the megolm session that decrypted them was
      // delivered directly by a pinned verified device (see journal_trust).
      await client.userDeviceKeysLoading;
      final trust = WorkerJournalTrust.of(client, trustedDevices);
      await trust.capture(timeline.room, [
        for (final event in events)
          if (event.type == personalEventType && !event.redacted) event,
      ]);
      for (final event in events) {
        if (event.type == EventTypes.Encrypted) {
          undeciphered = true;
          continue;
        }
        if (event.type != personalEventType ||
            event.redacted ||
            event.senderId != client.userID) {
          continue;
        }
        if (!trust.trusts(event)) continue;
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
      if (undeciphered) {
        timeline.requestKeys(onlineKeyBackupOnly: false);
      } else if (timeline.events.isNotEmpty) {
        store.setCheckpoint('journal', timeline.events.first.eventId);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> flush() async {
    final room = await validate();
    for (final snapshot in store.outbox) {
      final id = snapshot['opId'] as String;
      final body = store.outboxEntry(id);
      if (body == null) continue;
      store.recordTranscriptPublicationIntent(body);
      final result = await room.sendEvent(
        body,
        type: personalEventType,
        txid: stableId('journal', id),
        displayPendingEvent: false,
      );
      if (result == null) return;
      acknowledgePublishedReminderResult(store, body, eventId: result);
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

  void dispose() => _timeline?.cancelSubscriptions();
}
