// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/bridge_health.dart';
import 'package:chatloom/personal/connection_status.dart';
import 'package:chatloom/personal/encryption/e2ee_health.dart';
import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/personal/push_registration.dart';
import 'package:chatloom/personal/worker_readiness.dart';
import 'package:flutter/foundation.dart';

/// Where an inbox health problem comes from.
enum HealthSource { connection, e2ee, bridge, push, worker }

/// What the one-tap action of a health problem does.
enum HealthAction {
  /// Sync again now.
  retrySync,

  /// Open the bridge bot's management room ([HealthIssue.roomId]).
  openBridgeChat,

  /// The details sheet (no better fix is known).
  details,

  /// Push a settings route ([HealthIssue.route]).
  openRoute,

  /// Run the E2EE fix of [HealthIssue.e2ee].
  e2eeFix,
}

/// One problem the inbox status row can show, from any source.
@immutable
class HealthIssue {
  const HealthIssue({
    required this.source,
    required this.priority,
    required this.title,
    required this.message,
    required this.actionLabel,
    required this.action,
    required this.signature,
    this.severity = HealthSeverity.warning,
    this.roomId,
    this.route,
    this.e2ee,
    this.network,
    this.bridgeState,
    this.persistentDismissal = true,
  });

  final HealthSource source;

  /// Lower shows first.
  final int priority;
  final String title;
  final String message;
  final String actionLabel;
  final HealthAction action;
  final HealthSeverity severity;

  /// Stable identity for "hidden until something changes".
  final String signature;
  final String? roomId;
  final String? route;
  final E2eeIssue? e2ee;
  final String? network;
  final BridgeHealthState? bridgeState;

  /// False for passing problems (connection): a dismissal lasts only until
  /// the problem goes away, and is never stored.
  final bool persistentDismissal;
}

enum HealthSeverity { neutral, warning, danger }

/// Priorities: the connection first (while offline every other signal may
/// be stale), then anything that silently loses messages, then setup.
abstract final class HealthPriority {
  static const connection = 0;
  static const encryptionOff = 10;
  static const bridgeLoggedOut = 20;
  static const bridgeDisconnected = 25;
  static const storage = 28;
  static const push = 30;
  static const e2eeSetup = 40;
  static const bridgeDegraded = 50;
  static const privateSync = 55;
  static const worker = 60;
  static const undecryptable = 70;
  static const devices = 75;
  static const workerOutdated = 80;
}

/// The inbox notice of a connection problem. Only a lasting one is passed
/// here (`ConnectionStatusMonitor.lasting`); before that the header line says
/// it quietly. Shown compact (one row), so the message stays short.
HealthIssue? connectionIssue(ConnectionPhase phase) => switch (phase) {
  ConnectionPhase.waitingForNetwork => const HealthIssue(
    source: HealthSource.connection,
    priority: HealthPriority.connection,
    title: 'No internet connection',
    message: 'Showing loaded chats',
    actionLabel: 'Retry',
    action: HealthAction.retrySync,
    severity: HealthSeverity.neutral,
    signature: 'connection:network',
    persistentDismissal: false,
  ),
  ConnectionPhase.connecting => const HealthIssue(
    source: HealthSource.connection,
    priority: HealthPriority.connection,
    title: 'Can’t reach the server',
    message: 'Retrying automatically',
    actionLabel: 'Retry',
    action: HealthAction.retrySync,
    severity: HealthSeverity.neutral,
    signature: 'connection:server',
    persistentDismissal: false,
  ),
  _ => null,
};

HealthIssue e2eeHealthIssue(E2eeIssue issue) {
  final priority = switch (issue.kind) {
    E2eeIssueKind.encryptionOff => HealthPriority.encryptionOff,
    E2eeIssueKind.recovery || E2eeIssueKind.session => HealthPriority.e2eeSetup,
    E2eeIssueKind.privateSync =>
      issue.signature == 'sync:storageUnavailable'
          ? HealthPriority.storage
          : HealthPriority.privateSync,
    E2eeIssueKind.undecryptable => HealthPriority.undecryptable,
    E2eeIssueKind.devices => HealthPriority.devices,
  };
  return HealthIssue(
    source: HealthSource.e2ee,
    priority: priority,
    title: issue.title,
    message: issue.message,
    actionLabel: issue.actionLabel,
    action: HealthAction.e2eeFix,
    severity: switch (issue.kind) {
      E2eeIssueKind.encryptionOff => HealthSeverity.danger,
      E2eeIssueKind.undecryptable ||
      E2eeIssueKind.devices => HealthSeverity.neutral,
      _ => HealthSeverity.warning,
    },
    signature: issue.signature,
    e2ee: issue,
  );
}

