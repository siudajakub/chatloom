// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/personal/ui/notion_chat_details_page.dart';
import 'package:fluffychat/ui/notion/notion.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  testWidgets(
    'details incognito links to device settings and has no room switch',
    (tester) async {
      var privacy = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: NotionChatDetailsPage(
            data: const NotionConversationDetailsData(
              name: 'Anna',
              network: 'WhatsApp',
              avatar: Icon(Icons.person_outline),
              incognito: true,
              notifications: 'Mentions only',
            ),
            actions: NotionConversationDetailsActions(privacy: () => privacy++),
          ),
        ),
      );
      await tester.scrollUntilVisible(find.text('Incognito mode'), 180);
      await tester.ensureVisible(find.text('Incognito mode'));
      await tester.pumpAndSettle();
      expect(find.text('Applies to this device'), findsOneWidget);
      // The only switch is the private pin control.
      expect(find.byType(Switch), findsOneWidget);
      await tester.tap(find.text('Incognito mode'));
      expect(privacy, 1);
      expect(find.text('Mentions only'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'production shared content blocks preserve geometry and callback scope',
    (tester) async {
      var opened = '';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Row(
              children: [
                NotionSharedContentBlock(
                  label: 'Photo',
                  thumbnail: const ColoredBox(color: Colors.grey),
                  onTap: () => opened = 'photo',
                ),
                NotionSharedContentBlock(
                  label: 'notes.pdf',
                  onTap: () => opened = 'file',
                ),
                NotionSharedContentBlock(
                  label: '0:18',
                  audio: true,
                  onTap: () => opened = 'audio',
                ),
              ],
            ),
          ),
        ),
      );
      final blocks = find.byType(NotionSharedContentBlock);
      expect(tester.getSize(blocks.at(0)), const Size(144, 92));
      expect(tester.getSize(blocks.at(1)), const Size(88, 92));
      expect(tester.getSize(blocks.at(2)), const Size(88, 92));
      await tester.tap(find.text('notes.pdf'));
      expect(opened, 'file');
      await tester.tap(find.text('0:18'));
      expect(opened, 'audio');
      await tester.tap(blocks.at(0));
      expect(opened, 'photo');
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [320.0, 390.0, 430.0]) {
    testWidgets(
      'details remain scrollable with long names at width $width and 200 percent text',
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
                child: const NotionChatDetailsPage(
                  data: NotionConversationDetailsData(
                    name: 'A long fictional contact name on several networks',
                    network: 'WhatsApp · Telegram · Unknown network',
                    avatar: Icon(Icons.person_outline),
                    notifications: 'Mentions only',
                    incognito: true,
                  ),
                  actions: NotionConversationDetailsActions(),
                ),
              ),
            ),
          ),
        );
        await tester.scrollUntilVisible(find.text('View contact'), 240);
        await tester.ensureVisible(find.text('View contact'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      },
    );
  }
}
