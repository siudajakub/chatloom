// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/bridge_health.dart';
import 'package:chatloom/personal/bridge_health_monitor.dart';
import 'package:chatloom/personal/connection_status.dart';
import 'package:chatloom/personal/encryption/e2ee_health.dart';
import 'package:chatloom/personal/inbox_health.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/personal/push_registration.dart';
import 'package:chatloom/personal/ui/health_status_widgets.dart';
import 'package:chatloom/personal/ui/inbox_health_notice.dart';
import 'package:chatloom/personal/worker_readiness.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/utils/background_push.dart';
import 'package:chatloom/utils/sync_network_recovery.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

/// Where the inbox reads the push setup phase (Android only).
class PushHealthSource {
  const PushHealthSource({required this.phase, required this.changes});

  final PushRegistrationPhase? Function() phase;
  final Listenable changes;

  static PushHealthSource? of(BuildContext context, Client client) {
    BackgroundPush? push;
    try {
      push = Matrix.of(context).backgroundPush;
    } catch (_) {
      push = null;
    }
    if (push == null) return null;
    final instance = push;
    return PushHealthSource(
      phase: () => instance.registrationPhase(client),
      changes: instance.registrationChanges,
    );
  }
}

/// The inbox's single status row: connection, encryption and private sync,
/// bridges, notifications and the background worker, most important first.
/// Replaces the red snackbar and the separate offline notice: it stays until
/// fixed or dismissed, and a dismissal lasts until the problems change.
class InboxHealthStatus extends StatefulWidget {
  final Client client;

  /// Test seams: sources instead of the live client state.
  final Future<E2eeSnapshot> Function()? load;
  final ConnectionStatusMonitor? connection;
  final BridgeHealthMonitor? bridges;
  final PushHealthSource? push;
  final Future<PushDiagnosticsSnapshot> Function()? pushDiagnostics;
  final WorkerReadiness? Function()? worker;
  final DateTime Function()? clock;
  final Future<void> Function(Client client)? retrySync;

  const InboxHealthStatus({
    super.key,
    required this.client,
    this.load,
    this.connection,
    this.bridges,
    this.push,
    this.pushDiagnostics,
    this.worker,
    this.clock,
    this.retrySync,
  });

  static InboxHealthItem itemFor(E2eeIssue issue) => InboxHealthItem(
    icon: switch (issue.kind) {
      E2eeIssueKind.encryptionOff => Icons.lock_open_outlined,
      E2eeIssueKind.recovery => Icons.key_outlined,
      E2eeIssueKind.session => Icons.gpp_maybe_outlined,
      E2eeIssueKind.privateSync => Icons.sync_problem_outlined,
      E2eeIssueKind.undecryptable => Icons.lock_clock_outlined,
      E2eeIssueKind.devices => Icons.devices_other_outlined,
    },
    tone: switch (issue.kind) {
      E2eeIssueKind.encryptionOff => NotionCalloutTone.danger,
      E2eeIssueKind.undecryptable ||
      E2eeIssueKind.devices => NotionCalloutTone.neutral,
      _ => NotionCalloutTone.warning,
    },
    title: issue.title,
    message: issue.message,
    actionLabel: issue.actionLabel,
  );

  /// The row's presentation of any [issue].
  static InboxHealthItem itemForIssue(HealthIssue issue) {
    final e2ee = issue.e2ee;
    if (e2ee != null) return itemFor(e2ee);
    return InboxHealthItem(
      icon: switch (issue.source) {
        HealthSource.connection =>
          issue.signature == 'connection:network'
              ? Icons.cloud_off_outlined
              : Icons.sync_problem_outlined,
        HealthSource.bridge => bridgeHealthIcon(
          issue.bridgeState ?? BridgeHealthState.degraded,
        ),
        HealthSource.push => Icons.notifications_off_outlined,
        HealthSource.worker => Icons.dns_outlined,
        HealthSource.e2ee => Icons.lock_outline,
      },
      tone: switch (issue.severity) {
        HealthSeverity.neutral => NotionCalloutTone.neutral,
        HealthSeverity.warning => NotionCalloutTone.warning,
        HealthSeverity.danger => NotionCalloutTone.danger,
      },
      title: issue.title,
      message: issue.message,
      actionLabel: issue.actionLabel,
      compact: issue.source == HealthSource.connection,
    );
  }

