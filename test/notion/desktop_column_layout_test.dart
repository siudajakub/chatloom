// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';

import 'package:chatloom/config/themes.dart';
import 'package:chatloom/widgets/layouts/two_column_layout.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

/// Desktop (macOS/Linux/wide tablet) is two columns like Telegram and
/// Messenger desktop: the inbox column beside the chat, with no FluffyChat
/// navigation rail in front of the inbox.
void main() {
  const inboxKey = Key('fixture-inbox');
  const chatKey = Key('fixture-chat');

  Widget app() => MaterialApp(
    home: Builder(
      builder: (context) => ChatLoomThemes.isColumnMode(context)
          ? const TwoColumnLayout(
              mainView: Scaffold(key: inboxKey, body: Text('Inbox')),
              sideView: Scaffold(key: chatKey, body: Text('Chat')),
            )
          : const Scaffold(key: inboxKey, body: Text('Inbox')),
    ),
  );

  Future<void> setSize(WidgetTester tester, Size size) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = size;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  for (final size in const [
    Size(1280, 800),
    Size(1120, 760),
    Size(900, 700),
    Size(800, 700),
  ]) {
    testWidgets('desktop ${size.width.toInt()}x${size.height.toInt()}: '
        'inbox column starts at the window edge, chat fills the rest', (
      tester,
    ) async {
      await setSize(tester, size);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.byType(TwoColumnLayout), findsOneWidget);
      final inbox = tester.getRect(find.byKey(inboxKey));
      final chat = tester.getRect(find.byKey(chatKey));
      expect(inbox.left, 0);
      expect(inbox.width, ChatLoomThemes.columnWidth);
      // One hairline divider between the two columns, nothing else.
      expect(chat.left, ChatLoomThemes.columnWidth + 1);
      expect(chat.right, size.width);
      expect(find.byType(NavigationRail), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final size in const [Size(390, 844), Size(720, 520), Size(760, 520)]) {
    testWidgets('narrow ${size.width.toInt()}: single inbox column', (
      tester,
    ) async {
      await setSize(tester, size);
      await tester.pumpWidget(app());
      await tester.pumpAndSettle();

      expect(find.byType(TwoColumnLayout), findsNothing);
      expect(tester.getRect(find.byKey(inboxKey)).width, size.width);
      expect(find.byKey(chatKey), findsNothing);
    });
  }

  test('the FluffyChat spaces rail is gone from the inbox', () {
    expect(
      File('lib/pages/chat_list/navigation_rail.dart').existsSync(),
      isFalse,
    );
    expect(
      File('lib/pages/chat_list/navi_rail_item.dart').existsSync(),
      isFalse,
    );
    final view = File(
      'lib/pages/chat_list/chat_list_view.dart',
    ).readAsStringSync();
    expect(view, isNot(contains('NavigationRail')));
  });
}
