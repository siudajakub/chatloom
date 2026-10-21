// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/ui/notion_network_filter.dart';
import 'package:flutter/foundation.dart';

/// How well one network's bridge works, worst first in [severity].
enum BridgeHealthState { ok, unknown, degraded, disconnected, loggedOut }

extension BridgeHealthSeverity on BridgeHealthState {
  /// Higher is worse; [BridgeHealthState.unknown] never outranks a report.
  int get severity => switch (this) {
    BridgeHealthState.ok => 0,
    BridgeHealthState.unknown => 0,
    BridgeHealthState.degraded => 1,
    BridgeHealthState.disconnected => 2,
    BridgeHealthState.loggedOut => 3,
  };

  /// A state worth telling the user about.
  bool get isProblem => severity > 0;
}

/// Content key of the bridge state a mautrix bridgev2 bridge attaches to its
/// management-room notices (`bridge.bridge_status_notices`, default
/// `errors`): sent on bad credentials, unknown errors, "open the native app",
/// a disconnect that lasted 3 minutes, and the CONNECTED that follows an
/// error notice.
const bridgeStateNoticeKey = 'fi.mau.bridge_state';

/// Beeper's per-message delivery report from a bridge
/// (`bridge.message_status_events`).
const bridgeMessageStatusType = 'com.beeper.message_send_status';

/// One bridge state notice, reduced to allowlisted fields. Nothing here is
/// logged; [login] (the remote login id) only groups notices in memory.
@immutable
class BridgeStateReport {
  const BridgeStateReport({
    required this.network,
    required this.stateEvent,
    required this.at,
    this.login = '',
    this.error,
    this.userAction,
    this.roomId,
    this.remoteName,
  });

  /// Canonical network (`whatsapp`, `instagram`, ...).
  final String network;

  /// `CONNECTED`, `TRANSIENT_DISCONNECT`, `BAD_CREDENTIALS`, ...
  final String stateEvent;
  final DateTime at;
  final String login;

  /// Machine error code (`wa-logged-out`); kept for the signature only.
  final String? error;

  /// `OPEN_NATIVE`, `RELOGIN` or `RESTART`.
  final String? userAction;

  /// Management room the notice arrived in (the "Open bridge" target).
  final String? roomId;

  /// The bridge's display name of the signed-in account (`remote_name`, e.g.
  /// the account's own phone number or username). Shown only to the account
  /// owner on the Networks page; never logged.
  final String? remoteName;

  static const _states = {
    'STARTING',
    'UNCONFIGURED',
    'RUNNING',
    'BRIDGE_UNREACHABLE',
    'CONNECTING',
    'BACKFILLING',
    'CONNECTED',
    'TRANSIENT_DISCONNECT',
    'BAD_CREDENTIALS',
    'UNKNOWN_ERROR',
    'LOGGED_OUT',
  };

  /// Parses the `fi.mau.bridge_state` object of a notice. [fallback] is the
  /// event's server time, used when the state has no valid timestamp (its
  /// own `timestamp` is in seconds).
  static BridgeStateReport? parse(
    Object? state, {
    required String network,
    required DateTime fallback,
    String? roomId,
  }) {
    if (state is! Map) return null;
    final event = state['state_event'];
    if (event is! String || !_states.contains(event)) return null;
    final seconds = state['timestamp'];
    var at = fallback;
    if (seconds is num && seconds > 0) {
      final parsed = DateTime.fromMillisecondsSinceEpoch(
        (seconds * 1000).round(),
        isUtc: true,
      );
      // A bridge clock far ahead of the server must not pin a state.
      if (!parsed.isAfter(fallback.add(const Duration(minutes: 5)))) {
        at = parsed;
      }
    }
    String? text(Object? value, [int max = 64]) =>
        value is String && value.isNotEmpty && value.length <= max
        ? value
        : null;
    return BridgeStateReport(
      network: network,
      stateEvent: event,
      at: at,
      login: text(state['remote_id'], 256) ?? '',
      error: text(state['error']),
      userAction: text(state['user_action']),
      roomId: roomId,
      remoteName: text(state['remote_name']),
    );
  }

  BridgeHealthState get state {
    if (userAction == 'RELOGIN') return BridgeHealthState.loggedOut;
    return switch (stateEvent) {
      'CONNECTED' || 'BACKFILLING' || 'RUNNING' =>
        userAction == 'OPEN_NATIVE'
            ? BridgeHealthState.degraded
            : BridgeHealthState.ok,
      'CONNECTING' || 'STARTING' => BridgeHealthState.degraded,
      'TRANSIENT_DISCONNECT' ||
      'UNKNOWN_ERROR' ||
      'BRIDGE_UNREACHABLE' => BridgeHealthState.disconnected,
      'BAD_CREDENTIALS' ||
      'LOGGED_OUT' ||
      'UNCONFIGURED' => BridgeHealthState.loggedOut,
      _ => BridgeHealthState.unknown,
    };
  }
}

