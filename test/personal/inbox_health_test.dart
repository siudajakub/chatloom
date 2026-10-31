// SPDX-License-Identifier: AGPL-3.0-or-later
// The combined inbox status row (connection, bridges, push, worker, E2EE),
// the Telegram-style header status and the per-chat bridge banner.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat_list/inbox_health_status.dart';
import 'package:chatloom/personal/bridge_health.dart';
import 'package:chatloom/personal/bridge_health_monitor.dart';
import 'package:chatloom/personal/connection_status.dart';
import 'package:chatloom/personal/encryption/e2ee_health.dart';
import 'package:chatloom/personal/inbox_health.dart';
import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/personal/push_registration.dart';
import 'package:chatloom/personal/ui/health_status_widgets.dart';
import 'package:chatloom/personal/worker_readiness.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final _now = DateTime.utc(2026, 10, 20, 12);

BridgeHealth _bridge(
  BridgeHealthState state, {
  String network = 'whatsapp',
  String stamp = '1',
  String? room = '!management:example.invalid',
}) {
  final signals = BridgeSignals();
  final event = switch (state) {
    BridgeHealthState.loggedOut => 'BAD_CREDENTIALS',
    BridgeHealthState.disconnected => 'UNKNOWN_ERROR',
    _ => 'CONNECTING',
  };
  signals.addReport(
    BridgeStateReport(
      network: network,
      stateEvent: event,
      at: _now.subtract(const Duration(hours: 1)),
      error: stamp,
      roomId: room,
    ),
  );
  return evaluateBridgeHealth(network, signals, _now);
}

/// A bridge monitor whose verdicts the test sets.
class _FakeBridges extends BridgeHealthMonitor {
  _FakeBridges(super.client, this.room);

  final Room? room;
  List<BridgeHealth> fake = const [];

  void set(List<BridgeHealth> value) {
    fake = value;
    notifyListeners();
  }

  @override
  List<BridgeHealth> get problems => fake;

  @override
  BridgeHealth? problemFor(Room room) => fake.firstOrNull;

  @override
  Room? managementRoom(String network) => room;
}

