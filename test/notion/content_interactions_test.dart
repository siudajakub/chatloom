// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/personal/personal_hub.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_content.dart';
import 'package:fluffychat/widgets/matrix.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'conversation_test_support.dart';
import 'profile_content_capture_test.dart'
    show GalleryClient, GalleryDatabase, ThumbnailEvent;

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.showThumbnailsInTimeline.setItem(false);
  });
  testWidgets(
    'tabs preserve independent scroll and query without transport writes',
    (tester) async {
      tester.view.physicalSize = const Size(390, 600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final db = GalleryDatabase();
      final client = GalleryClient(db);
      final room = ConversationRoom(client, '!tabs:example.invalid');
      db.rows[room.id] = [
        for (var i = 0; i < 30; i++) ThumbnailEvent(room, i, Uint8List(0)),
      ];
      final prefs = await SharedPreferences.getInstance();
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: ConversationMatrix(client, prefs),
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: NotionConversationContentPage(
              rooms: [room],
              name: 'Fictional tabs',
              initialMedia: true,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(CustomScrollView), const Offset(0, -350));
      await tester.pumpAndSettle();
      final before = tester
          .state<ScrollableState>(find.byType(Scrollable).last)
          .position
          .pixels;
      expect(before, greaterThan(0));
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      expect(find.text('No matches in the loaded history.'), findsOneWidget);
      await tester.tap(find.text('Media'));
      await tester.pumpAndSettle();
      expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).last)
            .position
            .pixels,
        before,
      );
      await tester.enterText(
        find.byType(TextField),
        'Fictional shared media 29',
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Links'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Fictional shared media 29',
      );
      await tester.tap(find.text('Media'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Fictional shared media 29',
      );
      expect(client.requests, isEmpty);
      expect(room.reactionsSent, 0);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  testWidgets('cancelling Send later retains text selection and composition', (
    tester,
  ) async {
    final client = GalleryClient(GalleryDatabase());
    final room = ConversationRoom(client, '!schedule:example.invalid');
    final editor = TextEditingController.fromValue(
      const TextEditingValue(
        text: 'Unsent draft',
        selection: TextSelection(baseOffset: 2, extentOffset: 5),
        composing: TextRange(start: 0, end: 6),
      ),
    );
    final original = editor.value;
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: ConversationMatrix(client, prefs),
        child: MaterialApp(
          home: Scaffold(
            appBar: AppBar(
              actions: [
                RoomPersonalButton(
                  room: room,
                  composer: editor,
                  readCutoff: () => null,
                  includeChatSettings: true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send later'));
    await tester.pumpAndSettle();
    expect(find.text('Attachment'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(editor.value, original);
    expect(client.requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    editor.dispose();
  });
}
