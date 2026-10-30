// SPDX-License-Identifier: AGPL-3.0-or-later
// Golden of the pinned grid (wave 13). Fictional names.
import 'package:chatloom/personal/ui/notion_inbox_pins.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

NotionPinnedShortcut _pin(
  String name,
  int order, {
  int unreadCount = 0,
  bool unread = false,
  bool mentioned = false,
  bool muted = false,
  List<String> networks = const [],
}) => NotionPinnedShortcut(
  name: name,
  id: name,
  avatar: NotionInitialAvatar(name: name, size: notionPinnedAvatarSize),
  onTap: () {},
  order: order,
  unreadCount: unreadCount,
  unread: unread,
  mentioned: mentioned,
  muted: muted,
  networks: networks,
);

Widget _grid(Brightness brightness) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(brightness),
  home: Scaffold(
    body: Center(
      child: RepaintBoundary(
        key: const ValueKey('grid'),
        child: ColoredBox(
          color: NotionTheme.build(brightness).scaffoldBackgroundColor,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
            child: NotionPinnedShortcuts(
              onReorder: (_) async {},
              pins: [
                _pin(
                  'Anna Kowalska',
                  0,
                  unreadCount: 3,
                  networks: ['whatsapp'],
                ),
                _pin('Team', 1, networks: ['slack']),
                _pin('Mia', 2, unread: true),
                _pin('Jan', 3, unreadCount: 12, muted: true),
                _pin('Family group', 4, mentioned: true, muted: true),
                _pin('Ola', 5, networks: ['telegram', 'signal']),
                _pin('Piotr', 6),
              ],
            ),
          ),
        ),
      ),
    ),
  ),
);

void main() {
  setUpAll(() async {
    final loader = FontLoader('Roboto');
    for (final name in ['Regular', 'Medium', 'Bold']) {
      loader.addFont(rootBundle.load('assets/notion/fonts/Roboto-$name.ttf'));
    }
    await loader.load();
    final icons = FontLoader('MaterialIcons');
    icons.addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });

  for (final brightness in Brightness.values) {
    testWidgets('pinned grid golden (${brightness.name})', (tester) async {
      tester.view.physicalSize = const Size(412, 300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_grid(brightness));
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const ValueKey('grid')),
        matchesGoldenFile('goldens/inbox-pins-grid-${brightness.name}.png'),
      );
    });
  }
}