ConnectionStatusMonitor _connection(
  StreamController<SyncStatusUpdate> statuses, {
  bool network = true,
}) => ConnectionStatusMonitor(
  statuses: () => statuses.stream,
  current: () => null,
  firstSync: () => false,
  hasNetwork: () async => network,
  offlineGrace: Duration.zero,
  updatingGrace: Duration.zero,
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('combineHealthIssues', () {
    final undecryptable = e2eeIssues(
      const E2eeSnapshot(undecryptableChats: 1),
      includePrivateSync: true,
    );

    test('orders by what loses messages first', () {
      final issues = combineHealthIssues(
        connection: ConnectionPhase.online,
        e2ee: undecryptable,
        bridges: [
          _bridge(BridgeHealthState.degraded, network: 'slack'),
          _bridge(BridgeHealthState.loggedOut),
        ],
        pushPhase: PushRegistrationPhase.permissionRequired,
        worker: WorkerReadiness(
          receivedAt: _now.subtract(const Duration(hours: 2)),
          transcriptionMedia: 2,
        ),
        now: _now,
      );
      expect(issues.map((i) => i.title), [
        'WhatsApp is signed out',
        'Notifications are off',
        'Slack is reconnecting',
        'Background worker is offline',
        '1 chat has a message that couldn’t be decrypted',
      ]);
      // The network page, not the raw bot chat (BR-08).
      expect(issues.first.action, HealthAction.openRoute);
      expect(issues.first.route, '/rooms/settings/networks/whatsapp');
      expect(issues.first.actionLabel, 'Sign in');
      expect(issues[3].message, contains('2 h ago'));
    });

    test('a sign-out the user made here never nags in the inbox', () {
      final signals = BridgeSignals()
        ..signedOutAt = _now.subtract(const Duration(minutes: 1));
      final health = evaluateBridgeHealth('whatsapp', signals, _now);
      expect(health.state, BridgeHealthState.loggedOut);
      expect(health.userInitiated, isTrue);
      expect(bridgeHealthIssue(health, _now), isNull);
    });

    test('while offline only the connection and local problems show', () {
      final issues = combineHealthIssues(
        connection: ConnectionPhase.waitingForNetwork,
        e2ee: undecryptable,
        bridges: [_bridge(BridgeHealthState.disconnected)],
        worker: WorkerReadiness(
          receivedAt: _now.subtract(const Duration(hours: 2)),
        ),
        now: _now,
      );
      expect(issues.map((i) => i.source), [
        HealthSource.connection,
        HealthSource.e2ee,
      ]);
      expect(issues.first.title, 'No internet connection');
      expect(
        combineHealthIssues(connection: ConnectionPhase.updating, now: _now),
        isEmpty,
      );
    });

    test('push: setup phases and repeated delivery failures', () {
      expect(pushRegistrationIssue(PushRegistrationPhase.retrying), isNull);
      expect(
        pushRegistrationIssue(PushRegistrationPhase.automaticallyConfigured),
        isNull,
      );
      expect(
        pushRegistrationIssue(PushRegistrationPhase.failed)?.route,
        '/rooms/settings/notifications/diagnostics',
      );
      final noFirebase = pushRegistrationIssue(
        PushRegistrationPhase.firebaseUnavailable,
      );
      expect(noFirebase?.title, 'Notifications can’t work in this build');
      expect(noFirebase?.route, '/rooms/settings/notifications/diagnostics');
      PushDiagnosticsEntry entry(PushOutcome outcome, int minutes) =>
          PushDiagnosticsEntry(
            at: _now.subtract(Duration(minutes: minutes)),
            kind: PushKind.message,
            outcome: outcome,
          );
      final failing = PushDiagnosticsSnapshot(
        recent: [
          entry(PushOutcome.timeout, 1),
          entry(PushOutcome.fetchFailed, 5),
          entry(PushOutcome.error, 9),
        ],
      );
      expect(
        pushDeliveryIssue(failing, _now)?.title,
        'Notifications are failing',
      );
      final recovered = PushDiagnosticsSnapshot(
        recent: [entry(PushOutcome.shown, 0), ...failing.recent],
      );
      expect(pushDeliveryIssue(recovered, _now), isNull);
      expect(
        pushDeliveryIssue(failing, _now.add(const Duration(days: 2))),
        isNull,
      );
    });

    test('worker: never seen is quiet; stale, unhealthy and old versions', () {
      expect(workerIssue(null, _now), isNull);
      expect(
        workerIssue(
          WorkerReadiness(
            receivedAt: _now,
            healthy: true,
            transcriptionMedia: 2,
          ),
          _now,
        ),
        isNull,
      );
      expect(
        workerIssue(
          WorkerReadiness(receivedAt: _now, healthy: false),
          _now,
        )?.signature,
        'worker:unhealthy',
      );
      expect(
        workerIssue(WorkerReadiness(receivedAt: _now), _now)?.signature,
        'worker:outdated',
      );
    });

    test('dismissal: stored problems stay hidden, passing ones only once', () {
      final dismissal = HealthDismissal(account: '@me:x', stored: '');
      final bridge = bridgeHealthIssue(
        _bridge(BridgeHealthState.loggedOut),
        _now,
      )!;
      final offline = connectionIssue(ConnectionPhase.connecting)!;
      expect(dismissal.covers([offline, bridge]), isFalse);
      final stored = dismissal.dismiss([offline, bridge]);
      expect(dismissal.covers([offline, bridge]), isTrue);
      expect(stored, isNot(contains('connection')));
      // Offline ends, then comes back: it shows again.
      expect(dismissal.covers([bridge]), isTrue);
      expect(dismissal.covers([offline, bridge]), isFalse);
      // After a restart the bridge problem stays hidden...
      final restarted = HealthDismissal(account: '@me:x', stored: stored);
      expect(restarted.covers([bridge]), isTrue);
      // ...until it changes, and never for another account.
      final changed = bridgeHealthIssue(
        _bridge(BridgeHealthState.loggedOut, stamp: '2'),
        _now,
      )!;
      expect(restarted.covers([changed]), isFalse);
      expect(
        HealthDismissal(account: '@other:x', stored: stored).covers([bridge]),
        isFalse,
      );
    });

    test('a passing problem shows alone, without the hidden ones', () {
      final dismissal = HealthDismissal(account: '@me:x', stored: '');
      final bridge = bridgeHealthIssue(
        _bridge(BridgeHealthState.loggedOut),
        _now,
      )!;
      final offline = connectionIssue(ConnectionPhase.waitingForNetwork)!;
      dismissal.dismiss([bridge]);
      // A lasting connection problem: just that row, no "1 more".
      expect(dismissal.visible([offline, bridge]), [offline]);
      // It ends: the hidden problem stays hidden.
      expect(dismissal.visible([bridge]), isEmpty);
      // A changed lasting problem brings everything current back.
      final changed = bridgeHealthIssue(
        _bridge(BridgeHealthState.loggedOut, stamp: '2'),
        _now,
      )!;
      expect(dismissal.visible([offline, changed]), [offline, changed]);
    });

    test('a hidden passing problem stays hidden when another one shows', () {
      final dismissal = HealthDismissal(account: '@me:x', stored: '');
      final offline = connectionIssue(ConnectionPhase.connecting)!;
      final bridge = bridgeHealthIssue(
        _bridge(BridgeHealthState.loggedOut),
        _now,
      )!;
      // Only the compact connection row was hidden: a problem it did not
      // show still shows, without the connection coming back with it.
      dismissal.dismiss([offline]);
      expect(dismissal.visible([offline, bridge]), [bridge]);
      dismissal.dismiss([bridge]);
      expect(dismissal.visible([offline, bridge]), isEmpty);
      // A changed lasting problem brings the lasting ones back, still
      // without the passing one hidden in this session.
      final changed = bridgeHealthIssue(
        _bridge(BridgeHealthState.loggedOut, stamp: '2'),
        _now,
      )!;
      expect(dismissal.visible([offline, changed]), [changed]);
      // Once the connection problem ends, its dismissal ends with it.
      expect(dismissal.visible([changed]), [changed]);
      expect(dismissal.visible([offline, changed]), [offline, changed]);
    });

    test('existing E2EE dismissals keep working', () {
      final issues = e2eeIssues(
        const E2eeSnapshot(backupConnected: false),
        includePrivateSync: true,
      );
      final stored = E2eeNoticeDismissal.encode('@me:x', issues);
      expect(
        HealthDismissal(
          account: '@me:x',
          stored: stored,
        ).covers(issues.map(e2eeHealthIssue).toList()),
        isTrue,
      );
    });
  });

  testWidgets('inbox row: offline first, bridge next, real actions, dismiss', (
    tester,
  ) async {
    final client = Client('inbox health test', database: _UnusedDatabase());
    final management = Room(
      id: '!management:example.invalid',
      client: client,
      membership: Membership.join,
    );
    final statuses = StreamController<SyncStatusUpdate>.broadcast();
    addTearDown(statuses.close);
    final connection = _connection(statuses, network: false);
    final bridges = _FakeBridges(client, management)
      ..fake = [_bridge(BridgeHealthState.loggedOut)];
    final pushChanges = ValueNotifier(0);
    var retries = 0;
    final router = GoRouter(
      routes: [
        GoRoute(
          path: '/',
          builder: (context, _) => Scaffold(
            body: InboxHealthStatus(
              client: client,
              load: () async => const E2eeSnapshot(undecryptableChats: 1),
              connection: connection,
              bridges: bridges,
              push: PushHealthSource(
                phase: () => PushRegistrationPhase.permissionRequired,
                changes: pushChanges,
              ),
              pushDiagnostics: () async => PushDiagnosticsSnapshot.empty,
              worker: () => null,
              clock: () => _now,
              retrySync: (_) async => retries++,
            ),
          ),
        ),
        GoRoute(
          path: '/rooms/:roomid',
          builder: (context, state) =>
              const Scaffold(body: Text('Bridge chat')),
        ),
        GoRoute(
          path: '/rooms/settings/networks/:network',
          builder: (context, state) => Scaffold(
            body: Text('Network page ${state.pathParameters['network']}'),
          ),
        ),
      ],
    );
    addTearDown(router.dispose);
    await tester.pumpWidget(
      MaterialApp.router(
        theme: NotionTheme.build(Brightness.dark),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp is signed out'), findsOneWidget);
    expect(find.text('Sign in'), findsOneWidget);
    expect(find.text('2 more'), findsOneWidget);

    // A passing connection problem is the header line's alone.
    statuses
      ..add(const SyncStatusUpdate(SyncStatus.error))
      ..add(const SyncStatusUpdate(SyncStatus.error));
    await tester.pumpAndSettle();
    expect(connection.value, ConnectionPhase.waitingForNetwork);
    expect(find.text('No internet connection'), findsNothing);
    expect(find.text('WhatsApp is signed out'), findsOneWidget);
    // A lasting one outranks everything as one compact row without "N more"
    // and hides the (stale) bridge problem.
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(find.text('No internet connection'), findsOneWidget);
    expect(find.text('Showing loaded chats'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('2 more'), findsNothing);
    expect(
      tester.widget<NotionCallout>(find.byType(NotionCallout)).compact,
      isTrue,
    );
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(retries, 1, reason: 'Retry syncs at once');
    // Hiding the compact row hides only the connection problem: the ones
    // it did not show are not hidden with it.
    await tester.tap(find.byTooltip('Hide until something changes'));
    await tester.pumpAndSettle();
    expect(find.text('No internet connection'), findsNothing);
    expect(find.text('Notifications are off'), findsOneWidget);
    expect(
      tester.widget<NotionCallout>(find.byType(NotionCallout)).compact,
      isFalse,
    );
    statuses.add(const SyncStatusUpdate(SyncStatus.finished));
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp is signed out'), findsOneWidget);
    expect(
      tester.widget<NotionCallout>(find.byType(NotionCallout)).compact,
      isFalse,
    );

    // "2 more" lists everything with its own fix.
    await tester.tap(find.text('2 more'));
    await tester.pumpAndSettle();
    expect(find.text('What needs attention'), findsOneWidget);
    expect(find.text('Notifications are off'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10));
    await tester.pumpAndSettle();

    // The bridge action opens the network page (sign in there).
    await tester.tap(find.text('Sign in'));
    await tester.pumpAndSettle();
    expect(find.text('Network page whatsapp'), findsOneWidget);
    router.pop();
    await tester.pumpAndSettle();

    // Hidden until something changes.
    await tester.tap(find.byTooltip('Hide until something changes'));
    await tester.pumpAndSettle();
    expect(find.byType(NotionCallout), findsNothing);
    expect(AppSettings.personalE2eeNoticeDismissed.value, isNotEmpty);
    bridges.set([_bridge(BridgeHealthState.loggedOut, stamp: 'new')]);
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp is signed out'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    pushChanges.dispose();
  });

  testWidgets('header status lines show the debounced connection status', (
    tester,
  ) async {
    final client = Client('header status test', database: _UnusedDatabase());
    final statuses = StreamController<SyncStatusUpdate>.broadcast();
    addTearDown(statuses.close);
    final connection = _connection(statuses);
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: NotionCompactChatHeader(
            avatar: const SizedBox.square(dimension: 32),
            name: 'Synthetic chat',
            onDetails: null,
            status: ConnectionStatusLine(
              client: client,
              monitor: connection,
              retry: (_) async => retries++,
            ),
          ),
        ),
      ),
    );
    expect(find.text('Connecting…'), findsNothing);
    final idle = tester.getSize(find.byType(NotionCompactChatHeader));
    Future<void> settle() async {
      // The spinner loops; step through the reveal instead of settling.
      await tester.pump();
      await tester.pump(NotionMotion.medium);
      await tester.pump(NotionMotion.medium);
    }

    // One failed request says nothing.
    statuses.add(const SyncStatusUpdate(SyncStatus.error));
    await settle();
    expect(find.text('Connecting…'), findsNothing);
    statuses.add(const SyncStatusUpdate(SyncStatus.error));
    await settle();
    expect(find.text('Connecting…'), findsOneWidget);
    expect(find.byType(NotionDelayedSpinner), findsOneWidget);
    // A tap on the problem syncs at once.
    await tester.tap(find.text('Connecting…'));
    expect(retries, 1);
    statuses.add(const SyncStatusUpdate(SyncStatus.processing));
    await settle();
    expect(find.text('Updating…'), findsOneWidget);
    expect(find.byType(NotionDelayedSpinner), findsOneWidget);
    // Updating is no problem to retry.
    await tester.tap(find.text('Updating…'), warnIfMissed: false);
    expect(retries, 1);
    statuses.add(const SyncStatusUpdate(SyncStatus.finished));
    await settle();
    await tester.pumpAndSettle();
    expect(find.text('Updating…'), findsNothing);
    // The header keeps its height (48 pt minimum) with or without status.
    expect(tester.getSize(find.byType(NotionCompactChatHeader)), idle);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('chat banner names the broken bridge and can be hidden', (
    tester,
  ) async {
    final client = Client('chat banner test', database: _UnusedDatabase());
    final room = Room(
      id: '!portal:example.invalid',
      client: client,
      membership: Membership.join,
    );
    final bridges = _FakeBridges(client, null);
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: Stack(
            children: [
              const SizedBox.expand(),
              ChatBridgeNotice(room: room, monitor: bridges),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(NotionCallout), findsNothing);

    bridges.set([_bridge(BridgeHealthState.disconnected)]);
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp is disconnected'), findsOneWidget);
    expect(
      find.text('Messages won’t be delivered until it reconnects.'),
      findsOneWidget,
    );
    // The action opens the network page, known room or not (BR-08).
    expect(find.text('Open bridge'), findsNothing);
    expect(find.text('Details'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide until something changes'));
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp is disconnected'), findsNothing);

    // A different problem shows again; recovery removes it.
    bridges.set([_bridge(BridgeHealthState.loggedOut)]);
    await tester.pumpAndSettle();
    expect(find.text('WhatsApp is signed out'), findsOneWidget);
    bridges.set(const []);
    await tester.pumpAndSettle();
    expect(find.byType(NotionCallout), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });
}
