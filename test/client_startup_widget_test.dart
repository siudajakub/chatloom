// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/ui/notion/notion.dart';
import 'package:fluffychat/utils/client_manager.dart';
import 'package:fluffychat/widgets/client_startup.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
    'corrupt registry shows data-preserving restore retry instead of login',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        ClientManager.clientNamespace: 9,
      });
      final store = await SharedPreferences.getInstance();
      final startup = ClientStartup(
        store: store,
        clientFactory: (_, _) async =>
            throw StateError('must not create an account'),
      );
      await startup.restore();
      await tester.pumpWidget(
        ClientStartupView(
          startup: startup,
          appLockSettings: (pincode: null, useBiometrics: false),
        ),
      );
      expect(find.text('Could not restore your accounts.'), findsOneWidget);
      expect(find.text('Retry account restore'), findsOneWidget);
      expect(find.textContaining('No data was reset.'), findsOneWidget);
      await tester.tap(find.text('Retry account restore'));
      await tester.pumpAndSettle();
      expect(store.get(ClientManager.clientNamespace), 9);
      expect(startup.clients, isEmpty);
      expect(find.text('Could not restore your accounts.'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      startup.dispose();
    },
  );

  testWidgets('app lock failure retry stays on the locked failure surface', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({});
    final store = await SharedPreferences.getInstance();
    var attempts = 0;
    await tester.pumpWidget(
      StartupLockFailureView(
        store: store,
        retry: () async {
          attempts++;
        },
      ),
    );
    expect(find.textContaining('Could not read the app lock.'), findsOneWidget);
    await tester.tap(find.text('Retry app lock'));
    await tester.pumpAndSettle();
    expect(attempts, 1);
    expect(find.text('Retry app lock'), findsOneWidget);
  });

  testWidgets(
    'restoring shows the themed inbox skeleton on the first frame, then the failure surface',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        ClientManager.clientNamespace: ['saved'],
      });
      final store = await SharedPreferences.getInstance();
      final opening = Completer<Client>();
      final startup = ClientStartup(
        store: store,
        clientFactory: (_, _) => opening.future,
      );
      final restoring = startup.restore();
      await tester.pumpWidget(
        ClientStartupView(
          startup: startup,
          appLockSettings: (pincode: null, useBiometrics: false),
        ),
      );
      expect(find.byType(ClientStartupSkeleton), findsOneWidget);
      expect(
        find.bySemanticsLabel(ClientStartupSkeleton.label),
        findsOneWidget,
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final context = tester.element(find.byType(ClientStartupSkeleton));
      expect(Theme.of(context).brightness, Brightness.dark);
      expect(
        Theme.of(context).scaffoldBackgroundColor,
        NotionColors.dark.background,
      );

      opening.completeError(StateError('synthetic database failure'));
      await restoring;
      await tester.pump();
      // The skeleton fades through to the failure surface.
      await tester.pump(NotionMotion.medium);
      expect(find.byType(ClientStartupSkeleton), findsNothing);
      expect(find.text('Could not restore your accounts.'), findsOneWidget);
      expect(find.text('Retry account restore'), findsOneWidget);
      expect(store.getStringList(ClientManager.clientNamespace), ['saved']);
      await tester.pumpWidget(const SizedBox.shrink());
      startup.dispose();
    },
  );

  testWidgets('a stored light theme applies to the first startup frame', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      ClientManager.clientNamespace: ['saved'],
      'theme_mode': ThemeMode.light.name,
    });
    final store = await SharedPreferences.getInstance();
    final opening = Completer<Client>();
    final startup = ClientStartup(
      store: store,
      clientFactory: (_, _) => opening.future,
    );
    final restoring = startup.restore();
    await tester.pumpWidget(
      ClientStartupView(
        startup: startup,
        appLockSettings: (pincode: null, useBiometrics: false),
      ),
    );
    final context = tester.element(find.byType(ClientStartupSkeleton));
    expect(Theme.of(context).brightness, Brightness.light);
    expect(
      Theme.of(context).scaffoldBackgroundColor,
      NotionColors.light.background,
    );
    opening.completeError(StateError('synthetic database failure'));
    await restoring;
    await tester.pumpWidget(const SizedBox.shrink());
    startup.dispose();
  });
}
