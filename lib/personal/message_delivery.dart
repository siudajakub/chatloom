// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';

/// The status event mautrix bridges send about each bridged Matrix event
/// (`matrix.message_status_events`, enabled by Beeper's bridge manager): it
/// references the original with `m.reference` and says whether the remote
/// network accepted it.
const beeperMessageSendStatusType = 'com.beeper.message_send_status';

/// Listeners of [reportDeliveryOutcome] (tests, health monitors).
final deliveryOutcomeListeners = <void Function(Room room, bool failed)>[];

/// The one place every own send's final outcome passes through, once per
/// outcome: the SDK confirmed (`sent`) or gave up on (`error`) a local echo
/// of a text, edit, media or round send, or the room's bridge reported
/// `SUCCESS` / `FAIL_*` in `com.beeper.message_send_status`. Called by
/// `PersonalClient` from the client's timeline stream; never from a build.
///
/// Deliberately not forwarded to `BridgeHealthMonitor.noteDelivery`: the
/// monitor reads the bridge reports itself (forwarding would count each
/// failure twice), and an SDK outcome only says whether the homeserver took
/// the event, not whether the bridge delivered it.
void reportDeliveryOutcome(Room room, {required bool failed}) {
  for (final listener in List.of(deliveryOutcomeListeners)) {
    try {
      listener(room, failed);
    } catch (_) {
      // An observer never affects sending.
    }
  }
}

/// The delivery outcome [event] (a live timeline update) carries, or null.
/// Own local echoes report the SDK's final status; bridge reports younger
/// than [maxAge] (not history replayed by a catch-up sync) report theirs.
bool? deliveryOutcomeOf(
  Event event, {
  required String? ownUserId,
  required DateTime now,
  Duration maxAge = const Duration(minutes: 15),
}) {
  if (event.senderId == ownUserId) {
    if (event.type == beeperMessageSendStatusType) return null;
    return switch (event.status) {
      EventStatus.error => true,
      EventStatus.sent => false,
      _ => null,
    };
  }
  if (event.type != beeperMessageSendStatusType ||
      now.difference(event.originServerTs) > maxAge) {
    return null;
  }
  final report = BridgeSendStatus.parse(
    event.content,
    sender: event.senderId,
    bridgeBots: bridgeBotsOf(event.room),
    at: event.originServerTs,
  );
  if (report == null || report.status == 'PENDING') return null;
  return report.failed;
}

/// The bridge state events that name the room's bridge bot.
const _bridgeStateTypes = [
  'm.bridge',
  'uk.half-shot.bridge',
  'com.beeper.bridge',
];

/// One `com.beeper.message_send_status` report, already checked to come
/// from the room's bridge bot.
class BridgeSendStatus {
  /// `SUCCESS`, `PENDING`, `FAIL_RETRIABLE` or `FAIL_PERMANENT`.
  final String status;

  /// Machine reason, e.g. `m.foreign_network_error`.
  final String? reason;

  /// Human-readable explanation the bridge meant for display. The
  /// deprecated `error`/`internal_error` fields are never shown.
  final String? message;
  final DateTime at;

  const BridgeSendStatus({
    required this.status,
    required this.at,
    this.reason,
    this.message,
  });

  bool get failed => status == 'FAIL_RETRIABLE' || status == 'FAIL_PERMANENT';
  bool get retriable => status == 'FAIL_RETRIABLE';

  /// Parses [content] of a status event sent by [sender]. Only a declared
  /// bridge bot of the room may report delivery; anything else is ignored.
  static BridgeSendStatus? parse(
    Map<String, Object?> content, {
    required String sender,
    required Set<String> bridgeBots,
    required DateTime at,
  }) {
    if (!bridgeBots.contains(sender)) return null;
    final status = content['status'];
    if (status is! String ||
        !const {
          'SUCCESS',
          'PENDING',
          'FAIL_RETRIABLE',
          'FAIL_PERMANENT',
        }.contains(status)) {
      return null;
    }
    String? text(Object? value) {
      if (value is! String) return null;
      final trimmed = value.trim();
      if (trimmed.isEmpty) return null;
      // A display hint, not a log: one short paragraph at most.
      return trimmed.length > 280 ? '${trimmed.substring(0, 279)}…' : trimmed;
    }

    return BridgeSendStatus(
      status: status,
      reason: text(content['reason']),
      message: text(content['message']),
      at: at,
    );
  }

  /// The newest report wins (a retried message can fail, then succeed).
  static BridgeSendStatus? latest(Iterable<BridgeSendStatus> statuses) {
    BridgeSendStatus? newest;
    for (final status in statuses) {
      if (newest == null || !status.at.isBefore(newest.at)) newest = status;
    }
    return newest;
  }
}

enum MessageDeliveryKind {
  /// Nothing to show (sent, synced, or not our message).
  none,

  /// In the local outbox or on its way to the server. Shown only after a
  /// grace period, so a fast send never flashes "Sending…".
  sending,

  /// The server did not confirm the message (or its latest edit).
  notSent,

  /// The server has it, but the bridge reported that the remote network
  /// did not accept it.
  notDelivered,
}

/// What a message's bubble says about its delivery, and which actions its
/// failure offers. Pure: built from statuses, so it is unit-tested without
/// widgets and computed per visible row without I/O.
class MessageDelivery {
  final MessageDeliveryKind kind;

