// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/ui/notion_privacy_preferences.dart';
import 'package:chatloom/personal/ui/notion_settings_body.dart';
import 'package:chatloom/personal/ui/notion_settings_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/layouts/two_column_layout.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

NotionSettingsPage _index({
  ValueChanged<String>? open,
  String path = '/rooms/settings',
}) => NotionSettingsPage(
  data: NotionSettingsData(
    name: 'Fictional account',
    avatar: const Icon(Icons.person_outline),
    selectedPath: path,
  ),
  actions: NotionSettingsActions(open: open),
);

void main() {
  testWidgets(
    'desktop without notifications keeps reminders and scheduled tools',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: NotionSettingsPage(
            data: const NotionSettingsData(
              name: 'Fictional account',
              avatar: Icon(Icons.person_outline),
              notificationsAvailable: false,
            ),
            actions: const NotionSettingsActions(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Notifications'), findsNothing);
      await tester.scrollUntilVisible(find.text('Reminders'), 100);
      expect(find.text('Reminders'), findsOneWidget);
      await tester.scrollUntilVisible(find.text('Scheduled messages'), 100);
      expect(find.text('Scheduled messages'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'all categories and tools are direct, single destinations without overflow',
    (tester) async {
      final visited = <String>[];
      await tester.pumpWidget(MaterialApp(home: _index(open: visited.add)));
      for (final category in NotionSettingsCategory.values) {
        final target = find.text(
          category == NotionSettingsCategory.account
              ? 'Fictional account'
              : category.title,
        );
        await tester.scrollUntilVisible(target, 100);
        // Rows scroll under the glass header: centre the row instead of
        // aligning it with the (covered) top edge of the viewport.
        await Scrollable.ensureVisible(tester.element(target), alignment: .5);
        await tester.pumpAndSettle();
        await tester.tap(target);
      }
      expect(
        visited,
        NotionSettingsCategory.values
            .map((category) => category.route)
            .toList(),
      );
      expect(visited.toSet().length, visited.length);
      expect(find.byTooltip('More settings'), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byType(TextField), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  test('secondary routes select the owning category', () {
    const cases = {
      '/rooms/settings': NotionSettingsCategory.account,
      '/rooms/settings/account': NotionSettingsCategory.account,
      '/rooms/settings/devices': NotionSettingsCategory.security,
      '/rooms/settings/recovery': NotionSettingsCategory.security,
      '/rooms/settings/security/ignorelist': NotionSettingsCategory.security,
      '/rooms/settings/people': NotionSettingsCategory.chats,
      '/rooms/settings/chat/media': NotionSettingsCategory.chats,
      '/rooms/settings/networks': NotionSettingsCategory.networks,
      '/rooms/settings/transcriptions': NotionSettingsCategory.transcription,
      '/rooms/settings/reminders': NotionSettingsCategory.reminders,
      '/rooms/settings/push': NotionSettingsCategory.notifications,
      '/rooms/settings/notifications/registration':
          NotionSettingsCategory.notifications,
      '/rooms/settings/notifications/rules':
          NotionSettingsCategory.notifications,
      '/rooms/settings/sync': NotionSettingsCategory.advanced,
      '/rooms/settings/advanced': NotionSettingsCategory.advanced,
    };
    for (final entry in cases.entries) {
      expect(NotionSettingsCategory.forPath(entry.key), entry.value);
    }
  });

  testWidgets('index groups everyday settings, tools and Advanced last', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: _index(open: (_) {})));
    await tester.pumpAndSettle();
    double top(String text) => tester.getTopLeft(find.text(text)).dy;
    final order = [
      'Fictional account',
      'Appearance',
      'Notifications',
      'Privacy & security',
      'Chats',
      'Networks',
      'Transcription',
      'Tools',
      'Reminders',
      'Scheduled messages',
      'Bookmarks',
      'Advanced',
    ];
    for (var i = 1; i < order.length; i++) {
      expect(top(order[i]), greaterThan(top(order[i - 1])), reason: order[i]);
    }
    // FluffyChat leftovers are gone from the index.
    for (final removed in [
      'About & help',
      'Homeserver',
      'Sync & transcriptions',
      'Chats & organization',
    ]) {
      expect(find.text(removed), findsNothing);
    }
  });

  for (final incognito in [true, false]) {
    for (final pending in [true, false]) {
      testWidgets(
        'privacy preserves saved choices: incognito=$incognito pending=$pending',
        (tester) async {
          final calls = <bool>[];
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SingleChildScrollView(
                  child: NotionPrivacyPreferences(
                    incognito: incognito,
                    pending: pending,
                    typing: true,
                    receipts: true,
                    onIncognito: calls.add,
                    onTyping: calls.add,
                    onReceipts: calls.add,
                  ),
                ),
              ),
            ),
          );
          final switches = tester
              .widgetList<Switch>(find.byType(Switch))
              .toList();
          expect(switches.map((s) => s.value), [incognito, true, true]);
          expect(switches.first.onChanged == null, pending);
          expect(switches[1].onChanged == null, incognito || pending);
          expect(switches[2].onChanged == null, incognito || pending);
          expect(calls, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('settings sections use the shared RTL-safe section header', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: const Directionality(
          textDirection: TextDirection.rtl,
          child: Scaffold(body: NotionSettingsSection('Rules')),
        ),
      ),
    );
    expect(
      find.descendant(
        of: find.byType(NotionSettingsSection),
        matching: find.byType(NotionSectionHeader),
      ),
      findsOneWidget,
    );
    expect(
      tester.getSemantics(find.text('Rules')),
      matchesSemantics(label: 'Rules', isHeader: true),
    );
    semantics.dispose();
    // No hard-coded left alignment: the label follows the text direction.
    expect(
      find.descendant(
        of: find.byType(NotionSettingsSection),
        matching: find.byType(Align),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('privacy switch is keyboard operable with one toggle action', (
    tester,
  ) async {
    final changes = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: NotionSettingsToggle(
            title: 'Incognito mode',
            value: true,
            onChanged: changes.add,
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(changes, [false]);
    final semantics = tester.ensureSemantics();
    expect(find.bySemanticsLabel('Incognito mode'), findsOneWidget);
    semantics.dispose();
  });

  testWidgets(
    'failed privacy change keeps current policy and announces recovery',
    (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: NotionPrivacyPreferences(
                incognito: true,
                typing: false,
                receipts: false,
                error: 'Could not save privacy. Try again.',
              ),
            ),
          ),
        ),
      );
      expect(find.text('Could not save privacy. Try again.'), findsOneWidget);
      expect(tester.widget<Switch>(find.byType(Switch).first).value, isTrue);
    },
  );

  for (final width in [320.0, 390.0, 430.0, 900.0, 1365.0]) {
    for (final scale in [1.0, 2.0]) {
      for (final brightness in Brightness.values) {
        testWidgets('settings reachable at $width/$scale/$brightness', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = Size(width, 900);
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final index = _index(open: (_) {}, path: '/rooms/settings/sync');
          await tester.pumpWidget(
            MaterialApp(
              theme: NotionTheme.build(brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scale)),
                child: child!,
              ),
              home: width > 840
                  ? TwoColumnLayout(
                      mainView: index,
                      sideView: const NotionSettingsScaffold(
                        title: 'Private sync',
                        child: Text('Changes awaiting confirmation'),
                      ),
                    )
                  : index,
            ),
          );
          await tester.scrollUntilVisible(
            find.text('Scheduled messages'),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          await tester.ensureVisible(find.text('Scheduled messages'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