/// One failed (or confirmed) outgoing delivery reported by a bridge.
@immutable
class BridgeDelivery {
  const BridgeDelivery({required this.at, required this.failed});

  final DateTime at;
  final bool failed;

  /// Reads a `com.beeper.message_send_status` content; `null` for pending or
  /// unknown statuses. Only failures caused by the bridge or the remote
  /// network count (not "unsupported" or "no permission").
  static BridgeDelivery? parse(Map<String, Object?> content, DateTime at) {
    final status = content['status'];
    if (status == 'SUCCESS') return BridgeDelivery(at: at, failed: false);
    if (status != 'FAIL_RETRIABLE' && status != 'FAIL_PERMANENT') return null;
    final reason = content['reason'];
    const network = {
      'm.bridge_unavailable',
      'm.foreign_network_error',
      'm.event_not_handled',
    };
    if (reason is String && !network.contains(reason)) return null;
    return BridgeDelivery(at: at, failed: true);
  }
}

/// What the client currently knows about one network.
class BridgeSignals {
  /// Latest notice per remote login.
  final Map<String, BridgeStateReport> reports = {};

  /// Newest message from the remote side (a ghost user, or the bridge's
  /// double puppet of the account): proof the bridge delivers again.
  DateTime? lastInbound;

  /// Recent delivery reports, newest last, at most [maxDeliveries].
  final List<BridgeDelivery> deliveries = [];

  /// Management room (DM with the bridge bot), if known.
  String? managementRoomId;

  static const maxDeliveries = 8;

  bool addReport(BridgeStateReport report) {
    final current = reports[report.login];
    if (current != null && !report.at.isAfter(current.at)) return false;
    reports[report.login] = report;
    if (report.roomId != null) managementRoomId = report.roomId;
    return true;
  }

  bool addInbound(DateTime at) {
    final current = lastInbound;
    if (current != null && !at.isAfter(current)) return false;
    lastInbound = at;
    return true;
  }

  void addDelivery(BridgeDelivery delivery) {
    deliveries.add(delivery);
    deliveries.sort((a, b) => a.at.compareTo(b.at));
    if (deliveries.length > maxDeliveries) deliveries.removeAt(0);
  }
}

/// The verdict for one network, with a human reason.
@immutable
class BridgeHealth {
  const BridgeHealth({
    required this.network,
    required this.state,
    required this.title,
    required this.reason,
    required this.signature,
    this.since,
    this.managementRoomId,
    this.summary = '',
  });

  final String network;
  final BridgeHealthState state;

  /// "WhatsApp is signed out".
  final String title;

  /// The same verdict without the network name, for a row that already
  /// shows it: "Signed out", "Reconnecting". Falls back to [title].
  final String summary;

  /// What it means for the user, one sentence.
  final String reason;

  /// Stable identity for "dismissed until it changes" (no ids, no text).
  final String signature;
  final DateTime? since;
  final String? managementRoomId;

  String get label => notionNetworkLabel(network);

  /// [reason] with how long the problem lasts, computed when shown.
  String describe(DateTime now) {
    final at = since;
    if (at == null || reason.isEmpty) return reason;
    final age = bridgeHealthAge(at, now);
    return '$reason ${age[0].toUpperCase()}${age.substring(1)}.';
  }

  @override
  bool operator ==(Object other) =>
      other is BridgeHealth &&
      other.network == network &&
      other.state == state &&
      other.title == title &&
      other.reason == reason &&
      other.signature == signature &&
      other.since == since &&
      other.managementRoomId == managementRoomId &&
      other.summary == summary;

  @override
  int get hashCode => Object.hash(
    network,
    state,
    title,
    reason,
    signature,
    since,
    managementRoomId,
    summary,
  );
}

/// Tunables of [evaluateBridgeHealth].
abstract final class BridgeHealthRules {
  /// Remote messages this long after a problem notice prove recovery (the
  /// bridge may flush a backlog stamped just before the notice).
  static const healMargin = Duration(minutes: 1);

  /// Failed deliveries newer than this count.
  static const failureWindow = Duration(minutes: 30);

  /// Failures in [failureWindow] (with no delivery or remote message after
  /// them) before the network counts as degraded.
  static const failureThreshold = 2;
}

/// Compact "for 5 min" / "for 3 h" / "for 2 days".
String bridgeHealthAge(DateTime since, DateTime now) {
  final age = now.difference(since);
  if (age.isNegative || age < const Duration(minutes: 1)) return 'just now';
  if (age < const Duration(hours: 1)) return 'for ${age.inMinutes} min';
  if (age < const Duration(days: 1)) return 'for ${age.inHours} h';
  final days = age.inDays;
  return days == 1 ? 'for 1 day' : 'for $days days';
}

