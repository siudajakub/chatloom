// SPDX-License-Identifier: AGPL-3.0-or-later
/// Delivery ticks of own messages (Telegram/Signal): the clock while
/// sending, ✓ when the server has the message, ✓✓ once the bridged network
/// accepted it, ✓✓ in the accent once somebody on the other side read it.
///
/// Sources, all already on the device (nothing is requested or sent):
/// * sent: the event's own status (the server echo);
/// * delivered: the bridge's `com.beeper.message_send_status` SUCCESS for
///   the event, the bridge bot's delivery receipt on it
///   (`matrix.delivery_receipts`), or a message that came from the network
///   itself (double puppeted, or an own ghost);
/// * read: a read receipt of another member (a bridged ghost or a Matrix
///   user) at or after the event. The account's own receipts, the user's own
///   ghosts and the bridge bots never count as readers.
///
/// Only received receipts are displayed: receipt and typing sending and the
/// incognito policy are untouched by this file.
///
/// Cost: a bubble derives "sent/delivered" from its timeline aggregates while
/// it builds; "read" comes from one [RoomReadReceipts] per room, which
/// listens to receipt syncs of that room only while some tick shows, and
/// notifies only when another member's receipt actually moved. Rows never
/// subscribe to streams, and the timeline is not rebuilt for a receipt.
library;

import 'dart:async';

import 'package:chatloom/personal/message_delivery.dart';
import 'package:chatloom/personal/own_sender.dart';
import 'package:chatloom/ui/notion/notion_delivery_tick.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

/// Marks an event the bridge sent as the user's own account (double
/// puppeting): it was written in the network's own app, so it is on the
/// network already.
const doublePuppetSourceKey = 'fi.mau.double_puppet_source';

/// How far an own message got.
enum DeliveryProgress {
  /// Not an own message: no ticks.
  none,
  sending,
  sent,
  delivered,
  read,

  /// Not sent, or rejected by the network: the existing "Not sent" /
  /// "Not delivered" states show instead of ticks.
  failed;

  /// The glyph for this progress, or null when no tick shows.
  NotionDeliveryState? get tick => switch (this) {
    DeliveryProgress.sending => NotionDeliveryState.sending,
    DeliveryProgress.sent => NotionDeliveryState.sent,
    DeliveryProgress.delivered => NotionDeliveryState.delivered,
    DeliveryProgress.read => NotionDeliveryState.read,
    DeliveryProgress.none || DeliveryProgress.failed => null,
  };
}

/// The rule, pure: failure beats everything, then sending, then read, then
/// any proof of delivery, else sent.
DeliveryProgress resolveDeliveryProgress({
  required bool own,
  required EventStatus status,
  bool failed = false,
  BridgeSendStatus? bridge,
  bool fromNetwork = false,
  bool deliveryReceipt = false,
  bool read = false,
}) {
  if (!own) return DeliveryProgress.none;
  if (failed || status.isError || (bridge?.failed ?? false)) {
    return DeliveryProgress.failed;
  }
  if (status.isSending) return DeliveryProgress.sending;
  if (read) return DeliveryProgress.read;
  if (fromNetwork || deliveryReceipt || bridge?.status == 'SUCCESS') {
    return DeliveryProgress.delivered;
  }
  return DeliveryProgress.sent;
}

/// Whether [event] (own) was written in the network's own app.
bool cameFromNetwork(Event event) =>
    event.content[doublePuppetSourceKey] != null;

/// Sent or delivered for an own, server-confirmed [event] of a conversation
/// row, from its timeline aggregates (the bridge's status reports). "Read"
/// is added by the tick widget from [RoomReadReceipts], so a receipt never
/// rebuilds the row.
DeliveryProgress messageDeliveryProgress(Event event, Timeline timeline) {
  final own = event.senderId == event.room.client.userID;
  if (!own) return DeliveryProgress.none;
  return resolveDeliveryProgress(
    own: true,
    status: event.status,
    bridge: event.status.isSent
        ? BridgeSendStatus.latest(bridgeStatusesOf(event, timeline))
        : null,
    fromNetwork: cameFromNetwork(event),
  );
}

/// The events other members' receipts point at, split into readers (people)
/// and bridge bots (delivery receipts).
@immutable
class ReceiptTargets {
  const ReceiptTargets({
    this.read = const {},
    this.acknowledged = const {},
    this.newestRead,
  });

  /// Events read by another member.
  final Set<String> read;

  /// Events a bridge bot marked: delivered to the network.
  final Set<String> acknowledged;

  /// Time of the newest reader receipt (for history windows that do not
  /// contain its event).
  final DateTime? newestRead;

  static const empty = ReceiptTargets();