/// The network page of [network], where its problem is explained and fixed
/// (sign in, open the bridge chat).
String networkRoute(String network) =>
    '/rooms/settings/networks/${Uri.encodeComponent(network)}';

HealthIssue? bridgeHealthIssue(BridgeHealth health, DateTime now) {
  if (!health.state.isProblem) return null;
  // The user signed out on purpose: the network page says so, the inbox
  // does not nag.
  if (health.userInitiated) return null;
  final signIn = health.state == BridgeHealthState.loggedOut;
  return HealthIssue(
    source: HealthSource.bridge,
    priority: switch (health.state) {
      BridgeHealthState.loggedOut => HealthPriority.bridgeLoggedOut,
      BridgeHealthState.disconnected => HealthPriority.bridgeDisconnected,
      _ => HealthPriority.bridgeDegraded,
    },
    title: health.title,
    message: health.describe(now),
    // The network page, not the raw bot chat (BR-08): it explains the
    // problem and offers the one fix.
    actionLabel: signIn ? 'Sign in' : 'Details',
    action: HealthAction.openRoute,
    route: networkRoute(health.network),
    severity: health.state == BridgeHealthState.degraded
        ? HealthSeverity.warning
        : HealthSeverity.danger,
    signature: health.signature,
    roomId: health.managementRoomId,
    network: health.network,
    bridgeState: health.state,
  );
}

/// Push setup that does not work, from the Android registration phase.
/// "Retrying" and "registering" fix themselves and stay quiet.
HealthIssue? pushRegistrationIssue(PushRegistrationPhase? phase) {
  final (title, message) = switch (phase) {
    PushRegistrationPhase.permissionRequired => (
      'Notifications are off',
      'Allow notifications for ChatLoom, or new messages won’t alert you.',
    ),
    PushRegistrationPhase.tokenUnavailable => (
      'Notifications aren’t set up',
      'This device has no notification token. Retry notification setup.',
    ),
    PushRegistrationPhase.firebaseUnavailable => (
      'Notifications can’t work in this build',
      'This ChatLoom build has no push configuration. Install a build that '
          'includes it; your data stays.',
    ),
    PushRegistrationPhase.notAuthorized => (
      'Notifications aren’t set up',
      'The notification service rejected this account.',
    ),
    PushRegistrationPhase.failed => (
      'Notifications aren’t set up',
      'Setup couldn’t finish, so new messages may not alert you.',
    ),
    _ => (null, null),
  };
  if (title == null || message == null) return null;
  return HealthIssue(
    source: HealthSource.push,
    priority: HealthPriority.push,
    title: title,
    message: message,
    actionLabel: 'Fix',
    action: HealthAction.openRoute,
    // The diagnostics page shows which step fails and re-registers in one tap.
    route: '/rooms/settings/notifications/diagnostics',
    signature: 'push:${phase!.name}',
  );
}

const _pushFailures = {
  PushOutcome.storageUnavailable,
  PushOutcome.fetchFailed,
  PushOutcome.timeout,
  PushOutcome.error,
};

/// Delivered pushes that this device could not turn into notifications: the
/// newest three message wakes all failed, the latest within a day.
HealthIssue? pushDeliveryIssue(PushDiagnosticsSnapshot snapshot, DateTime now) {
  final messages = snapshot.recent
      .where((entry) => entry.kind == PushKind.message)
      .take(3)
      .toList();
  if (messages.length < 3) return null;
  if (!messages.every((entry) => _pushFailures.contains(entry.outcome))) {
    return null;
  }
  final newest = messages.first.at;
  if (now.difference(newest) > const Duration(days: 1)) return null;
  return HealthIssue(
    source: HealthSource.push,
    priority: HealthPriority.push,
    title: 'Notifications are failing',
    message:
        'Recent messages reached this phone but couldn’t be shown as '
        'notifications.',
    actionLabel: 'Diagnose',
    action: HealthAction.openRoute,
    route: '/rooms/settings/notifications/diagnostics',
    signature: 'push:delivery:${newest.millisecondsSinceEpoch ~/ 60000}',
  );
}