  /// Short line under the bubble ("Not sent · Tap to retry").
  final String label;

  /// Longer explanation for the action sheet, or null.
  final String? detail;

  /// The failure concerns an edit, not the original message.
  final bool edit;

  /// Retry with the same transaction (not sent), or send a copy (a bridge
  /// rejection that may work again).
  final bool canRetry;

  /// The unsent local echo can be removed.
  final bool canDelete;

  const MessageDelivery._(
    this.kind, {
    this.label = '',
    this.detail,
    this.edit = false,
    this.canRetry = false,
    this.canDelete = false,
  });

  static const none = MessageDelivery._(MessageDeliveryKind.none);

  bool get failed =>
      kind == MessageDeliveryKind.notSent ||
      kind == MessageDeliveryKind.notDelivered;

  /// [status] is the message's own status, [editStatuses] those of the
  /// user's own edits of it, [bridge] the newest bridge report and
  /// [network] the bridged network's display name (null when unbridged).
  static MessageDelivery resolve({
    required bool own,
    required EventStatus status,
    Iterable<EventStatus> editStatuses = const [],
    BridgeSendStatus? bridge,
    String? network,
  }) {
    if (!own) return none;
    if (status.isError) {
      return const MessageDelivery._(
        MessageDeliveryKind.notSent,
        label: 'Not sent · Tap to retry',
        canRetry: true,
        canDelete: true,
      );
    }
    if (status.isSending) {
      return const MessageDelivery._(
        MessageDeliveryKind.sending,
        label: 'Sending…',
      );
    }
    if (editStatuses.any((s) => s.isError)) {
      return const MessageDelivery._(
        MessageDeliveryKind.notSent,
        label: 'Edit not sent · Tap to retry',
        edit: true,
        canRetry: true,
        canDelete: true,
      );
    }
    if (bridge != null && bridge.failed) {
      final where = network == null ? '' : ' to $network';
      return MessageDelivery._(
        MessageDeliveryKind.notDelivered,
        label: 'Not delivered$where · Tap for details',
        detail: bridgeFailureText(bridge, network: network),
        canRetry: bridge.retriable,
      );
    }
    return none;
  }
}

/// A plain-language reason for a bridge rejection. The bridge's own display
/// message is preferred; the reason code is the fallback.
String bridgeFailureText(BridgeSendStatus status, {String? network}) {
  final remote = network ?? 'The other network';
  final fallback = switch (status.reason) {
    'm.foreign_network_error' => '$remote returned an error.',
    'm.no_permission' => 'You are not allowed to send this here.',
    'com.beeper.unsupported_event' => '$remote does not support this message.',
    'com.beeper.undecryptable_event' =>
      'The bridge could not decrypt this message.',
    'm.event_too_old' => 'The message was too old to deliver.',
    'm.bridge_unavailable' => 'The bridge is offline.',
    _ => 'The bridge could not deliver this message.',
  };
  final message = status.message;
  final base = message == null
      ? fallback
      : RegExp(r'[.!?…]$').hasMatch(message)
      ? message
      : '$message.';
  return status.retriable
      ? '$base Sending it again may work.'
      : '$base It will not be retried.';
}

/// The declared bridge bots of [room] (`bridgebot` of its bridge state).
Set<String> bridgeBotsOf(Room room) => {
  for (final type in _bridgeStateTypes)
    for (final state
        in room.states[type]?.values ?? const <StrippedStateEvent>[])
      if (state.content['bridgebot'] case final String bot when bot.isNotEmpty)
        bot,
};

/// Bridge reports about [event] in [timeline], trusted senders only.
Iterable<BridgeSendStatus> bridgeStatusesOf(
  Event event,
  Timeline timeline,
) sync* {
  final related = event.aggregatedEvents(timeline, RelationshipTypes.reference);
  if (related.isEmpty) return;
  final bots = bridgeBotsOf(event.room);
  if (bots.isEmpty) return;
  for (final report in related) {
    if (report.type != beeperMessageSendStatusType) continue;
    final parsed = BridgeSendStatus.parse(
      report.content,
      sender: report.senderId,
      bridgeBots: bots,
      at: report.originServerTs,
    );
    if (parsed != null) yield parsed;
  }
}

/// The delivery state of [event] (an own message row) in [timeline].
/// [network] names the bridged network; it is only called for a bridge
/// rejection, so ordinary rows never compute it.
MessageDelivery messageDeliveryOf(
  Event event,
  Timeline timeline, {
  String? Function()? network,
}) {
  final own = event.senderId == event.room.client.userID;
  if (!own) return MessageDelivery.none;
  final edits = event.status.isSent
      ? [
          for (final edit in event.aggregatedEvents(
            timeline,
            RelationshipTypes.edit,
          ))
            if (edit.senderId == event.senderId) edit.status,
        ]
      : const <EventStatus>[];
  final bridge = event.status.isSent
      ? BridgeSendStatus.latest(bridgeStatusesOf(event, timeline))
      : null;
  return MessageDelivery.resolve(
    own: true,
    status: event.status,
    editStatuses: edits,
    bridge: bridge,
    network: bridge != null && bridge.failed ? network?.call() : null,
  );
}
