// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/encryption/recovery_settings.dart';
import 'package:chatloom/personal/encryption/recovery_unlock.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

// No L10n: these surfaces use plain English and Material localizations only.
Widget _app(Widget home) =>
    MaterialApp(theme: NotionTheme.build(Brightness.dark), home: home);

Future<LogoutChoice?> _logout(
  WidgetTester tester,
  LogoutRecovery recovery, {
  required String tap,
}) async {
  LogoutChoice? choice;
  await tester.pumpWidget(
    _app(
      Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async =>
                choice = await showLogoutConfirmDialog(context, recovery),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
  await tester.tap(find.text(tap));
  await tester.pumpAndSettle();
  return choice;
}

void main() {
  test('status combines connected and initialized', () {
    expect(recoveryStatusOf(), RecoveryStatus.unknown);
    expect(recoveryStatusOf(connected: true), RecoveryStatus.connected);
    expect(
      recoveryStatusOf(connected: false, initialized: true),
      RecoveryStatus.notConnected,
    );
    expect(
      recoveryStatusOf(connected: false, initialized: false),
      RecoveryStatus.notSetUp,
    );
  });

  group('log out (CS-08)', () {
    testWidgets('connected recovery: no backup warning', (tester) async {
      LogoutChoice? choice;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => choice = await showLogoutConfirmDialog(
                  context,
                  LogoutRecovery.connected,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Log out?'), findsOneWidget);
      expect(find.textContaining('recovery key restores'), findsOneWidget);
      expect(find.textContaining('Warning'), findsNothing);
      expect(find.textContaining('lost'), findsNothing);
      expect(find.text('Set up recovery'), findsNothing);
      await tester.tap(find.text('Log out'));
      await tester.pumpAndSettle();
      expect(choice, LogoutChoice.logOut);
    });

    testWidgets('no recovery on this device: warns and offers setup', (
      tester,
    ) async {
      expect(
        await _logout(
          tester,
          LogoutRecovery.notConnected,
          tap: 'Set up recovery',
        ),
        LogoutChoice.setUpRecovery,
      );
      expect(
        await _logout(
          tester,
          LogoutRecovery.notConnected,
          tap: 'Log out anyway',
        ),
        LogoutChoice.logOut,
      );
      expect(
        await _logout(tester, LogoutRecovery.unknown, tap: 'Cancel'),
        LogoutChoice.cancel,
      );
    });
  });

  group('recovery settings (CS-27)', () {
    Future<List<String>> pumpBody(
      WidgetTester tester,
      RecoveryStatus status,
    ) async {
      final taps = <String>[];
      await tester.pumpWidget(
        _app(
          RecoverySettingsBody(
            status: status,
            onCheck: () => taps.add('check'),
            onOpenRecovery: () => taps.add('open'),
            onVerify: () => taps.add('verify'),
            onReset: () => taps.add('reset'),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return taps;
    }

    testWidgets('connected: status, verify, and reset last', (tester) async {
      final taps = await pumpBody(tester, RecoveryStatus.connected);
      expect(find.text('Key backup'), findsOneWidget);
      expect(find.textContaining('On.'), findsOneWidget);
      await tester.tap(find.text('Verify recovery key'));
      await tester.tap(find.text('Reset recovery key…'));
      expect(taps, ['verify', 'reset']);
      expect(find.text('Enter recovery key'), findsNothing);
      for (final legacy in [
        'Chat backup',
        'Online Key Backup',
        'Crypto Identity',
        'Manage recovery',
      ]) {
        expect(find.textContaining(legacy), findsNothing);
      }
    });

    testWidgets('not connected or not set up: one way forward, no reset', (
      tester,
    ) async {
      var taps = await pumpBody(tester, RecoveryStatus.notConnected);
      await tester.tap(find.text('Enter recovery key'));
      expect(taps, ['open']);
      expect(find.text('Reset recovery key…'), findsNothing);

      taps = await pumpBody(tester, RecoveryStatus.notSetUp);
      await tester.tap(find.text('Set up recovery key'));
      expect(taps, ['open']);
      expect(find.text('Verify recovery key'), findsNothing);

      taps = await pumpBody(tester, RecoveryStatus.unknown);
      await tester.tap(find.text('Check again'));
      expect(taps, ['check']);
    });

    testWidgets('reset needs an explicit destructive confirmation', (
      tester,
    ) async {
      bool? confirmed;
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async =>
                    confirmed = await confirmRecoveryReset(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Reset your recovery key?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(confirmed, isFalse);
    });

    testWidgets('verify tells a wrong key from a working one', (tester) async {
      final checked = <String>[];
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showVerifyRecoveryKeyDialog(
                  context,
                  check: (key) async {
                    checked.add(key);
                    return key == 'EsTx good'
                        ? null
                        : RecoveryUnlockFailure.wrongKey;
                  },
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'EsTx bad');
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(
        find.text('This isn’t the recovery key for your account.'),
        findsOneWidget,
      );
      await tester.enterText(find.byType(TextField), 'EsTx good');
      await tester.tap(find.text('Check'));
      await tester.pumpAndSettle();
      expect(find.textContaining('This recovery key works'), findsOneWidget);
      expect(checked, ['EsTx bad', 'EsTx good']);
      await tester.tap(find.text('Done'));
      await tester.pumpAndSettle();
      expect(find.text('Verify your recovery key'), findsNothing);
    });
  });
}
