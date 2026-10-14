// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/ui/notion_settings_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'settings privacy control is device-wide and all main routes are reachable',
    (tester) async {
      final actions = <String>[];
      bool? privacy;
      await tester.pumpWidget(
        MaterialApp(
          home: NotionSettingsPage(
            data: const NotionSettingsData(
              name: 'Jan',
              avatar: Icon(Icons.person_outline),
              incognito: true,
              appLock: 'Off',
              appearance: 'Dark',
              privateSync: 'Not connected',
            ),
            actions: NotionSettingsActions(
              editProfile: () => actions.add('profile'),
              appLock: () => actions.add('lock'),
              devices: () => actions.add('devices'),
              notifications: () => actions.add('notifications'),
              appearance: () => actions.add('appearance'),
              transcriptions: () => actions.add('transcriptions'),
              privateSync: () => actions.add('sync'),
              about: () => actions.add('about'),
              overflow: () => actions.add('more'),
              incognito: (value) => privacy = value,
            ),
          ),
        ),
      );
      await tester.tap(find.text('Edit profile'));
      await tester.scrollUntilVisible(find.text('Incognito mode'), 120);
      await tester.ensureVisible(find.byType(Switch));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(Switch));
      expect(privacy, false);
      for (final label in [
        'App lock',
        'Devices & keys',
        'Notifications',
        'Appearance',
        'Transcriptions',
        'Private sync',
        'About',
      ]) {
        await tester.scrollUntilVisible(find.text(label), 100);
        await tester.ensureVisible(find.text(label));
        await tester.pumpAndSettle();
        await tester.tap(find.text(label));
      }
      await tester.tap(find.byTooltip('More settings'));
      expect(actions, [
        'profile',
        'lock',
        'devices',
        'notifications',
        'appearance',
        'transcriptions',
        'sync',
        'about',
        'more',
      ]);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'pending privacy keeps real value and disables duplicate changes',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: NotionSettingsPage(
            data: NotionSettingsData(
              name: 'Jan',
              avatar: Icon(Icons.person_outline),
              incognito: true,
              privacyPending: true,
              status: 'Waiting for device settings',
            ),
            actions: NotionSettingsActions(),
          ),
        ),
      );
      await tester.scrollUntilVisible(find.byType(Switch), 100);
      await tester.ensureVisible(find.byType(Switch));
      await tester.pumpAndSettle();
      final control = tester.widget<Switch>(find.byType(Switch));
      expect(control.value, isTrue);
      expect(control.onChanged, isNull);
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [320.0, 390.0, 430.0]) {
    testWidgets(
      'settings adapts long copy and 200 percent text at width $width',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 844);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            home: MediaQuery(
              data: MediaQueryData(
                size: Size(width, 844),
                textScaler: const TextScaler.linear(2),
              ),
              child: SizedBox(
                width: width,
                child: const NotionSettingsPage(
                  data: NotionSettingsData(
                    name: 'A long fictional account name',
                    avatar: Icon(Icons.person_outline),
                    incognito: true,
                    appLock: 'Unknown',
                    appearance: 'System',
                    privateSync: 'Changes awaiting synchronization',
                  ),
                  actions: NotionSettingsActions(),
                ),
              ),
            ),
          ),
        );
        await tester.scrollUntilVisible(find.text('About'), 240);
        await tester.ensureVisible(find.text('About'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
