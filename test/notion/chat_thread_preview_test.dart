// SPDX-License-Identifier: AGPL-3.0-or-later
// Fictional account and messages; no native phone or real network access.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat_list/chat_actions_menu.dart';
import 'package:chatloom/pages/chat_list/chat_thread_preview.dart';
import 'package:chatloom/pages/chat_list/room_thread_preview.dart';
import 'package:chatloom/personal/hidden_messages.dart';
import 'package:chatloom/personal/ui/notion_inbox_row.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Database implements DatabaseApi {
  final events = <String, List<Event>>{};
  final reads = <(String, int?)>[];
  bool fail = false;
  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async {
    reads.add((room.id, limit));
    if (fail) throw StateError('Fictional database unavailable');
    return (events[room.id] ?? []).take(limit ?? 40).toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected database write/access: ${invocation.memberName}',
  );
}

class _Client extends Client {
  _Client(_Database database)
    : super(
        'offline thread preview',
        database: database,
        httpClient: MockClient((_) => throw StateError('Network forbidden')),
      );
  @override
  String get userID => '@owner:example.invalid';
}

Event _event(
  Room room,
  String id,
  int minute, {
  String type = EventTypes.Message,
  Map<String, dynamic>? content,
  bool deleted = false,
}) => Event(
  room: room,
  eventId: '\$$id',
  senderId: '@anna:example.invalid',
  type: type,
  content: content ?? {'msgtype': MessageTypes.Text, 'body': id},
  originServerTs: DateTime(2026, 11, 6, 9, minute),
  unsigned: deleted
      ? {
          'redacted_because': {
            'type': EventTypes.Redaction,
            'event_id': r'$redaction',
            'sender': '@anna:example.invalid',
            'origin_server_ts': 1793955600000,
            'content': <String, dynamic>{},
          },
        }
      : {},
);