  @override
  State<InboxHealthStatus> createState() => _InboxHealthStatusState();
}

class _InboxHealthStatusState extends State<InboxHealthStatus> {
  late E2eeHealthController _health;
  late ConnectionStatusMonitor _connection;
  late BridgeHealthMonitor _bridges;
  late HealthDismissal _dismissal;
  late Listenable _listenable;
  late final AppLifecycleListener _lifecycle;
  PushHealthSource? _push;
  StreamSubscription<SyncUpdate>? _sync;
  PushDiagnosticsSnapshot? _pushDiagnostics;
  String? _workerSignature;
  bool _retrying = false;
  bool _pushBound = false;

  /// Problems shown last, kept while the notice collapses after a fix or a
  /// dismissal.
  List<HealthIssue> _shown = const [];

  DateTime _now() => (widget.clock ?? DateTime.now)();

  WorkerReadiness? _worker() {
    final source = widget.worker;
    if (source != null) return source();
    final personal = PersonalClient.of(widget.client);
    return personal.ready ? personal.workerReadiness : null;
  }

  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(onResume: _readPushDiagnostics);
    _bind();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_pushBound) return;
    _pushBound = true;
    _push = widget.push ?? PushHealthSource.of(context, widget.client);
    _push?.changes.addListener(_onPushChanged);
    _readPushDiagnostics();
  }

  void _bind() {
    _health = E2eeHealthController(widget.client, load: widget.load)..start();
    _connection =
        widget.connection ?? ConnectionStatusMonitor.of(widget.client);
    _bridges = widget.bridges ?? BridgeHealthMonitor.of(widget.client);
    _listenable = Listenable.merge([
      _health,
      _connection,
      _bridges,
      PersonalClient.of(widget.client),
    ]);
    _dismissal = HealthDismissal(
      account: widget.client.userID ?? widget.client.clientName,
      stored: AppSettings.personalE2eeNoticeDismissed.value,
    );
    _workerSignature = workerIssue(_worker(), _now())?.signature;
    // A heartbeat goes stale without any event: re-check it on each sync.
    _sync = widget.client.onSync.stream.listen((_) {
      final signature = workerIssue(_worker(), _now())?.signature;
      if (signature == _workerSignature || !mounted) return;
      setState(() => _workerSignature = signature);
    }, onError: (Object _) {});
  }

  void _unbind() {
    _health.dispose();
    unawaited(_sync?.cancel());
  }

  @override
  void didUpdateWidget(InboxHealthStatus oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.client, widget.client)) {
      _unbind();
      _bind();
    }
  }

  @override
  void dispose() {
    _unbind();
    _push?.changes.removeListener(_onPushChanged);
    _lifecycle.dispose();
    super.dispose();
  }

  void _onPushChanged() {
    if (mounted) setState(() {});
  }

  void _readPushDiagnostics() {
    final read = widget.pushDiagnostics;
    if (read == null && _push == null) return;
    unawaited(
      (read ?? PushDiagnostics.read)().then((snapshot) {
        if (mounted) setState(() => _pushDiagnostics = snapshot);
      }, onError: (Object _) {}),
    );
  }

  List<HealthIssue> _issues() => combineHealthIssues(
    // A passing connection problem is the header line's alone; only a
    // lasting one earns the notice (and hides the stale bridge and worker
    // signals).
    connection: _connection.lasting
        ? _connection.value
        : ConnectionPhase.online,
    e2ee: _health.issues,
    bridges: _bridges.problems,
    pushPhase: _push?.phase(),
    pushDiagnostics: _pushDiagnostics,
    worker: _worker(),
    now: _now(),
  );

  int? _busyIndex(List<HealthIssue> issues) {
    if (_retrying) {
      final index = issues.indexWhere(
        (issue) => issue.action == HealthAction.retrySync,
      );
      if (index >= 0) return index;
    }
    final busy = _health.busy;
    if (busy == null) return null;
    final index = issues.indexWhere((issue) => issue.e2ee?.fix == busy);
    return index < 0 ? null : index;
  }

  Future<void> _fix(HealthIssue issue, {BuildContext? sheet}) async {
    void closeSheet() {
      if (sheet != null && sheet.mounted) Navigator.of(sheet).pop();
    }

    switch (issue.action) {
      case HealthAction.retrySync:
        if (_retrying) return;
        setState(() => _retrying = true);
        try {
          // Drops a long-poll stuck on a dead socket instead of joining it.
          await (widget.retrySync ?? syncNow)(widget.client);
        } catch (error) {
          Logs().w('[Personal] Sync retry failed: ${error.runtimeType}');
        } finally {
          if (mounted) setState(() => _retrying = false);
        }
      case HealthAction.openBridgeChat:
        final network = issue.network;
        final room = network == null ? null : _bridges.managementRoom(network);
        if (room == null) {
          if (sheet == null) _details();
          return;
        }
        closeSheet();
        await GoRouter.of(context).push('/rooms/${room.id}');
      case HealthAction.openRoute:
        closeSheet();
        await GoRouter.of(context).push(issue.route!);
        if (mounted) setState(() {});
      case HealthAction.details:
        if (sheet == null) _details();
      case HealthAction.e2eeFix:
        final e2ee = issue.e2ee!;
        // Screens open from the inbox, not from under the sheet.
        if (e2eeFixRoute(e2ee.fix) != null) closeSheet();
        await _health.fix(context, e2ee);
    }
  }

  void _details() {
    unawaited(
      showNotionSheet<void>(
        context: context,
        title: 'What needs attention',
        builder: (sheetContext) => ListenableBuilder(
          listenable: _listenable,
          builder: (sheetContext, _) {
            final issues = _issues();
            return InboxHealthDetails(
              items: issues.map(InboxHealthStatus.itemForIssue).toList(),
              busy: _busyIndex(issues),
              onFix: (index) {
                if (index < issues.length) {
                  unawaited(_fix(issues[index], sheet: sheetContext));
                }
              },
            );
          },
        ),
      ),
    );
  }

  Future<void> _dismiss(List<HealthIssue> issues) async {
    final stored = _dismissal.dismiss(issues);
    setState(() {});
    await AppSettings.personalE2eeNoticeDismissed.setItem(stored);
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _listenable,
    builder: (context, _) {
      final all = _issues();
      final issues = _dismissal.visible(all);
      if (issues.isNotEmpty) _shown = issues;
      final shown = _shown;
      if (shown.isEmpty) return const SizedBox.shrink();
      final items = shown.map(InboxHealthStatus.itemForIssue).toList();
      // Grows in when a problem appears, shrinks away when it is fixed or
      // hidden; a different top problem cross-fades in place.
      return NotionSizeReveal(
        visible: issues.isNotEmpty,
        revealOnMount: true,
        child: Padding(
          padding: const EdgeInsets.only(top: NotionSpace.xs),
          child: NotionFadeThrough(
            child: SizedBox(
              key: ValueKey((items.first.title, items.length)),
              width: double.infinity,
              child: InboxHealthNotice(
                items: items,
                busy: _busyIndex(shown),
                onFix: (index) {
                  final current = _issues();
                  if (index < current.length) {
                    unawaited(_fix(current[index]));
                  }
                },
                // A compact (connection) row shows only itself, so its
                // dismiss hides only itself: problems the user has not seen
                // are never hidden with it.
                onDismiss: () => unawaited(
                  _dismiss(items.first.compact ? [shown.first] : all),
                ),
                onDetails: _details,
              ),
            ),
          ),
        ),
      );
    },
  );
}
