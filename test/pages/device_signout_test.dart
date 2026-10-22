// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/device_settings/device_signout.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';

// Fictional sessions; ids and keys are placeholders.
final _phone = Device(deviceId: 'THIS', displayName: 'ChatLoom Android');
final _desktop = Device(
  deviceId: 'DESK',
  displayName: 'Beeper Desktop',
  lastSeenTs: DateTime(2026, 10, 20).millisecondsSinceEpoch,
);
final _ios = Device(deviceId: 'IOS', displayName: 'Beeper iOS');
final _renamedWorker = Device(deviceId: 'WRK', displayName: 'Home server');
final _namedWorker = Device(
  deviceId: 'WRK2',
  displayName: 'Personal feature worker',
);

Future<void> _host(
  WidgetTester tester,
  void Function(BuildContext) open,
) async {
  await tester.pumpWidget(
    MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  // L10n loads deferred: let it arrive before tapping.
  await tester.pump();
  await tester.pump();
  await tester.pumpAndSettle();
}

void main() {
  group('worker detection (CC-26)', () {
    test('the heartbeat signer is the worker, even after a rename', () {
      expect(
        findWorkerDeviceIds(
          devices: [_desktop, _ios, _renamedWorker],
          identityKeys: {
            'DESK': 'curve-desk',
            'IOS': 'curve-ios',
            'WRK': 'curve-worker',
          },
          heartbeatDeviceKey: 'curve-worker',
        ),
        {'WRK'},
      );
    });

    test('without a heartbeat the default worker name still counts', () {
      expect(findWorkerDeviceIds(devices: [_desktop, _ios, _namedWorker]), {
        'WRK2',
      });
      expect(isWorkerDeviceName('Personal feature worker'), isTrue);
      expect(isWorkerDeviceName('ChatLoom worker'), isTrue);
      expect(isWorkerDeviceName('Beeper Desktop'), isFalse);
      expect(isWorkerDeviceName('Networker laptop'), isFalse);
      expect(isWorkerDeviceName(null), isFalse);
    });

    test('bulk sign-out never includes the worker', () {
      final others = [_desktop, _renamedWorker, _ios, _namedWorker];
      final workers = findWorkerDeviceIds(
        devices: others,
        identityKeys: {'WRK': 'curve-worker'},
        heartbeatDeviceKey: 'curve-worker',
      );
      expect(bulkSignOutDevices(others, workers).map((d) => d.deviceId), [
        'DESK',
        'IOS',
      ]);
      expect(bulkSignOutDevices([_phone], const {}), [_phone]);
    });
  });

  group('confirmations', () {
    testWidgets('bulk sign-out lists the sessions and needs two steps', (
      tester,
    ) async {
      bool? confirmed;
      await _host(
        tester,
        (context) async => confirmed = await confirmBulkSignOut(
          context,
          devices: [_desktop, _ios],
          workerKept: true,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out 2 other devices?'), findsOneWidget);
      expect(find.text('Beeper Desktop'), findsOneWidget);
      expect(find.text('Beeper iOS'), findsOneWidget);
      expect(find.textContaining('worker stays signed in'), findsOneWidget);

      await tester.tap(find.text('Sign out 2 devices'));
      await tester.pumpAndSettle();
      expect(find.text('Are you sure?'), findsOneWidget);
      expect(confirmed, isNull);
      // Cancel at the second step signs nothing out.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(confirmed, isFalse);

      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out 2 devices'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(confirmed, isTrue);
    });

    testWidgets('signing out the worker needs the phrase typed', (
      tester,
    ) async {
      bool? confirmed;
      await _host(
        tester,
        (context) async => confirmed = await confirmDeviceSignOut(
          context,
          device: _namedWorker,
          worker: true,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out the ChatLoom worker?'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'yes');
      await tester.tap(find.text('Sign out worker'));
      await tester.pumpAndSettle();
      // Wrong phrase: the dialog stays and explains.
      expect(find.text('Sign out the ChatLoom worker?'), findsOneWidget);
      expect(confirmed, isNull);
      await tester.enterText(find.byType(TextField), 'Remove worker');
      await tester.tap(find.text('Sign out worker'));
      await tester.pumpAndSettle();
      expect(confirmed, isTrue);
    });

    testWidgets('an ordinary device gets one named confirmation', (
      tester,
    ) async {
      bool? confirmed;
      await _host(
        tester,
        (context) async => confirmed = await confirmDeviceSignOut(
          context,
          device: _desktop,
          worker: false,
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out Beeper Desktop?'), findsOneWidget);
      await tester.tap(find.text('Sign out'));
      await tester.pumpAndSettle();
      expect(confirmed, isTrue);
    });
  });
}