void main() {
  late _Database database;
  late _Client client;
  late Room room;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
    await (FontLoader('Roboto')
          ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Regular.ttf'))
          ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Medium.ttf'))
          ..addFont(rootBundle.load('assets/notion/fonts/Roboto-Bold.ttf')))
        .load();
  });

  setUp(() {
    database = _Database();
    client = _Client(database);
    room = Room(
      id: '!chat:example.invalid',
      client: client,
      notificationCount: 3,
    );
    client.rooms.add(room);
    HiddenMessages.instance.storageFor = (_) => null;
  });

  tearDown(() {
    HiddenMessages.instance.storageFor = HiddenMessages.defaultStorage;
  });

  test(
    'bounded local reads preserve unread state and newest sync, across sources',
    () async {
      final other = Room(id: '!other:example.invalid', client: client);
      final first = _event(room, 'first', 1);
      final newer = _event(other, 'newer', 2);
      final live = _event(room, 'live', 3);
      database.events[room.id] = [first];
      database.events[other.id] = [newer];
      room.lastEvent = live;
      final result = await loadThreadPreview([room, other]);
      expect(result.failed, isFalse);
      expect(visibleThreadPreviewEvents(result.events), [first, newer, live]);
      expect(database.reads, [(room.id, 40), (other.id, 40)]);
      expect(room.notificationCount, 3);
      expect(room.lastEvent, same(live));
    },
  );

  test(
    'filters edits, reactions, hidden messages and deleted original text',
    () {
      final visible = _event(room, 'visible', 1);
      final hidden = _event(room, 'hidden', 2);
      HiddenMessages.instance.hide(hidden);
      final edit = _event(
        room,
        'edit',
        3,
        content: {
          'msgtype': MessageTypes.Text,
          'body': 'edited',
          'm.relates_to': {
            'rel_type': RelationshipTypes.edit,
            'event_id': visible.eventId,
          },
        },
      );
      final reaction = _event(room, 'reaction', 4, type: EventTypes.Reaction);
      final deleted = _event(room, 'removed', 5, deleted: true);
      final events = visibleThreadPreviewEvents([
        visible,
        hidden,
        edit,
        reaction,
        deleted,
      ]);
      expect(events, [visible, deleted]);
    },
  );

  test(
    'keeps saved history in order, distinguishes equal event IDs in different rooms',
    () {
      final other = Room(id: '!other:example.invalid', client: client);
      final events = [for (var i = 0; i < 10; i++) _event(room, 'event-$i', i)];
      final last = _event(other, 'event-9', 10);
      final visible = visibleThreadPreviewEvents([...events.reversed, last]);
      expect(visible, [...events, last]);
    },
  );

  test(
    'database failure retains cached newest message without a network fallback',
    () async {
      database.fail = true;
      room.lastEvent = _event(room, 'cached', 1);
      final result = await loadThreadPreview([room]);
      expect(result.failed, isTrue);
      expect(result.events, [room.lastEvent]);
    },
  );

  testWidgets(
    'holding an inbox row previews without opening/reading; explicit Open chat returns action',
    (tester) async {
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      database.events[room.id] = [_event(room, 'Saved message', 1)];
      ChatMenuAction? chosen;
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Scaffold(
            body: Builder(
              builder: (context) => NotionInboxRow(
                avatar: const SizedBox.shrink(),
                name: 'Anna',
                preview: 'Saved message',
                unreadCount: 3,
                onTap: () => taps++,
                onLongPress: () async => chosen = await showChatActionsMenu(
                  context,
                  anchor: const Rect.fromLTWH(0, 80, 390, 64),
                  title: 'Anna',
                  preview: RoomThreadPreview(
                    sources: [room],
                    isCurrent: () => true,
                    changes: changes,
                    sourceLabel: (_) => 'WhatsApp',
                  ),
                  items: const [
                    ChatMenuItem(
                      ChatMenuAction.open,
                      Icons.open_in_new,
                      'Open chat',
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.longPress(find.byType(NotionInboxRow));
      await tester.pumpAndSettle();
      expect(find.text('Preview · stays unread'), findsOneWidget);
      expect(find.byType(ChatThreadPreview), findsOneWidget);
      expect(room.notificationCount, 3);
      expect(taps, 0);
      expect(chosen, isNull);
      await tester.tapAt(const Offset(780, 580));
      await tester.pumpAndSettle();
      expect(find.byType(ChatThreadPreview), findsNothing);
      expect(room.notificationCount, 3);
      expect(chosen, isNull);
      await tester.longPress(find.byType(NotionInboxRow));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open chat'));
      await tester.pumpAndSettle();
      expect(chosen, ChatMenuAction.open);
      expect(room.notificationCount, 3);
      // Tapping the row still follows the ordinary navigation callback.
      await tester.tap(find.byType(NotionInboxRow));
      expect(taps, 1);
    },
  );

  testWidgets(
    'deleted and encrypted messages show placeholders without profile requests',
    (tester) async {
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      final deleted = _event(
        room,
        'Original text must never appear',
        1,
        deleted: true,
      );
      (deleted.unsigned!['redacted_because'] as Map)['sender'] =
          '@unknown-admin:example.invalid';
      database.events[room.id] = [
        deleted,
        _event(
          room,
          'ciphertext',
          2,
          type: EventTypes.Encrypted,
          content: {'ciphertext': 'fictional'},
        ),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Scaffold(
            body: RoomThreadPreview(
              sources: [room],
              isCurrent: () => true,
              changes: changes,
              sourceLabel: (_) => 'WhatsApp',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Message deleted'), findsOneWidget);
      expect(find.text('Encrypted message'), findsOneWidget);
      expect(find.text('Original text must never appear'), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'older preview pages stay unread and preserve the scroll position',
    (tester) async {
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      database.events[room.id] = [
        for (var i = 95; i >= 0; i--) _event(room, 'Saved message $i', i),
      ];
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Scaffold(
            body: RoomThreadPreview(
              sources: [room],
              isCurrent: () => true,
              changes: changes,
              sourceLabel: (_) => 'WhatsApp',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final list = find.byKey(const ValueKey('chat-thread-preview-messages'));
      final scrollable = find.descendant(
        of: list,
        matching: find.byType(Scrollable),
      );
      final position = tester.state<ScrollableState>(scrollable).position;
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      final before = position.pixels;
      await tester.tap(find.text('Load older messages'));
      await tester.pumpAndSettle();
      expect(database.reads.map((read) => read.$2), [40, 80]);
      expect(position.pixels, closeTo(before, 1));
      expect(room.notificationCount, 3);
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Load older messages'));
      await tester.pumpAndSettle();
      expect(database.reads.last.$2, 120);
      position.jumpTo(position.maxScrollExtent);
      await tester.pumpAndSettle();
      expect(find.text('End of saved preview'), findsOneWidget);
      expect(room.notificationCount, 3);
    },
  );

  testWidgets(
    'open preview reacts to local hides and drops contents when account changes',
    (tester) async {
      final changes = ChangeNotifier();
      addTearDown(changes.dispose);
      var current = true;
      final event = _event(room, 'Private saved message', 1);
      database.events[room.id] = [event];
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Scaffold(
            body: RoomThreadPreview(
              sources: [room],
              isCurrent: () => current,
              changes: changes,
              sourceLabel: (_) => 'WhatsApp',
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Private saved message'), findsOneWidget);
      HiddenMessages.instance.hide(event);
      await tester.pumpAndSettle();
      expect(find.text('Private saved message'), findsNothing);
      HiddenMessages.instance.unhide(event);
      await tester.pumpAndSettle();
      expect(find.text('Private saved message'), findsOneWidget);
      current = false;
      changes.notifyListeners();
      await tester.pumpAndSettle();
      expect(find.text('Private saved message'), findsNothing);
    },
  );

  for (final size in [
    const Size(320, 568),
    const Size(390, 844),
    const Size(1200, 800),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets(
        'preview fits $size at text scale $scale; actions remain reachable',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final boundary = GlobalKey();
          ChatMenuAction? chosen;
          await tester.pumpWidget(
            MaterialApp(
              theme: NotionTheme.build(Brightness.dark),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context).copyWith(
                  textScaler: TextScaler.linear(scale),
                  padding: const EdgeInsets.only(top: 44, bottom: 34),
                ),
                child: RepaintBoundary(key: boundary, child: child),
              ),
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async => chosen = await showChatActionsMenu(
                      context,
                      anchor: Rect.fromLTWH(
                        0,
                        size.height - 100,
                        size.width,
                        64,
                      ),
                      title: 'Anna · WhatsApp & Messenger',
                      preview: ChatThreadPreview(
                        messages: [
                          for (var i = 0; i < 8; i++)
                            ChatThreadPreviewMessage(
                              text: i.isEven
                                  ? 'See you tomorrow! Let’s meet by the river.'
                                  : 'Video: A walk in the mountains',
                              sender: i.isEven ? 'Anna' : 'You',
                              timestamp: DateTime(2026, 11, 6, 9, i),
                              outgoing: i.isOdd,
                              source: i.isEven ? 'WhatsApp' : 'Messenger',
                            ),
                        ],
                      ),
                      items: const [
                        ChatMenuItem(
                          ChatMenuAction.open,
                          Icons.open_in_new,
                          'Open chat',
                        ),
                        ChatMenuItem(
                          ChatMenuAction.read,
                          Icons.done_all,
                          'Mark as read',
                        ),
                        ChatMenuItem(
                          ChatMenuAction.pin,
                          Icons.push_pin_outlined,
                          'Pin',
                        ),
                      ],
                    ),
                    child: const Text('Preview Anna'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('Preview Anna'));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final panel = tester.getRect(
            find.byType(ChatActionsPanel<ChatMenuAction>),
          );
          expect(panel.top, greaterThanOrEqualTo(44));
          expect(panel.bottom, lessThanOrEqualTo(size.height - 34));
          if (size.width == 390 && scale == 1) {
            await tester.runAsync(() async {
              final image =
                  await (boundary.currentContext!.findRenderObject()
                          as RenderRepaintBoundary)
                      .toImage();
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File('build/chat-thread-preview-mobile.png');
              await file.parent.create(recursive: true);
              await file.writeAsBytes(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
          await tester.ensureVisible(find.text('Open chat'));
          await tester.tap(find.text('Open chat'));
          await tester.pumpAndSettle();
          expect(chosen, ChatMenuAction.open);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
