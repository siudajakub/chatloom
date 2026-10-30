// SPDX-License-Identifier: AGPL-3.0-or-later
// FX-17 (pinned reorder, "Mark all as read") and FX-20 (Copy link).
// Fictional offline fixtures.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/message_link_actions.dart';
import 'package:chatloom/pages/chat_list/chat_list.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/notion_inbox_pins.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/ui/notion/metadata_actions.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

class _Client extends ConversationClient {
  @override
  Uri get baseUri => Uri.parse('https://fixture.invalid');
}

class _Room extends ConversationRoom {
  final receipts = <(String?, String?, bool?)>[];
  _Room(super.client, super.id);

  @override
  Event? get lastEvent => Event(
    room: this,
    eventId: r'$latest',
    type: EventTypes.Message,
    senderId: '@anna:example.invalid',
    originServerTs: DateTime.utc(2026, 10, 23),
    content: {'msgtype': MessageTypes.Text, 'body': 'Fictional message'},
  );

  @override
  Future<void> setReadMarker(
    String? eventId, {
    String? mRead,
    bool? public,
  }) async => receipts.add((eventId, mRead, public));
}

Widget _app(Widget child) => MaterialApp(
  theme: NotionTheme.build(Brightness.dark),
  home: Scaffold(
    body: Padding(padding: const EdgeInsets.all(20), child: child),
  ),
);

NotionPinnedShortcut _pin(String name, int order, {VoidCallback? menu}) =>
    NotionPinnedShortcut(
      name: name,
      id: 'entity-$name',
      avatar: const SizedBox.shrink(),
      onTap: () {},
      onLongPress: menu,
      order: order,
    );

Event _message(Room room, Map<String, Object?> content) => Event(
  room: room,
  eventId: r'$message',
  type: EventTypes.Message,
  senderId: '@anna:example.invalid',
  originServerTs: DateTime.utc(2026, 10, 23),
  content: content,
);

