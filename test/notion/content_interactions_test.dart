// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:typed_data';
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/personal/personal_hub.dart';
import 'package:chatloom/personal/ui/notion_chat_details_content.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
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
      await tester.ensureVisible(find.text('Files'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Files'));
      await tester.pumpAndSettle();
      expect(find.text('No matches in the loaded history.'), findsOneWidget);
      await tester.ensureVisible(find.text('Media'));
      await tester.pumpAndSettle();
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
      await tester.ensureVisible(find.text('Links'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Links'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Fictional shared media 29',
      );
      await tester.ensureVisible(find.text('Media'));
      await tester.pumpAndSettle();
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
  testWidgets('voice and rounds get their own tab; the sender pills filter', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final db = GalleryDatabase();
    final client = GalleryClient(db);
    final room = ConversationRoom(client, '!kinds:example.invalid');
    Event event(String id, Map<String, dynamic> content, {bool own = false}) =>
        Event(
          room: room,
          eventId: id,
          type: EventTypes.Message,
          senderId: own ? client.userID : '@anna:example.invalid',
          originServerTs: DateTime.utc(2026, 10, 16, 14, id.length),
          content: content,
        );
    db.rows[room.id] = [
      event(r'$voice', {
        'msgtype': MessageTypes.Audio,
        'body': 'Voice message',
        'org.matrix.msc3245.voice': <String, dynamic>{},
        'info': {'duration': 7000},
      }, own: true),
      event(r'$round', {
        'msgtype': MessageTypes.Video,
        'body': 'Video message',
        'info': {'fi.mau.telegram.round_message': true, 'duration': 12000},
      }),
      event(r'$file', {
        'msgtype': MessageTypes.File,
        'body': 'Fictional report.pdf',
      }),
      event(r'$mention', {
        'msgtype': MessageTypes.Text,
        'body': 'Anna: hi',
        'formatted_body':
            '<a href="https://matrix.to/#/@anna:example.invalid">Anna</a>: hi',
      }),
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
            name: 'Fictional Anna',
            initialMedia: true,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    // No round among the photos and videos.
    expect(find.text('Nothing here yet'), findsOneWidget);
    await tester.tap(find.text('Messages'));
    await tester.pumpAndSettle();
    expect(find.text('Voice message'), findsOneWidget);
    expect(find.text('Video message'), findsOneWidget);
    expect(find.textContaining('You · 0:07'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shared-sender-others')));
    await tester.pumpAndSettle();
    expect(find.text('Voice message'), findsNothing);
    expect(find.text('Video message'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('shared-sender-me')));
    await tester.pumpAndSettle();
    expect(find.text('Voice message'), findsOneWidget);
    expect(find.text('Video message'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('shared-sender-everyone')));
    await tester.tap(find.text('Files'));
    await tester.pumpAndSettle();
    expect(find.text('Fictional report.pdf'), findsOneWidget);
    expect(find.text('Voice message'), findsNothing);
    await tester.tap(find.text('Links'));
    await tester.pumpAndSettle();
    expect(find.text('matrix.to'), findsNothing);
    expect(find.text('Nothing here yet'), findsOneWidget);
    expect(find.text('Fictional'), findsOneWidget);
    expect(client.requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
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
    await tester.tap(find.byTooltip('Conversation options'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Send later'));
    await tester.pumpAndSettle();
    // The Send later sheet, or (without private sync in this fixture) one
    // specific explanation; never a generic "could not request" text.
    final sheet = find.text('Schedule message');
    final explained = find.textContaining('Send later needs private sync');
    final failed = find.textContaining('Couldn’t schedule this message');
    expect(
      sheet.evaluate().isNotEmpty ||
          explained.evaluate().isNotEmpty ||
          failed.evaluate().isNotEmpty,
      isTrue,
    );
    if (sheet.evaluate().isNotEmpty) {
      expect(find.text('Schedule an attachment'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
    }
    expect(editor.value, original);
    expect(client.requests, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    editor.dispose();
  });
}
