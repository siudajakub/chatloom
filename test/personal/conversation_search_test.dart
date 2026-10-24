// SPDX-License-Identifier: AGPL-3.0-or-later
// In-chat search (FX-03) and the device message search (FX-04 option A):
// stepping "3 of 17", stored pages, edits and cancellation, and the search
// mode of an open chat (no second chat page). Fictional offline fixtures.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/conversation_search.dart';
import 'package:chatloom/personal/local_message_search.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

Event _edit(
  ConversationRoom room,
  String id,
  String target,
  String text, {
  int minute = 50,
}) => Event(
  room: room,
  eventId: id,
  type: EventTypes.Message,
  senderId: '@anna:example.invalid',
  originServerTs: DateTime.utc(2026, 10, 16, 16, minute),
  content: {
    'msgtype': MessageTypes.Text,
    'body': '* $text',
    'm.new_content': {'msgtype': MessageTypes.Text, 'body': text},
    'm.relates_to': {'rel_type': RelationshipTypes.edit, 'event_id': target},
  },
);

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  late ConversationClient client;
  late ConversationRoom room;

  setUp(() {
    client = ConversationClient();
    room = ConversationRoom(client, '!search:example.invalid');
  });

  group('matching', () {
    test('folds case and diacritics, every word must occur', () {
      final terms = localSearchTerms('lukasz  KAWA');
      expect(terms, ['lukasz', 'kawa']);
      expect(localTextMatches('lukasz pije kawe i kawa', terms), isTrue);
      expect(localTextMatches('lukasz pije herbate', terms), isFalse);
      expect(localTextMatches('anything', const []), isFalse);
    });

    test('match ranges index the original text', () {
      const text = 'Łukasz said ŁUKASZ';
      final ranges = localMatchRanges(text, localSearchTerms('lukasz'));
      expect(ranges, [(0, 6), (12, 18)]);
      expect(text.substring(ranges.first.$1, ranges.first.$2), 'Łukasz');
    });

    test('a long message is cut in front of its first match', () {
      final text = '${List.filled(20, 'filler').join(' ')} the apple pie';
      final snippet = localSnippet(text, localSearchTerms('apple'));
      expect(snippet.startsWith('…'), isTrue);
      expect(snippet, contains('apple pie'));
      expect(
        localSnippet('apple first', localSearchTerms('apple')),
        'apple first',
      );
    });
  });

  group('pool', () {
    test('an edit replaces the text; redactions and non-messages drop', () {
      final original = room.message(r'$m1', 'grocery list', minute: 1);
      final pool = LocalMessagePool()
        ..add([
          original,
          _edit(room, r'$e1', r'$m1', 'apple shopping list'),
          room.message(r'$m2', 'apple pie', minute: 2),
        ]);
      final hits = pool.search(localSearchTerms('apple'));
      expect(hits.map((h) => h.eventId), [r'$m2', r'$m1']);
      expect(hits.last.text, 'apple shopping list');
      expect(pool.search(localSearchTerms('grocery')), isEmpty);
      // An edit of a message that is not stored has no row to jump to.
      pool.add([_edit(room, r'$e9', r'$missing', 'apple elsewhere')]);
      expect(pool.search(localSearchTerms('elsewhere')), isEmpty);
    });

    test('compact device copies keep the latest edit only', () {
      final events = [
        _edit(room, r'$e2', r'$m1', 'second apple', minute: 59),
        _edit(room, r'$e1', r'$m1', 'first apple', minute: 55),
        room.message(r'$m1', 'original', minute: 1),
      ];
      final compact = compactMessages(events);
      expect(compact, hasLength(1));
      expect(compact.single.$2.text, 'second apple');
      expect(compact.single.$2.eventId, r'$m1');
    });
  });

  group('ConversationSearchController stepping', () {
    late List<Event> loaded;
    late List<String> jumped;
    late ConversationSearchController search;

    setUp(() {
      loaded = [
        for (var i = 0; i < 20; i++)
          room.message(
            '\$l$i',
            i.isEven ? 'apple number $i' : 'pear $i',
            minute: i,
          ),
      ];
      jumped = [];
      search = ConversationSearchController(
        rooms: () => [room],
        loaded: () => loaded,
        jump: (event) async => jumped.add(event.eventId),
        // Stored history: one older page with seven more apples.
        read: (room, start, limit) async => start > 0
            ? const []
            : [
                for (var i = 0; i < 7; i++)
                  Event(
                    room: room,
                    eventId: '\$s$i',
                    type: EventTypes.Message,
                    senderId: '@anna:example.invalid',
                    originServerTs: DateTime.utc(2026, 10, 15, 10, i),
                    content: {
                      'msgtype': MessageTypes.Text,
                      'body': 'apple old $i',
                    },
                  ),
              ],
      );
    });
    tearDown(() => search.dispose());

    test('counts, steps older and newer and jumps each time', () async {
      search.open();
      await pumpEventQueue();
      expect(search.storeComplete, isTrue);
      search.setQuery('APPLE');
      expect(search.hits, hasLength(17));
      expect(search.status, '17 results');
      expect(search.listOpen, isTrue);
      expect(search.canStepNewer, isFalse);

      search.submit();
      expect(search.status, '1 of 17');
      expect(search.listOpen, isFalse);
      expect(jumped, [r'$l18']);

      search.stepOlder();
      search.stepOlder();
      expect(search.status, '3 of 17');
      expect(jumped.last, r'$l14');
      search.stepNewer();
      expect(search.status, '2 of 17');
      expect(jumped.last, r'$l16');

      search.select(16);
      expect(search.status, '17 of 17');
      expect(search.canStepOlder, isFalse);
      // The oldest stored hit (from the encrypted store, not the timeline).
      expect(jumped.last, r'$s0');
    });

    test('a hit arriving later keeps the current one', () async {
      search.open();
      search.setQuery('apple');
      search.submit();
      final current = search.current!.eventId;
      await pumpEventQueue();
      expect(search.current!.eventId, current);
      expect(search.hits, hasLength(17));
    });

    test('closing forgets the query and the stored pages', () async {
      search.open();
      await pumpEventQueue();
      search.setQuery('apple');
      search.close();
      expect(search.active, isFalse);
      expect(search.hits, isEmpty);
      expect(search.text.text, isEmpty);
      expect(search.status, '');
    });

    test('a store that cannot be read still searches the timeline', () async {
      final failing = ConversationSearchController(
        rooms: () => [room],
        loaded: () => loaded,
        jump: (_) async {},
        read: (_, _, _) async => throw StateError('fixture store'),
      );
      addTearDown(failing.dispose);
      failing.open();
      await pumpEventQueue();
      failing.setQuery('apple');
      expect(failing.storeFailed, isTrue);
      expect(failing.hits, hasLength(10));
    });

    test('older messages load only on request', () async {
      var serverPages = 0;
      room.prev_batch = 'fixture-token';
      final remote = ConversationSearchController(
        rooms: () => [room],
        loaded: () => loaded,
        jump: (_) async {},
        read: (_, _, _) async => const [],
        older: (room, cursor) async {
          serverPages++;
          return (
            events: [
              Event(
                room: room,
                eventId: r'$server',
                type: EventTypes.Message,
                senderId: '@anna:example.invalid',
                originServerTs: DateTime.utc(2025),
                content: {'msgtype': MessageTypes.Text, 'body': 'apple 2025'},
              ),
            ],
            next: null,
          );
        },
      );
      addTearDown(remote.dispose);
      remote.open();
      await pumpEventQueue();
      remote.setQuery('apple');
      expect(serverPages, 0);
      expect(remote.canSearchOlder, isTrue);
      await remote.searchOlder();
      expect(serverPages, 1);
      expect(remote.hits.last.eventId, r'$server');
      expect(remote.canSearchOlder, isFalse);
    });
  });

  group('DeviceMessageSearch', () {
    test('reads each room once and filters per query', () async {
      final other = ConversationRoom(client, '!other:example.invalid');
      final reads = <String>[];
      final device = DeviceMessageSearch(
        rooms: () => [room, other],
        read: (r, start, limit) async {
          reads.add(r.id);
          return r == room
              ? [
                  room.message(r'$a', 'apple in the first chat', minute: 5),
                  room.message(r'$b', 'banana', minute: 4),
                ]
              : [other.message(r'$c', 'Apple in the other', minute: 9)];
        },
        yieldSlice: () async {},
        sliceSize: 1,
      );
      addTearDown(device.dispose);
      device.search('apple');
      expect(device.searching, isTrue);
      await pumpEventQueue();
      expect(device.searching, isFalse);
      expect(device.hits.map((h) => h.eventId), [r'$c', r'$a']);
      device.search('banana');
      await pumpEventQueue();
      expect(device.hits.single.eventId, r'$b');
      expect(reads, [room.id, other.id]);
    });

    test('a newer query cancels the running one', () async {
      final gate = Completer<void>();
      final device = DeviceMessageSearch(
        rooms: () => [room],
        read: (r, start, limit) async {
          await gate.future;
          return [room.message(r'$a', 'apple banana', minute: 5)];
        },
        yieldSlice: () async {},
      );
      addTearDown(device.dispose);
      device.search('apple');
      device.search('cherry');
      gate.complete();
      await pumpEventQueue();
      expect(device.query, 'cherry');
      expect(device.hits, isEmpty);
      expect(device.searching, isFalse);
    });

    test('a room whose store fails is skipped', () async {
      final other = ConversationRoom(client, '!other:example.invalid');
      final device = DeviceMessageSearch(
        rooms: () => [room, other],
        read: (r, start, limit) async {
          if (r == room) throw StateError('fixture store');
          return [other.message(r'$c', 'apple', minute: 9)];
        },
        yieldSlice: () async {},
      );
      addTearDown(device.dispose);
      device.search('apple');
      await pumpEventQueue();
      expect(device.hits.single.eventId, r'$c');
    });
  });

  group('search mode in the chat', () {
    late ConversationPersonal personal;

    setUp(() {
      for (var i = 0; i < 30; i++) {
        room.message(
          '\$chat-$i',
          i % 10 == 3 ? 'Fictional apple $i' : 'Fictional message $i',
          minute: i,
        );
      }
      personal = ConversationPersonal(client);
      PersonalClient.debugUse(client, personal);
    });
    tearDown(() => personal.dispose());

    Future<ChatController> mount(WidgetTester tester) async {
      final state = ConversationMatrix(
        client,
        await SharedPreferences.getInstance(),
      );
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: state,
          child: MaterialApp(
            localizationsDelegates: L10n.localizationsDelegates,
            supportedLocales: L10n.supportedLocales,
            home: ChatPage(roomId: room.id),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return tester.state<ChatController>(find.byType(ChatPageWithRoom));
    }

    testWidgets('the header becomes the field and steps in place', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final controller = await mount(tester);
      controller.openSearch();
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey('conversation-search-field')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('conversation-search-bar')),
        findsOneWidget,
      );
      // The composer stays mounted but is not shown.
      expect(find.byType(Offstage), findsWidgets);

      await tester.enterText(
        find.byKey(const ValueKey('conversation-search-field')),
        'apple',
      );
      await tester.pumpAndSettle();
      expect(find.text('3 results'), findsOneWidget);
      // The results list: sender and the matched words.
      expect(find.byType(ConversationSearchResultRow), findsNWidgets(3));

      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pumpAndSettle();
      expect(find.text('1 of 3'), findsOneWidget);
      expect(find.byType(ConversationSearchResultRow), findsNothing);

      await tester.tap(find.byKey(const ValueKey('conversation-search-older')));
      await tester.pumpAndSettle();
      expect(find.text('2 of 3'), findsOneWidget);
      // Still one chat page with one timeline.
      expect(find.byType(ChatPageWithRoom), findsOneWidget);
      expect(find.text('Fictional apple 13'), findsOneWidget);

      // Back leaves the search, not the chat.
      await tester.tap(find.byTooltip('Close search'));
      await tester.pumpAndSettle();
      expect(controller.searchActive, isFalse);
      expect(find.byType(ChatPageWithRoom), findsOneWidget);
      expect(
        find.byKey(const ValueKey('conversation-search-field')),
        findsNothing,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('Escape in the field closes the search', (tester) async {
      final controller = await mount(tester);
      controller.openSearch();
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(controller.searchActive, isFalse);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('the ⋯ menu entry opens the same search mode', (tester) async {
      final controller = await mount(tester);
      final context = tester.element(find.byTooltip('Conversation options'));
      expect(ConversationSearchScope.maybeOpen(context), isTrue);
      await tester.pumpAndSettle();
      expect(controller.searchActive, isTrue);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });
}
