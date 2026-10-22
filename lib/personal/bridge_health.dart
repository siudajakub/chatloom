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
    this.live = false,
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

  /// Read from the bridge's provisioning `whoami` (the login's current
  /// state) rather than from a notice in the management room. [at] is when
  /// this device first saw the login in this state.
  final bool live;

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

  /// One login of a provisioning `whoami` answer (`logins[]`: `id`, `name`
  /// and the full bridge `state`), fetched at [fetchedAt]. A login without a
  /// readable state is null (nothing known about it).
  static BridgeStateReport? fromLogin({
    required String network,
    required String loginId,
    required String loginName,
    required Object? state,
    required DateTime fetchedAt,
  }) {
    final parsed = parse(state, network: network, fallback: fetchedAt);
    if (parsed == null) return null;
    String? name(String value) =>
        value.isNotEmpty && value.length <= 64 ? value : null;
    return BridgeStateReport(
      network: network,
      stateEvent: parsed.stateEvent,
      at: parsed.at,
      login: loginId.length <= 256 ? loginId : '',
      error: parsed.error,
      userAction: parsed.userAction,
      remoteName: parsed.remoteName ?? name(loginName),
      live: true,
    );
  }

  /// A copy first seen at [since] (the state began before this answer).
  BridgeStateReport seenSince(DateTime since) => BridgeStateReport(
    network: network,
    stateEvent: stateEvent,
    at: since,
    login: login,
    error: error,
    userAction: userAction,
    roomId: roomId,
    remoteName: remoteName,
    live: live,
  );

  /// The same state as [other] (an answer that only repeats it).
  bool sameStateAs(BridgeStateReport other) =>
      other.stateEvent == stateEvent &&
      other.error == error &&
      other.userAction == userAction;

  /// A passing state bridgev2 itself hides for 3 minutes
  /// (`TransientDisconnectNoticeDelay`): the bridge reconnects on its own.
  bool get transient => const {
    'STARTING',
    'CONNECTING',
    'TRANSIENT_DISCONNECT',
    'UNKNOWN_ERROR',
  }.contains(stateEvent);

  BridgeHealthState get state {
    if (userAction == 'RELOGIN') return BridgeHealthState.loggedOut;
    return switch (stateEvent) {
      'CONNECTED' || 'BACKFILLING' || 'RUNNING' =>
        userAction == 'OPEN_NATIVE'
            ? BridgeHealthState.degraded
            : BridgeHealthState.ok,
      // The bridge reconnects by itself: amber, not red.
      'CONNECTING' ||
      'STARTING' ||
      'TRANSIENT_DISCONNECT' => BridgeHealthState.degraded,
      'UNKNOWN_ERROR' || 'BRIDGE_UNREACHABLE' => BridgeHealthState.disconnected,
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

  /// Current login states from the provisioning `whoami`, by login id
  /// (replaced with every answer; empty when the bridge has no login).
  Map<String, BridgeStateReport> live = const {};

  /// When `whoami` last answered (null: never on this device).
  DateTime? liveAt;

  /// Since when `whoami` lists no login at all.
  DateTime? noLoginSince;

  /// A `whoami` request is in flight.
  bool liveChecking = false;

  /// This device can't ask the bridge (no provisioning route, not a Beeper
  /// bridge, or the route answered something else).
  bool liveUnavailable = false;

  /// `whoami` failed repeatedly while other bridges answered: the bridge
  /// process itself seems down (set by the monitor).
  DateTime? unreachableSince;

  /// The user signed out of this network from this device (CC-25).
  DateTime? signedOutAt;

  /// The management room `whoami` reported.
  String? liveManagementRoomId;

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

  /// Stores one `whoami` answer fetched at [at]. A login that keeps its
  /// state keeps the time it was first seen in it, so the 3-minute delay of
  /// passing states counts from the start, not from the latest answer.
  void setLive(
    Iterable<BridgeStateReport> logins,
    DateTime at, {
    String? managementRoomId,
  }) {
    final previous = live;
    live = {
      for (final report in logins)
        report.login: switch (previous[report.login]) {
          final old?
              when old.sameStateAs(report) && old.at.isBefore(report.at) =>
            report.seenSince(old.at),
          _ => report,
        },
    };
    liveAt = at;
    liveUnavailable = false;
    unreachableSince = null;
    if (live.isEmpty) {
      noLoginSince ??= at;
    } else {
      noLoginSince = null;
    }
    if (managementRoomId != null) liveManagementRoomId = managementRoomId;
    // Signed in again after a sign-out from this device.
    final signedOut = signedOutAt;
    if (signedOut != null &&
        at.isAfter(signedOut.add(BridgeHealthRules.signOutSettle)) &&
        live.values.any((report) => report.state == BridgeHealthState.ok)) {
      signedOutAt = null;
    }
  }

  /// [now] is within the time a `whoami` answer stays current (or a newer
  /// one is on its way, so the last one still stands).
  bool liveFresh(DateTime now) {
    final at = liveAt;
    if (at == null) return false;
    return liveChecking || now.difference(at) < BridgeHealthRules.liveTtl;
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
    this.stateEvent,
    this.signedIn = false,
    this.userInitiated = false,
    this.checking = false,
    this.unavailable = false,
  });

  final String network;
  final BridgeHealthState state;

  /// The bridge state behind a problem (`BAD_CREDENTIALS`,
  /// `TRANSIENT_DISCONNECT`, …); null for delivery failures and healthy or
  /// unknown networks.
  final String? stateEvent;

  /// A signed-in login is known (from `whoami`, or a bridge notice when the
  /// bridge can't be asked): the only basis for offering "Sign out".
  final bool signedIn;

  /// Signed out by the user from this device: shown on the network page and
  /// in its chats, never as an inbox alert.
  final bool userInitiated;

  /// Nothing known yet and the bridge is being asked right now.
  final bool checking;

  /// This device can't ask the bridge for its status.
  final bool unavailable;

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
      other.summary == summary &&
      other.stateEvent == stateEvent &&
      other.signedIn == signedIn &&
      other.userInitiated == userInitiated &&
      other.checking == checking &&
      other.unavailable == unavailable;

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
    stateEvent,
    signedIn,
    userInitiated,
    checking,
    unavailable,
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

  /// How long a `whoami` answer stays current.
  static const liveTtl = Duration(minutes: 15);

  /// Passing states (reconnecting, an unknown error the bridge retries) show
  /// only once they last this long, as bridgev2 does for its notices.
  static const transientDelay = Duration(minutes: 3);

  /// A remote message this recent proves the bridge delivers (when nothing
  /// fresher is known).
  static const inboundFresh = Duration(minutes: 30);

  /// After "Sign out of a network", answers this soon may still list the
  /// login (the bridge has not processed the command yet).
  static const signOutSettle = Duration(minutes: 2);

  /// While the app is in the foreground, `whoami` is asked this often.
  static const liveInterval = Duration(minutes: 5);

  /// Retry after a failed `whoami`: doubles from [retryBase] up to
  /// [retryMax].
  static const retryBase = Duration(minutes: 1);
  static const retryMax = Duration(minutes: 30);

  /// A bridge that can't be asked at all is tried again this late.
  static const unavailableRetry = Duration(minutes: 30);

  /// Consecutive failed `whoami` answers (over at least [transientDelay],
  /// while other bridges answer) before a bridge counts as not responding.
  static const unreachableFailures = 3;
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
/// * A current `whoami` answer is the truth about each login: passing states
///   ([BridgeStateReport.transient]) count only after
///   [BridgeHealthRules.transientDelay]; signed-out states count at once; no
///   login at all is "Not signed in". Without one, the worst login notice
///   wins, unless remote messages arrived after it (a bridge that restarts
///   does not repeat CONNECTED after an error it forgot).
/// * "Sign out" from this device reads as signed out until the bridge
///   confirms, or [BridgeHealthRules.signOutSettle] has passed.
/// * Without a problem, [BridgeHealthRules.failureThreshold] recent
///   delivery failures with nothing delivered or received since make the
///   network degraded.
/// * Healthy needs evidence: a current `whoami` login that is connected, a
///   CONNECTED notice, or a recent remote message. Anything else is
///   [BridgeHealthState.unknown] ("Status unknown"), never "Connected".
/// * Silence alone never raises an alarm: quiet chats are normal.
BridgeHealth evaluateBridgeHealth(
  String network,
  BridgeSignals signals,
  DateTime now,
) {
  final label = notionNetworkLabel(network);
  final inbound = signals.lastInbound;
  final room = signals.managementRoomId ?? signals.liveManagementRoomId;
  final fresh = signals.liveFresh(now);
  final liveAt = signals.liveAt;
  final signedOutAt = signals.signedOutAt;
  // A sign-out the bridge has not confirmed yet still counts.
  final pendingSignOut =
      signedOutAt != null &&
      (liveAt == null ||
          !liveAt.isAfter(signedOutAt.add(BridgeHealthRules.signOutSettle)));
  final candidates = <BridgeStateReport>[
    if (fresh) ...[
      ...signals.live.values,
      // Notices newer than the answer (bridges that send them).
      for (final report in signals.reports.values)
        if (report.at.isAfter(liveAt!)) report,
      if (signals.live.isEmpty)
        BridgeStateReport(
          network: network,
          stateEvent: 'UNCONFIGURED',
          at: signals.noLoginSince ?? liveAt!,
          live: true,
        ),
    ] else
      ...signals.reports.values,
    if (pendingSignOut)
      BridgeStateReport(
        network: network,
        stateEvent: 'LOGGED_OUT',
        at: signedOutAt,
        live: true,
      ),
    if (signals.unreachableSince case final since? when !pendingSignOut)
      BridgeStateReport(
        network: network,
        stateEvent: 'BRIDGE_UNREACHABLE',
        at: since,
        live: true,
      ),
  ];
  BridgeStateReport? worst;
  var positive = false;
  var signedIn = false;
  for (final report in candidates) {
    final state = report.state;
    final passing =
        report.live &&
        report.transient &&
        now.difference(report.at) < BridgeHealthRules.transientDelay;
    if (state != BridgeHealthState.loggedOut &&
        report.stateEvent != 'BRIDGE_UNREACHABLE') {
      signedIn = true;
    }
    if (!state.isProblem || passing) {
      // A login that works, or reconnects within the delay.
      if (state == BridgeHealthState.ok || passing) positive = true;
      continue;
    }
    // Remote messages after a problem prove the bridge works again; a
    // current "signed out" answer stands (they may come from another login).
    final healed =
        inbound != null &&
        inbound.isAfter(report.at.add(BridgeHealthRules.healMargin)) &&
        !(report.live && state == BridgeHealthState.loggedOut);
    if (healed) continue;
    if (worst == null ||
        state.severity > worst.state.severity ||
        (state.severity == worst.state.severity &&
            report.at.isBefore(worst.at))) {
      worst = report;
    }
  }
  if (pendingSignOut) signedIn = false;
  final userInitiated = signedOutAt != null;
  if (worst != null) {
    final state = worst.state;
    final unconfigured = worst.stateEvent == 'UNCONFIGURED';
    final unreachable = worst.stateEvent == 'BRIDGE_UNREACHABLE';
    final outdated = worst.error == 'wa-client-outdated';
    final (title, reason, summary) = switch (state) {
      BridgeHealthState.loggedOut when userInitiated => (
        'You signed out of $label',
        'Sign in again to get $label messages here.',
        'Signed out',
      ),
      BridgeHealthState.loggedOut => (
        unconfigured ? '$label isn’t signed in' : '$label is signed out',
        unconfigured
            ? 'No $label account is signed in to the bridge. Messages won’t '
                  'arrive until you sign in.'
            : 'Messages won’t arrive until you sign in again.',
        unconfigured ? 'Not signed in' : 'Signed out',
      ),
      BridgeHealthState.disconnected when outdated => (
        '$label bridge needs an update',
        '$label stopped accepting this bridge version. Messages won’t arrive '
            'until the bridge is updated.',
        'Bridge needs an update',
      ),
      // Our own guess from failing requests says "not responding"; the
      // server's BRIDGE_UNREACHABLE says the process isn't running.
      BridgeHealthState.disconnected when unreachable => (
        worst.live
            ? '$label bridge isn’t responding'
            : '$label bridge isn’t running',
        'Messages may not arrive or be delivered until it reconnects.',
        worst.live ? 'Bridge isn’t responding' : 'Bridge isn’t running',
      ),
      BridgeHealthState.disconnected => (
        '$label is disconnected',
        'Messages may not arrive or be delivered until it reconnects.',
        'Disconnected',
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
      stateEvent: worst.stateEvent,
      signedIn: signedIn,
      userInitiated: userInitiated && state == BridgeHealthState.loggedOut,
      // Live states repeat with every answer: their identity is the state,
      // not a timestamp, so "hide until something changes" holds.
      signature: worst.live
          ? 'bridge:$network:${worst.stateEvent}:${worst.error ?? ''}'
          : 'bridge:$network:${worst.stateEvent}:'
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
      signedIn: signedIn,
      signature:
          'bridge:$network:delivery:${first.millisecondsSinceEpoch ~/ 1000}',
    );
  }
  if (inbound != null &&
      now.difference(inbound) < BridgeHealthRules.inboundFresh) {
    positive = true;
  }
  if (positive) {
    return BridgeHealth(
      network: network,
      state: BridgeHealthState.ok,
      title: '$label is connected',
      summary: 'Connected',
      reason: '',
      managementRoomId: room,
      signedIn: signedIn,
      signature: 'bridge:$network:ok',
    );
  }
  final checking = signals.liveChecking && liveAt == null;
  final unavailable = signals.liveUnavailable && !fresh;
  return BridgeHealth(
    network: network,
    state: BridgeHealthState.unknown,
    title: checking ? 'Checking $label…' : '$label status unknown',
    summary: checking ? 'Checking…' : 'Status unknown',
    reason: unavailable
        ? 'ChatLoom can’t check this bridge from this device.'
        : checking
        ? ''
        : 'The bridge hasn’t reported its status recently.',
    managementRoomId: room,
    signedIn: signedIn,
    checking: checking,
    unavailable: unavailable,
    signature: 'bridge:$network:unknown',
  );
}

/// When [evaluateBridgeHealth] of [signals] next changes without a new
/// signal (a passing state reaches its delay, a remote message or an answer
/// stops being recent, a failure leaves the window), or null. The monitor
/// re-evaluates once at that moment instead of polling.
DateTime? nextBridgeHealthChange(BridgeSignals signals, DateTime now) {
  DateTime? next;
  void consider(DateTime at) {
    if (!at.isAfter(now)) return;
    if (next == null || at.isBefore(next!)) next = at;
  }

  for (final report in signals.live.values) {
    if (report.transient)
      consider(report.at.add(BridgeHealthRules.transientDelay));
  }
  final inbound = signals.lastInbound;
  if (inbound != null) consider(inbound.add(BridgeHealthRules.inboundFresh));
  final liveAt = signals.liveAt;
  if (liveAt != null) consider(liveAt.add(BridgeHealthRules.liveTtl));
  final signedOut = signals.signedOutAt;
  if (signedOut != null) {
    consider(signedOut.add(BridgeHealthRules.signOutSettle));
  }
  for (final delivery in signals.deliveries) {
    if (delivery.failed) {
      consider(delivery.at.add(BridgeHealthRules.failureWindow));
    }
  }
  return next;
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