  /// Collected from [room]'s stored receipt state (main timeline and
  /// unthreaded receipts). Never the account, its own ghosts or the
  /// bridge bots as readers.
  factory ReceiptTargets.of(Room room) {
    final client = room.client;
    final own = client.userID;
    final state = room.receiptState;
    final others = [state.global.otherUsers, ?state.mainThread?.otherUsers];
    if (others.every((users) => users.isEmpty)) return empty;
    final bots = bridgeBotsOf(room);
    final resolver = OwnSenderResolver.of(client);
    final read = <String>{};
    final acknowledged = <String>{};
    DateTime? newest;
    for (final users in others) {
      for (final MapEntry(key: user, value: receipt) in users.entries) {
        if (user == own) continue;
        if (bots.contains(user)) {
          acknowledged.add(receipt.eventId);
          continue;
        }
        if (resolver.isOwnSender(user, roomId: room.id)) continue;
        read.add(receipt.eventId);
        final at = receipt.timestamp;
        if (newest == null || at.isAfter(newest)) newest = at;
      }
    }
    return ReceiptTargets(
      read: read,
      acknowledged: acknowledged,
      newestRead: newest,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ReceiptTargets &&
      other.newestRead == newestRead &&
      setEquals(other.read, read) &&
      setEquals(other.acknowledged, acknowledged);

  @override
  int get hashCode => Object.hash(
    newestRead,
    Object.hashAllUnordered(read),
    Object.hashAllUnordered(acknowledged),
  );
}

/// Read and acknowledged positions of one loaded timeline.
class ReceiptSnapshot {
  ReceiptSnapshot._(this._ownIndex, this._readFrom, this._ackFrom);

  /// Builds the snapshot of [events] (newest first, as `Timeline.events`).
  /// [live] is false while the timeline shows an older window (a jump into
  /// history), where a receipt's event may lie after the window.
  factory ReceiptSnapshot.of(
    List<Event> events,
    ReceiptTargets targets, {
    required String? ownUserId,
    bool live = true,
  }) {
    var readFrom = -1, ackFrom = -1;
    final ownIndex = <String, int>{};
    for (var i = 0; i < events.length; i++) {
      final event = events[i];
      final id = event.eventId;
      if (readFrom < 0 && targets.read.contains(id)) readFrom = i;
      if (ackFrom < 0 && targets.acknowledged.contains(id)) ackFrom = i;
      if (event.senderId == ownUserId) ownIndex[id] = i;
    }
    final newestRead = targets.newestRead;
    if (readFrom < 0 &&
        !live &&
        newestRead != null &&
        events.isNotEmpty &&
        !newestRead.isBefore(events.first.originServerTs)) {
      // The reader's event is newer than everything loaded here.
      readFrom = 0;
    }
    return ReceiptSnapshot._(ownIndex, readFrom, ackFrom);
  }

  final Map<String, int> _ownIndex;
  final int _readFrom, _ackFrom;

  /// Another member's receipt is on [event] or a later event.
  bool isRead(Event event) {
    if (_readFrom < 0) return false;
    final index = _ownIndex[event.eventId];
    return index != null && index >= _readFrom;
  }

  /// A bridge bot's delivery receipt is on [event] or a later event.
  bool isAcknowledged(Event event) {
    if (_ackFrom < 0) return false;
    final index = _ownIndex[event.eventId];
    return index != null && index >= _ackFrom;
  }
}

/// One per room: the receipts of other members, as a listenable for the
/// ticks of that room's bubbles. While nobody listens it holds no
/// subscription; while ticks show it watches only this room's `m.receipt`
/// syncs and notifies when the targets of other members' receipts changed
/// (the account's own receipts never notify).
class RoomReadReceipts extends ChangeNotifier {
  RoomReadReceipts._(this.room);

  static final _rooms = Expando<RoomReadReceipts>('room read receipts');

  static RoomReadReceipts of(Room room) =>
      _rooms[room] ??= RoomReadReceipts._(room);

  final Room room;
  StreamSubscription<SyncUpdate>? _sync;
  ReceiptTargets? _targets;
  ({Timeline timeline, int length, String? first, String? last})? _key;
  ReceiptSnapshot? _snapshot;

  /// Notifications so far (performance tests).
  @visibleForTesting
  int debugNotifications = 0;

  /// Current targets; tracked live while listened to, read fresh otherwise.
  ReceiptTargets get targets => _sync != null
      ? _targets ??= ReceiptTargets.of(room)
      : ReceiptTargets.of(room);

  /// The snapshot of [timeline] (cached until its window or the receipts
  /// change, so every bubble of one build shares it).
  ReceiptSnapshot snapshotOf(Timeline timeline) {
    final events = timeline.events;
    final key = (
      timeline: timeline,
      length: events.length,
      first: events.firstOrNull?.eventId,
      last: events.lastOrNull?.eventId,
    );
    final cached = _snapshot;
    if (_sync != null && cached != null && _key == key) return cached;
    final snapshot = ReceiptSnapshot.of(
      events,
      targets,
      ownUserId: room.client.userID,
      live: timeline.allowNewEvent,
    );
    if (_sync != null) {
      _key = key;
      _snapshot = snapshot;
    }
    return snapshot;
  }

  @override
  void addListener(VoidCallback listener) {
    final first = !hasListeners;
    super.addListener(listener);
    if (first) _start();
  }

  @override
  void removeListener(VoidCallback listener) {
    super.removeListener(listener);
    if (!hasListeners) _stop();
  }

  void _start() {
    _targets = ReceiptTargets.of(room);
    _key = null;
    _snapshot = null;
    _sync = room.client.onSync.stream.listen(_onSync, onError: (_) {});
  }

  void _stop() {
    unawaited(_sync?.cancel());
    _sync = null;
    _targets = null;
    _key = null;
    _snapshot = null;
  }

  void _onSync(SyncUpdate update) {
    final ephemeral = update.rooms?.join?[room.id]?.ephemeral;
    if (ephemeral == null || !ephemeral.any((e) => e.type == 'm.receipt')) {
      return;
    }
    refresh();
  }

  /// Re-reads the receipt state and notifies when it moved (also called by
  /// tests after injecting receipts).
  void refresh() {
    final next = ReceiptTargets.of(room);
    if (next == _targets) return;
    _targets = next;
    _key = null;
    _snapshot = null;
    debugNotifications++;
    notifyListeners();
  }
}

/// Bridge status reports seen for recent own messages, for the inbox, which
/// has no timeline: live reports as they sync, and a one-time look into the
/// newest stored events of a room for a last message whose report arrived
/// before this run. Bounded; memory only.
class BridgeDeliveryLedger {
  BridgeDeliveryLedger._(this.client) {
    // Lives as long as the client, like [OwnSenderResolver].
    client.onTimelineEvent.stream.listen(_onEvent, onError: (_) {});
  }

  static final _clients = Expando<BridgeDeliveryLedger>('delivery ledger');

  static BridgeDeliveryLedger of(Client client) =>
      _clients[client] ??= BridgeDeliveryLedger._(client);

  final Client client;
  final _statuses = <String, BridgeSendStatus>{};
  final _checked = <String>{};
  final _changes = StreamController<String>.broadcast();
  Future<void> _queue = Future.value();

  /// Events remembered at most (statuses and look-ups each).
  static const capacity = 256;

  /// Stored events looked at per room for a missing report.
  static const lookBack = 12;

  /// Room ids whose last message's report became known.
  Stream<String> get changes => _changes.stream;

  /// Store look-ups started so far (performance tests).
  @visibleForTesting
  int debugLookups = 0;

  /// The newest trusted report about [eventId], if seen.
  BridgeSendStatus? statusOf(String eventId) => _statuses[eventId];

  void _onEvent(Event event) {
    if (event.type != beeperMessageSendStatusType) return;
    if (record(event)) _changes.add(event.room.id);
  }

  /// Records a status [report] from the room's bridge bot; true when the
  /// known status of its target changed.
  bool record(Event report) {
    if (report.type != beeperMessageSendStatusType) return false;
    final relation = report.content['m.relates_to'];
    final target = relation is Map ? relation['event_id'] : null;
    if (target is! String || target.isEmpty) return false;
    final status = BridgeSendStatus.parse(
      report.content,
      sender: report.senderId,
      bridgeBots: bridgeBotsOf(report.room),
      at: report.originServerTs,
    );
    if (status == null) return false;
    final known = _statuses[target];
    if (known != null && status.at.isBefore(known.at)) return false;
    final changed = known?.status != status.status;
    _statuses.remove(target);
    _statuses[target] = status;
    while (_statuses.length > capacity) {
      _statuses.remove(_statuses.keys.first);
    }
    return changed;
  }

  /// Looks once for [event]'s report among [room]'s newest stored events,
  /// when it is an own sent message of a bridged room whose status is not
  /// known yet. Look-ups run one after another; a found report announces
  /// [room] on [changes].
  void lookUp(Room room, Event event) {
    final id = event.eventId;
    if (!event.status.isSent ||
        _statuses.containsKey(id) ||
        _checked.contains(id) ||
        bridgeBotsOf(room).isEmpty) {
      return;
    }
    _checked.add(id);
    while (_checked.length > capacity) {
      _checked.remove(_checked.first);
    }
    debugLookups++;
    _queue = _queue.then((_) async {
      try {
        final events = await client.database.getEventList(
          room,
          limit: lookBack,
        );
        var changed = false;
        for (final report in events) {
          if (report.relationshipEventId != id) continue;
          changed = record(report) || changed;
        }
        if (changed) _changes.add(room.id);
      } catch (_) {
        // A store that cannot answer leaves the row at one tick.
      }
    });
  }
}

/// The ticks of an inbox row whose last message is [event] in [room] (one
/// source of a merged person): the same rule as the bubble, read when
/// another member's receipt is on this very message.
DeliveryProgress inboxDeliveryProgress(Room room, Event event) {
  final client = room.client;
  final account = event.senderId == client.userID;
  final ghost = !account && OwnSenderResolver.of(client).isOwnEvent(event);
  if (!account && !ghost) return DeliveryProgress.none;
  if (event.status.isError) return DeliveryProgress.failed;
  if (event.status.isSending) return DeliveryProgress.sending;
  final targets = ReceiptTargets.of(room);
  return resolveDeliveryProgress(
    own: true,
    status: event.status,
    bridge: BridgeDeliveryLedger.of(client).statusOf(event.eventId),
    fromNetwork: ghost || cameFromNetwork(event),
    deliveryReceipt: targets.acknowledged.contains(event.eventId),
    read: targets.read.contains(event.eventId),
  );
}