/// The background worker stopped sending heartbeats, or runs a version
/// older than this app expects. Silent when no worker was ever seen.
HealthIssue? workerIssue(WorkerReadiness? readiness, DateTime now) {
  if (readiness == null) return null;
  if (!readiness.freshAt(now)) {
    if (now.isBefore(readiness.receivedAt)) return null;
    return HealthIssue(
      source: HealthSource.worker,
      priority: HealthPriority.worker,
      title: 'Background worker is offline',
      message:
          'Transcriptions, reminders and scheduled messages wait until it’s '
          'back. Last heard from it '
          '${bridgeHealthAge(readiness.receivedAt, now).replaceFirst('for ', '')} '
          'ago.',
      actionLabel: 'Details',
      action: HealthAction.openRoute,
      route: '/rooms/settings/sync',
      severity: HealthSeverity.neutral,
      signature:
          'worker:stale:${readiness.receivedAt.millisecondsSinceEpoch ~/ 1000}',
    );
  }
  if (readiness.healthy == false) {
    return const HealthIssue(
      source: HealthSource.worker,
      priority: HealthPriority.worker,
      title: 'Background worker has a problem',
      message: 'It reports its Matrix connection as unhealthy.',
      actionLabel: 'Details',
      action: HealthAction.openRoute,
      route: '/rooms/settings/sync',
      severity: HealthSeverity.neutral,
      signature: 'worker:unhealthy',
    );
  }
  if (readiness.transcriptionMedia == null) {
    return const HealthIssue(
      source: HealthSource.worker,
      priority: HealthPriority.workerOutdated,
      title: 'Background worker needs an update',
      message: 'It runs an older version; video transcription isn’t available.',
      actionLabel: 'Details',
      action: HealthAction.openRoute,
      route: '/rooms/settings/sync',
      severity: HealthSeverity.neutral,
      signature: 'worker:outdated',
    );
  }
  return null;
}

/// Every issue in display order. While offline, bridge and worker signals
/// are stale (they arrive through the same sync) and are left out.
List<HealthIssue> combineHealthIssues({
  required ConnectionPhase connection,
  List<E2eeIssue> e2ee = const [],
  List<BridgeHealth> bridges = const [],
  PushRegistrationPhase? pushPhase,
  PushDiagnosticsSnapshot? pushDiagnostics,
  WorkerReadiness? worker,
  required DateTime now,
}) {
  final offline = connection.offline;
  final issues = <HealthIssue>[
    ?connectionIssue(connection),
    ...e2ee.map(e2eeHealthIssue),
    if (!offline)
      for (final bridge in bridges) ?bridgeHealthIssue(bridge, now),
    ?pushRegistrationIssue(pushPhase),
    if (pushDiagnostics != null) ?pushDeliveryIssue(pushDiagnostics, now),
    if (!offline) ?workerIssue(worker, now),
  ];
  // Stable: equal priorities keep their source order.
  final indexed = issues.indexed.toList()
    ..sort(
      (a, b) => a.$2.priority != b.$2.priority
          ? a.$2.priority.compareTo(b.$2.priority)
          : a.$1.compareTo(b.$1),
    );
  return [for (final (_, issue) in indexed) issue];
}

/// "Hidden until something changes" for the combined row. Stored issues
/// use the existing E2EE dismissal setting (account hash + signatures, no
/// ids); passing issues are remembered in memory only.
class HealthDismissal {
  HealthDismissal({required this.account, required String stored})
    : _stored = stored;

  final String account;
  String _stored;
  final _session = <String>{};

  String get stored => _stored;

  /// True when every current issue was dismissed. A new or changed issue
  /// shows the row again; a resolved one never does.
  bool covers(List<HealthIssue> issues) => visible(issues).isEmpty;

  /// The issues to show, in order. A new or changed lasting problem brings
  /// the row back with everything current except a passing problem hidden
  /// in this session; a passing one (the connection) shows alone, without
  /// the problems hidden before (they used to come back with it, as an
  /// unexplained "1 more", and vanish with it).
  List<HealthIssue> visible(List<HealthIssue> issues) {
    if (issues.isEmpty) return const [];
    // A passing problem that went away may come back later and show again.
    _session.retainAll(issues.map((issue) => issue.signature));
    final lines = _stored.isEmpty ? const <String>[] : _stored.split('\n');
    final stored = lines.isNotEmpty && lines.first == fnv1a(account)
        ? lines.skip(1).toSet()
        : const <String>{};
    bool hidden(HealthIssue issue) => issue.persistentDismissal
        ? stored.contains(issue.signature)
        : _session.contains(issue.signature);
    final changed = issues.any(
      (issue) => issue.persistentDismissal && !hidden(issue),
    );
    return [
      for (final issue in issues)
        if (!hidden(issue) || (changed && issue.persistentDismissal)) issue,
    ];
  }

  /// Dismisses [issues]; returns the new stored value.
  String dismiss(List<HealthIssue> issues) {
    for (final issue in issues) {
      if (!issue.persistentDismissal) _session.add(issue.signature);
    }
    final signatures =
        issues
            .where((issue) => issue.persistentDismissal)
            .map((issue) => issue.signature)
            .toSet()
            .toList()
          ..sort();
    _stored = [fnv1a(account), ...signatures].join('\n');
    return _stored;
  }
}