void main() {
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    PersonalPrivacy.surfaceUnlocked = true;
    PersonalPrivacy.surfaceForeground = true;
  });

  group('pin reorder', () {
    test('a dropped pin takes the target slot', () {
      expect(notionMovePin(['a', 'b', 'c'], 'a', 'c'), ['b', 'c', 'a']);
      expect(notionMovePin(['a', 'b', 'c'], 'c', 'a'), ['c', 'a', 'b']);
      final same = ['a', 'b'];
      expect(notionMovePin(same, 'a', 'a'), same);
      expect(notionMovePin(same, 'x', 'a'), same);
    });

    test('persisted orders keep hidden pins in place and renumber', () {
      // b is hidden by a network filter; the user drags c before a.
      expect(
        NotionMetadataActions.pinOrdersAfterReorder(
          {'a': 3, 'b': 5, 'c': 9},
          ['c', 'a'],
        ),
        {'a': 2, 'c': 0, 'b': 1},
      );
      // Already numbered pins only write what changed.
      expect(
        NotionMetadataActions.pinOrdersAfterReorder(
          {'a': 0, 'b': 1, 'c': 2},
          ['a', 'c', 'b'],
        ),
        {'c': 1, 'b': 2},
      );
      // Ties are ordered by entity, unknown entities ignored.
      expect(
        NotionMetadataActions.pinOrdersAfterReorder(
          {'a': 0, 'b': 0},
          ['b', 'a', 'gone'],
        ),
        {'a': 1},
      );
    });

    testWidgets('long-press drag reorders; a still release opens the menu', (
      tester,
    ) async {
      final orders = <List<String>>[];
      var menus = 0;
      await tester.pumpWidget(
        _app(
          NotionPinnedShortcuts(
            pins: [
              _pin('Anna', 0, menu: () => menus++),
              _pin('Team', 1, menu: () => menus++),
            ],
            onReorder: (keys) async => orders.add(keys),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final anna = tester.getCenter(find.text('Anna'));
      final team = tester.getCenter(find.text('Team'));

      // Long press and release without moving: the card's menu.
      final still = await tester.startGesture(anna);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      await still.up();
      await tester.pumpAndSettle();
      expect(menus, 1);
      expect(orders, isEmpty);

      // Long press, drag onto Team, drop.
      final drag = await tester.startGesture(anna);
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 50));
      for (var i = 1; i <= 5; i++) {
        await drag.moveTo(Offset.lerp(anna, team, i / 5)!);
        await tester.pump();
      }
      await drag.up();
      await tester.pumpAndSettle();
      expect(orders, [
        ['entity-Team', 'entity-Anna'],
      ]);
      expect(menus, 1);
      // Shown at once: Team is now first.
      expect(
        tester.getCenter(find.text('Team')).dx,
        lessThan(tester.getCenter(find.text('Anna')).dx),
      );
    });

    testWidgets('a failed save puts the stored order back', (tester) async {
      await tester.pumpWidget(
        _app(
          NotionPinnedShortcuts(
            pins: [_pin('Anna', 0), _pin('Team', 1)],
            onReorder: (_) => Future<void>.error(StateError('offline')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      // Anna moves right through the screen reader action.
      final action = tester
          .widgetList<Semantics>(
            find.byWidgetPredicate(
              (w) =>
                  w is Semantics && w.properties.customSemanticsActions != null,
            ),
          )
          .first
          .properties
          .customSemanticsActions!
          .entries
          .single;
      expect(action.key.label, 'Move right');
      action.value();
      await tester.pump();
      await tester.pumpAndSettle();
      expect(
        tester.getCenter(find.text('Anna')).dx,
        lessThan(tester.getCenter(find.text('Team')).dx),
      );
    });

    testWidgets('the pinned bubble ring follows the light theme (UI-14)', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.light),
          home: Scaffold(body: NotionPinnedShortcuts(pins: [_pin('Anna', 0)])),
        ),
      );
      await tester.pumpAndSettle();
      final border = tester.element(find.text('Anna')).notion.colors.border;
      expect(border, isNot(NotionTokens.border));
      expect(
        tester
            .widgetList<DecoratedBox>(find.byType(DecoratedBox))
            .map((box) => box.decoration)
            .whereType<BoxDecoration>()
            .any(
              (decoration) =>
                  decoration.shape == BoxShape.circle &&
                  (decoration.border as Border?)?.top.color == border,
            ),
        isTrue,
      );
    });
  });

  group('mark all as read', () {
    testWidgets('the Show chats menu offers it', (tester) async {
      var marked = 0;
      await tester.pumpWidget(
        _app(
          NotionNetworkMenu(
            networks: const ['whatsapp'],
            selected: null,
            onSelected: (_) {},
            onViewSelected: (_) {},
            onMarkAllRead: () => marked++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mark all as read'));
      expect(marked, 1);
    });

    test('incognito bulk read keeps the receipt private', () async {
      await AppSettings.personalIncognito.setItem(true);
      await AppSettings.sendPublicReadReceipts.setItem(true);
      final client = _Client();
      final room = _Room(client, '!fixture:example.invalid')
        ..notificationCount = 2;
      final personal = PersonalClient.of(client);
      await markInboxRowRead(personal, room, privateReceipt: true);
      expect(room.receipts, [(r'$latest', r'$latest', false)]);
      // The row action without the flag still follows the receipt setting.
      await markInboxRowRead(personal, room);
      expect(room.receipts.last, (r'$latest', r'$latest', true));
    });
  });

  group('copy link', () {
    test('first web link of the text, else the bridged preview', () {
      final room = ConversationRoom(_Client(), '!fixture:example.invalid');
      expect(
        messageFirstLink(
          _message(room, {
            'msgtype': MessageTypes.Text,
            'body': 'look https://example.invalid/a and https://b.invalid',
          }),
        ),
        'https://example.invalid/a',
      );
      expect(
        messageFirstLink(
          _message(room, {'msgtype': MessageTypes.Text, 'body': 'no link.'}),
        ),
        isNull,
      );
      expect(
        messageFirstLink(
          _message(room, {
            'msgtype': MessageTypes.Text,
            'body': 'preview only',
            'com.beeper.linkpreviews': [
              {'matched_url': 'https://preview.invalid/x', 'og:title': 'T'},
            ],
          }),
        ),
        'https://preview.invalid/x',
      );
    });
  });
}