/// Reduces every signal of [network] to one verdict. Pure: the same signals
/// and [now] always give the same answer.
///
/// * The worst current login notice wins, unless remote messages arrived
///   after it (then the bridge evidently works again: a bridge that
///   restarts does not repeat CONNECTED after an error it forgot).
/// * Without a problem notice, [BridgeHealthRules.failureThreshold] recent
///   delivery failures with nothing delivered or received since make the
///   network degraded.
/// * Silence alone never raises an alarm: quiet chats are normal.
BridgeHealth evaluateBridgeHealth(
  String network,
  BridgeSignals signals,
  DateTime now,
) {
  final label = notionNetworkLabel(network);
  final inbound = signals.lastInbound;
  BridgeStateReport? worst;
  var anyReport = false;
  for (final report in signals.reports.values) {
    anyReport = true;
    final state = report.state;
    if (!state.isProblem) continue;
    final healed =
        inbound != null &&
        inbound.isAfter(report.at.add(BridgeHealthRules.healMargin));
    if (healed) continue;
    if (worst == null ||
        state.severity > worst.state.severity ||
        (state.severity == worst.state.severity &&
            report.at.isBefore(worst.at))) {
      worst = report;
    }
  }
  final room = signals.managementRoomId;
  if (worst != null) {
    final state = worst.state;
    final (title, reason, summary) = switch (state) {
      BridgeHealthState.loggedOut => (
        '$label is signed out',
        worst.stateEvent == 'UNCONFIGURED'
            ? 'No $label account is signed in to the bridge. Messages won’t '
                  'arrive until you sign in in the bridge chat.'
            : 'Messages won’t arrive until you sign in again in the bridge '
                  'chat.',
        worst.stateEvent == 'UNCONFIGURED' ? 'Not signed in' : 'Signed out',
      ),
      BridgeHealthState.disconnected => (
        worst.stateEvent == 'BRIDGE_UNREACHABLE'
            ? '$label bridge isn’t running'
            : '$label is disconnected',
        'Messages may not arrive or be delivered until it reconnects.',
        worst.stateEvent == 'BRIDGE_UNREACHABLE'
            ? 'Bridge isn’t running'
            : 'Disconnected',
      ),
      _ =>
        worst.userAction == 'OPEN_NATIVE'
            ? (
                '$label needs its phone app',
                'Open $label on your phone so the bridge stays connected.',
                'Open the app on your phone',
              )
            : (
                '$label is reconnecting',
                'Messages may be delayed.',
                'Reconnecting',
              ),
    };
    return BridgeHealth(
      network: network,
      state: state,
      title: title,
      reason: reason,
      summary: summary,
      since: worst.at,
      managementRoomId: room,
      signature:
          'bridge:$network:${worst.stateEvent}:'
          '${worst.error ?? ''}:${worst.at.millisecondsSinceEpoch ~/ 1000}',
    );
  }
  final recentFailures = <BridgeDelivery>[];
  for (final delivery in signals.deliveries.reversed) {
    if (!delivery.failed) break;
    if (now.difference(delivery.at) > BridgeHealthRules.failureWindow) break;
    if (inbound != null && !inbound.isBefore(delivery.at)) break;
    recentFailures.add(delivery);
  }
  if (recentFailures.length >= BridgeHealthRules.failureThreshold) {
    final first = recentFailures.last.at;
    return BridgeHealth(
      network: network,
      state: BridgeHealthState.degraded,
      title: '$label isn’t delivering messages',
      summary: 'Messages aren’t being delivered',
      reason:
          '${recentFailures.length} recent messages to $label failed. The '
          'bridge may be disconnected.',
      since: first,
      managementRoomId: room,
      signature:
          'bridge:$network:delivery:${first.millisecondsSinceEpoch ~/ 1000}',
    );
  }
  return BridgeHealth(
    network: network,
    state: anyReport || inbound != null
        ? BridgeHealthState.ok
        : BridgeHealthState.unknown,
    title: '$label is connected',
    summary: 'Connected',
    reason: '',
    managementRoomId: room,
    signature: 'bridge:$network:ok',
  );
}

/// Network of a bridge bot from its user id when no room declares it, e.g.
/// `@sh-whatsappbot:beeper.local` or `@instagrambot:example.org`.
String? bridgeBotNetworkFromId(String userId) {
  final match = RegExp(r'^@(?:sh-)?([a-z]+?)(?:go)?bot:').firstMatch(userId);
  final name = match?.group(1);
  if (name == null) return null;
  final network = canonicalNetwork(name);
  return network == 'matrix' ? null : network;
}
