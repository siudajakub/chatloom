// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:collection';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'matrix_transport.dart';
import 'ports.dart';

/// Push feed of incoming speech media from the worker's own Matrix sync.
///
/// Cloud bridge rooms are invisible to the local index scan; without this
/// feed only an open app could ask for their transcripts. The SDK already
/// receives (and decrypts) every timeline event, so a new voice note, round
/// or video becomes a candidate the moment the sync delivers it: no polling
/// and no history requests. Only identifiers, kind, duration, network and
/// timestamp leave this class; eligibility, limits and budget are decided by
/// the engine exactly as for the local scan.
///
/// Events the SDK could not decrypt yet are re-read from the SDK database
/// for a bounded time and decrypted with the keys it holds by then: the SDK
/// stores the decrypted copy itself only for to-device keys that arrive
/// within 5 minutes, not for keys from the backup or a later forward.
class MatrixLiveSources implements LiveSourceFeed {
  static const maxQueued = 200;
  static const maxPendingKeys = 100;
  static const pendingKeysFor = Duration(minutes: 10);
  static const pendingKeysRetry = Duration(seconds: 10);

  final Client client;
  final String journalRoomId;

  /// Rooms to ignore. By default none: a local-bridge event that the sync
  /// happens to deliver gets the same entity id as the adapter scan's item,
  /// so whichever source sees it first creates the single job.
  final bool Function(String roomId) excludedRoom;
  final DateTime Function() clock;

  /// Decrypts a stored, still encrypted event with the keys held now
  /// ([decryptStoredEvent]); a test seam.
  final Future<Event> Function(Event event) decrypt;
  final _queue = Queue<({Event event, AutoTranscriptionKind kind})>();
  final _seen = <String>{};
  final _seenOrder = Queue<String>();
  final _pending = <String, ({String roomId, DateTime since})>{};
  DateTime? _pendingCheckedAt;
  StreamSubscription<Event>? _subscription;
  Completer<void>? _wake;
  bool _active = true;

  MatrixLiveSources(
    this.client, {
    required this.journalRoomId,
    bool Function(String roomId)? excludedRoom,
    DateTime Function()? clock,
    Future<Event> Function(Event event)? decrypt,
  }) : excludedRoom = excludedRoom ?? ((_) => false),
       clock = clock ?? DateTime.now,
       decrypt = decrypt ?? ((event) => decryptStoredEvent(client, event));

  /// Subscribe before the SDK's first sync, so messages that arrived while
  /// the worker was stopped (the catch-up sync) are seen as well.
  void start() {
    _subscription ??= client.onTimelineEvent.stream.listen(observe);
  }

  Future<void> close() async {
    await _subscription?.cancel();
    _subscription = null;
    _signal();
  }

  @override
  set active(bool value) {
    _active = value;
    if (!value) {
      _queue.clear();
      _pending.clear();
    }
  }

  @override
  Future<void> get wakeup => (_wake ??= Completer<void>()).future;

  void _signal() {
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  /// Classifies one timeline event; public for tests.
  void observe(Event event) {
    if (!_active) return;
    final room = event.room;
    if (room.id == journalRoomId ||
        excludedRoom(room.id) ||
        room.membership != Membership.join ||
        !event.eventId.startsWith(r'$') ||
        event.senderId == client.userID) {
      return;
    }
    if (event.type == EventTypes.Encrypted) {
      if (_pending.length < maxPendingKeys && !_seen.contains(event.eventId)) {
        _pending[event.eventId] = (roomId: room.id, since: clock());
      }
      return;
    }
    if (_accept(event)) _signal();
  }

  /// Queues a speech media message; its room's state is consulted when
  /// the feed is drained ([drain] loads it for rooms never opened).
  bool _accept(Event event) {
    if (event.redacted ||
        event.type != EventTypes.Message ||
        event.relationshipType == RelationshipTypes.edit ||
        _seen.contains(event.eventId)) {
      return false;
    }
    final kind = transcribableMediaKind(event.content);
    if (kind == null) return false;
    _remember(event.eventId);
    if (_queue.length >= maxQueued) _queue.removeFirst();
    _queue.add((event: event, kind: kind));
    return true;
  }

  /// The item for a queued message, or null when its room rules it out.
  Future<RecentSourceItem?> _item(
    Event event,
    AutoTranscriptionKind kind,
  ) async {
    final room = event.room;
    // Bridge declarations and the disappearing setting of a room the worker
    // never opened are only in the SDK database until loaded.
    await ensureRoomState(client, room);
    // The chat's disappearing setting; the transport re-checks before any
    // download, this only avoids creating jobs that would be refused.
    if (disappearingTimerLimits(
      room.getState(beeperDisappearingTimerKey)?.content,
    )) {
      return null;
    }
    final duration = event.infoMap['duration'];
    return RecentSourceItem(
      roomId: room.id,
      eventId: event.eventId,
      kind: kind,
      network: networkOf(room),
      durationMs: duration is int && duration >= 0 ? duration : null,
      timestamp: event.originServerTs.toUtc(),
      // Sent from the native app, the owner's message arrives as the
      // owner's bridge ghost: the own-message rules of the policy apply.
      outgoing: cachedOwnRemoteIdentity(
        client,
      ).isOwn(event.senderId, roomId: room.id),
    );
  }

  void _remember(String eventId) {
    if (_seen.add(eventId)) {
      _seenOrder.add(eventId);
      if (_seenOrder.length > 2000) _seen.remove(_seenOrder.removeFirst());
    }
  }

  @override
  Future<List<RecentSourceItem>> drain() async {
    await _retryPending();
    final queued = _queue.toList();
    _queue.clear();
    final items = <RecentSourceItem>[];
    for (final entry in queued) {
      final item = await _item(entry.event, entry.kind);
      if (item != null) items.add(item);
    }
    return items;
  }

  Future<void> _retryPending() async {
    if (_pending.isEmpty) return;
    final now = clock();
    final checked = _pendingCheckedAt;
    if (checked != null && now.difference(checked) < pendingKeysRetry) return;
    _pendingCheckedAt = now;
    for (final entry in _pending.entries.toList()) {
      if (now.difference(entry.value.since) > pendingKeysFor) {
        _pending.remove(entry.key);
        continue;
      }
      final room = client.getRoomById(entry.value.roomId);
      if (room == null) {
        _pending.remove(entry.key);
        continue;
      }
      try {
        var stored = await room.getEventById(entry.key);
        if (stored != null && stored.type == EventTypes.Encrypted) {
          stored = await decrypt(stored);
        }
        if (stored == null || stored.type == EventTypes.Encrypted) continue;
        _pending.remove(entry.key);
        _accept(stored);
      } catch (_) {
        _pending.remove(entry.key);
      }
    }
  }

  /// Same rule as the app's `PersonalClient.networkOf`, so synced
  /// per-network switches match.
  static String networkOf(Room room) {
    for (final type in [
      'm.bridge',
      'uk.half-shot.bridge',
      'com.beeper.bridge',
    ]) {
      final states = room.states[type];
      if (states == null) continue;
      for (final state in states.values) {
        final protocol = state.content['protocol'];
        if (protocol is Map && protocol['id'] is String) {
          final id = protocol['id'] as String;
          if (RegExp(r'^[A-Za-z0-9_.-]{1,64}$').hasMatch(id)) return id;
        }
      }
    }
    return 'unknown';
  }
}
