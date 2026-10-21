// SPDX-License-Identifier: AGPL-3.0-or-later
// Inbox encryption health: issue priority, one-tap fixes and dismissal.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat_list/inbox_health_status.dart';
import 'package:chatloom/personal/diagnostics.dart';
import 'package:chatloom/personal/encryption/e2ee_health.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _UnusedDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<String> _kinds(E2eeSnapshot snapshot) => e2eeIssues(
  snapshot,
  includePrivateSync: true,
).map((i) => i.signature).toList();

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  test('a healthy device has no issues', () {
    expect(_kinds(const E2eeSnapshot()), isEmpty);
    expect(recoveryFixFor(const E2eeSnapshot()), isNull);
  });

  test('issues come in priority order with their fixes', () {
    final issues = e2eeIssues(
      const E2eeSnapshot(
        backupConnected: false,
        sessionVerified: false,
        crossSigningConnected: false,
        undecryptableChats: 3,
        unverifiedDevices: ['DEVICEB'],
        privateSync: PrivateSyncFailure.journalUnavailable,
      ),
      includePrivateSync: true,
    );
    expect(issues.map((i) => i.kind), [
      E2eeIssueKind.recovery,
      E2eeIssueKind.privateSync,
      E2eeIssueKind.undecryptable,
    ]);
    expect(issues.first.fix, E2eeFix.connectRecovery);
    expect(issues.first.message, contains('verify this session'));
    expect(issues[1].fix, E2eeFix.retryPrivateSync);
    expect(issues[2].title, '3 chats have messages that couldn’t be decrypted');
  });

  test('a missing backup opens settings, never the setup flow directly', () {
    const snapshot = E2eeSnapshot(backupEnabled: false, backupConnected: false);
    expect(e2eeIssues(snapshot).single.fix, E2eeFix.openRecoverySettings);
    expect(recoveryFixFor(snapshot), E2eeFix.openRecoverySettings);
    expect(
      e2eeFixRoute(E2eeFix.openRecoverySettings),
      '/rooms/settings/recovery',
    );
    expect(e2eeFixRoute(E2eeFix.connectRecovery), '/backup');
  });

  test('a connected but unsigned session verifies from another device', () {
    const snapshot = E2eeSnapshot(sessionVerified: false);
    final issue = e2eeIssues(snapshot).single;
    expect(issue.kind, E2eeIssueKind.session);
    expect(issue.fix, E2eeFix.openDevices);
    expect(
      recoveryFixFor(
        const E2eeSnapshot(
          sessionVerified: false,
          crossSigningConnected: false,
        ),
      ),
      E2eeFix.connectRecovery,
    );
  });

  test('other sessions count only once this session is verified', () {
    expect(
      _kinds(const E2eeSnapshot(unverifiedDevices: ['DEVICEB', 'DEVICEC'])),
      [startsWith('devices:')],
    );
    expect(
      _kinds(
        const E2eeSnapshot(
          sessionVerified: false,
          unverifiedDevices: ['DEVICEB'],
        ),
      ),
      ['session:unverified'],
    );
  });

  test('offline private sync is left to the connection notice', () {
    expect(
      _kinds(const E2eeSnapshot(privateSync: PrivateSyncFailure.offline)),
      isEmpty,
    );
    expect(
      e2eeIssues(
        const E2eeSnapshot(privateSync: PrivateSyncFailure.journalMissing),
        includePrivateSync: true,
      ).single.fix,
      E2eeFix.openPrivateSync,
    );
    expect(
      e2eeIssues(
        const E2eeSnapshot(privateSync: PrivateSyncFailure.journalMissing),
        includePrivateSync: false,
      ),
      isEmpty,
    );
  });

  test('encryption off is reported first and alone', () {
    expect(
      _kinds(
        const E2eeSnapshot(
          encryptionAvailable: false,
          undecryptableChats: 2,
          unverifiedDevices: ['DEVICEB'],
        ),
      ),
      ['encryption:off'],
    );
  });

  test('dismissal holds until a new or changed issue appears', () {
    final before = e2eeIssues(
      const E2eeSnapshot(backupConnected: false, undecryptableChats: 2),
    );
    final stored = E2eeNoticeDismissal.encode('@me:example.invalid', before);
    expect(stored, isNot(contains('@me')));
    expect(
      E2eeNoticeDismissal.covers(stored, '@me:example.invalid', before),
      isTrue,
    );
    // Resolving one issue keeps the rest hidden.
    final fewer = e2eeIssues(const E2eeSnapshot(undecryptableChats: 5));
    expect(
      E2eeNoticeDismissal.covers(stored, '@me:example.invalid', fewer),
      isTrue,
    );
    // A new device set is a new issue.
    final devicesA = e2eeIssues(
      const E2eeSnapshot(unverifiedDevices: ['DEVICEB']),
    );
    final devicesB = e2eeIssues(
      const E2eeSnapshot(unverifiedDevices: ['DEVICEB', 'DEVICEC']),
    );
    final storedDevices = E2eeNoticeDismissal.encode('@me:x', devicesA);
    expect(
      E2eeNoticeDismissal.covers(storedDevices, '@me:x', devicesA),
      isTrue,
    );
    expect(
      E2eeNoticeDismissal.covers(storedDevices, '@me:x', devicesB),
      isFalse,
    );
    // Another account never inherits a dismissal.
    expect(E2eeNoticeDismissal.covers(stored, '@other:x', before), isFalse);
    expect(E2eeNoticeDismissal.covers('', '@me:x', before), isFalse);
  });

  test('fnv1a is stable', () {
    expect(fnv1a(''), '811c9dc5');
    expect(fnv1a('a'), 'e40c292c');
  });

  testWidgets('inbox row shows the top issue, more, and stays dismissed', (
    tester,
  ) async {
    final client = Client('e2ee health test', database: _UnusedDatabase());
    var snapshot = const E2eeSnapshot(
      backupConnected: false,
      undecryptableChats: 2,
    );
    Widget app() => MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      home: Scaffold(
        body: InboxHealthStatus(client: client, load: () async => snapshot),
      ),
    );
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Connect this device to key backup'), findsOneWidget);
    expect(find.text('Connect'), findsOneWidget);
    expect(find.text('1 more'), findsOneWidget);

    await tester.tap(find.byTooltip('Hide until something changes'));
    await tester.pumpAndSettle();
    expect(find.byType(NotionCallout), findsNothing);
    expect(AppSettings.personalE2eeNoticeDismissed.value, isNotEmpty);

    // Same issues after a restart: still hidden.
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.byType(NotionCallout), findsNothing);

    // A new issue brings the row back with everything current.
    snapshot = const E2eeSnapshot(
      backupConnected: false,
      undecryptableChats: 2,
      unverifiedDevices: ['DEVICEB'],
    );
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(app());
    await tester.pumpAndSettle();
    expect(find.text('Connect this device to key backup'), findsOneWidget);
    expect(find.text('2 more'), findsOneWidget);

    // "2 more" lists every issue with its own fix.
    await tester.tap(find.text('2 more'));
    await tester.pumpAndSettle();
    expect(find.text('What needs attention'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(find.text('Review'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });
}
