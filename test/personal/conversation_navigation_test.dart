// SPDX-License-Identifier: AGPL-3.0-or-later
// Moving around a conversation (FX-06, FX-10, FX-11): a busy chat opens at
// its first unread message also when the read marker is far back, the read
// marker is never held back by the fallback, the merged chat opens at its
// divider, unread mentions and jump to date. Fictional offline fixtures.
import 'dart:io';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/conversation_navigation.dart';
import 'package:chatloom/personal/merged_chat_page.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

/// A timeline whose history and future requests are recorded, not sent.
class _Timeline extends ConversationTimeline {
  int historyRequests = 0, futureRequests = 0;
  _Timeline({required super.room, required super.chunk, super.onUpdate});

  @override
  Future<void> requestHistory({
    int historyCount = Room.defaultHistoryCount,
    StateFilter? filter,
  }) async => historyRequests++;

  @override
  Future<void> requestFuture({
    int historyCount = Room.defaultHistoryCount,
    StateFilter? filter,
  }) async => futureRequests++;
}

/// The live timeline holds the newest [live] messages; the context around
/// the read marker holds the marker and everything after it.
class _BusyRoom extends ConversationRoom {
  final int live = 30;
  Object? contextFailure;
  final loads = <String?>[];
  final readMarkers = <String?>[];
  _Timeline? timeline;
  _BusyRoom(super.client, super.id);

  @override
  Future<Timeline> getTimeline({
    void Function(int)? onChange,
    void Function(int)? onRemove,
    void Function(int)? onInsert,
    void Function()? onNewEvent,
    void Function()? onUpdate,
    String? eventContextId,
    int? limit = Room.defaultHistoryCount,
  }) async {
    loads.add(eventContextId);
    if (eventContextId != null) {
      final failure = contextFailure;
      if (failure != null) throw failure;
      final at = sourceEvents.indexWhere((e) => e.eventId == eventContextId);
      final context = _Timeline(
        room: this,
        chunk: TimelineChunk(
          events: sourceEvents.sublist(
            0,
            at + 5 > sourceEvents.length ? sourceEvents.length : at + 5,
          ),
        ),
        onUpdate: onUpdate,
      )..allowNewEvent = false;
      return timeline = context;
    }
    return timeline = _Timeline(
      room: this,
      chunk: TimelineChunk(events: sourceEvents.sublist(0, live)),
      onUpdate: onUpdate,
    );
  }

  @override
  Future<void> setReadMarker(
    String? eventId, {
    String? mRead,
    bool? public,
  }) async => readMarkers.add(eventId);
}

Future<void> _mount(WidgetTester tester, Client client, Widget home) async {
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
        home: home,
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _unmount(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpAndSettle();
}

Event _at(ConversationRoom room, String id, String text, DateTime at) {
  final event = Event(
    room: room,
    eventId: id,
    type: EventTypes.Message,
    senderId: '@anna:example.invalid',
    originServerTs: at,
    content: {'msgtype': MessageTypes.Text, 'body': text},
  );
  room.sourceEvents.insert(0, event);
  return event;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  late ConversationClient client;
  late ConversationPersonal personal;

  setUp(() {
    client = ConversationClient();
    personal = ConversationPersonal(client);
    PersonalClient.debugUse(client, personal);
  });
  tearDown(() => personal.dispose());

  group('FX-06 busy chats open at the first unread', () {
    late _BusyRoom room;

    setUp(() {
      room = _BusyRoom(client, '!busy:example.invalid');
      // 0–59: 0–9 read, 10–59 unread; the live page holds only 30–59.
      for (var i = 0; i < 60; i++) {
        room.message('\$busy-$i', 'Fictional message $i', minute: i % 60);
      }
      room.lastEvent = room.sourceEvents.first;
      room.roomAccountData['m.fully_read'] = BasicEvent(
        type: 'm.fully_read',
        content: {'event_id': r'$busy-9'},
      );
    });

    testWidgets('a marker beyond the first page loads its context', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await _mount(tester, client, ChatPage(roomId: room.id));
      final controller = tester.state<ChatController>(
        find.byType(ChatPageWithRoom),
      );
      // Live page first, then the history around the read marker.
      expect(room.loads, [null, r'$busy-9']);
      expect(controller.timelineHold.value, isFalse);
      expect(controller.scrollUpBannerEventId, isNull);
      final divider = find.text('50 unread messages');
      expect(divider, findsOneWidget);
      final header = tester.getBottomLeft(find.byType(AppBar)).dy;
      final top = tester.getTopLeft(divider).dy;
      expect(top, greaterThan(header));
      expect(top, lessThan(header + 48));
      expect(controller.newBelow.value, 50);
      expect(controller.jumpButtonVisible.value, isTrue);
      // No banner: the Notion "First unread" button is not needed either.
      expect(find.text('First unread'), findsNothing);

      // Positioning never loaded newer messages by itself...
      expect(room.timeline!.futureRequests, 0);
      // ...reading down to the newest loaded row does.
      await tester.drag(find.byType(ListView).first, const Offset(0, -6000));
      await tester.pumpAndSettle();
      expect(room.timeline!.futureRequests, greaterThan(0));
      await _unmount(tester);
    });

    testWidgets('a failed context keeps the chat usable and marks it read', (
      tester,
    ) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      // Receipts are on (incognito, the default, never sends them).
      await AppSettings.personalIncognito.setItem(false);
      addTearDown(() => AppSettings.personalIncognito.setItem(true));
      room.contextFailure = const SocketException('fixture offline');
      await _mount(tester, client, ChatPage(roomId: room.id));
      final controller = tester.state<ChatController>(
        find.byType(ChatPageWithRoom),
      );
      // The live timeline stays, the Notion button offers the way up.
      expect(controller.scrollUpBannerEventId, r'$busy-9');
      expect(
        find.byKey(const ValueKey('conversation-first-unread')),
        findsOneWidget,
      );
      expect(find.text('Jump to last read message'), findsNothing);
      // At the newest message the read marker is set (FluffyChat held it
      // back while its banner showed).
      expect(room.readMarkers, isNotEmpty);
      await _unmount(tester);
    });
  });

  group('FX-10 merged chat', () {
    testWidgets('opens with the unread divider under the header', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final a = ConversationRoom(client, '!merged-a:example.invalid');
      final b = ConversationRoom(
        client,
        '!merged-b:example.invalid',
        network: 'messenger',
      );
      for (var i = 0; i < 40; i++) {
        a.message('\$a-$i', 'Fictional merged $i', minute: i);
      }
      b.message(r'$b-0', 'Messenger fictional', minute: 0);
      a.lastEvent = a.sourceEvents.first;
      a.roomAccountData['m.fully_read'] = BasicEvent(
        type: 'm.fully_read',
        content: {'event_id': r'$a-9'},
      );
      final group = PersonGroup(
        id: 'merged-person',
        name: 'Anna',
        members: [personal.ref(a), personal.ref(b)],
        defaultRoomId: a.id,
      );
      await _mount(
        tester,
        client,
        MergedChatPage(personal: personal, group: group),
      );
      final divider = find.text('30 unread messages');
      expect(divider, findsOneWidget);
      final header = tester.getBottomLeft(find.byType(AppBar)).dy;
      final top = tester.getTopLeft(divider).dy;
      expect(top, greaterThan(header));
      expect(top, lessThan(header + 48));
      // The jump button counts what is below.
      expect(find.text('30'), findsOneWidget);
      await _unmount(tester);
    });
  });

  group('FX-11 unread mentions', () {
    test('oldest unread highlighted message first, skipping handled', () {
      final room = ConversationRoom(client, '!mentions:example.invalid');
      for (var i = 0; i < 10; i++) {
        room.message(
          '\$m-$i',
          i.isOdd ? 'hey @owner $i' : 'plain $i',
          minute: i,
        );
      }
      room.message(r'$own', '@owner own', outgoing: true, minute: 11);
      final rows = room.sourceEvents;
      bool mention(Event e) => e.body.contains('@owner');
      // Rows are newest first; the marker row is "plain 4".
      final marker = rows.indexWhere((e) => e.eventId == r'$m-4');
      final unread = conversationUnreadMentions(
        rows,
        marker,
        highlighted: mention,
      );
      expect(unread.map((e) => e.eventId), [r'$m-5', r'$m-7', r'$m-9']);
      expect(
        conversationUnreadMentions(
          rows,
          marker,
          highlighted: mention,
          handled: {r'$m-5'},
        ).first.eventId,
        r'$m-7',
      );
      // Marker not loaded: every loaded row counts.
      expect(
        conversationUnreadMentions(rows, -1, highlighted: mention),
        hasLength(5),
      );
    });

    testWidgets('the @ button counts the server highlights minus visits', (
      tester,
    ) async {
      final room = ConversationRoom(client, '!at:example.invalid')
        ..highlightCount = 2;
      final handled = ValueNotifier(0);
      addTearDown(handled.dispose);
      var taps = 0;
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Scaffold(
            body: Center(
              child: ConversationMentionButton(
                rooms: [room],
                handled: handled,
                onPressed: () => taps++,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('2'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('conversation-mention')));
      expect(taps, 1);
      handled.value = 1;
      await tester.pumpAndSettle();
      expect(find.text('1'), findsOneWidget);
      handled.value = 2;
      await tester.pumpAndSettle();
      expect(conversationMentionCount([room], 2), 0);
      expect(
        tester
            .widget<ExcludeSemantics>(
              find
                  .ancestor(
                    of: find.byType(NotionSizeReveal),
                    matching: find.byType(ExcludeSemantics),
                  )
                  .first,
            )
            .excluding,
        isTrue,
      );
    });
  });

  group('FX-11 jump to date', () {
    test('the oldest row on or after the day', () {
      final room = ConversationRoom(client, '!days:example.invalid');
      _at(room, r'$d1', 'one', DateTime(2026, 10, 1, 9));
      _at(room, r'$d3a', 'three a', DateTime(2026, 10, 3, 8));
      _at(room, r'$d3b', 'three b', DateTime(2026, 10, 3, 20));
      _at(room, r'$d5', 'five', DateTime(2026, 10, 5, 12));
      final rows = room.sourceEvents;
      String? on(DateTime day) {
        final i = conversationRowForDay(rows, day);
        return i < 0 ? null : rows[i].eventId;
      }

      expect(on(DateTime(2026, 10, 3)), r'$d3a');
      // A day without messages lands on the next one.
      expect(on(DateTime(2026, 10, 4)), r'$d5');
      expect(on(DateTime(2026, 9, 1)), r'$d1');
      expect(on(DateTime(2026, 10, 6)), isNull);
      expect(conversationRowsReachDay(rows, DateTime(2026, 10, 3)), isTrue);
      expect(conversationRowsReachDay(rows, DateTime(2026, 10, 1)), isFalse);
    });

    testWidgets('a picked day puts its first message under the header', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final room = ConversationRoom(client, '!jump-days:example.invalid');
      for (var day = 1; day <= 6; day++) {
        for (var i = 0; i < 6; i++) {
          _at(
            room,
            '\$day$day-$i',
            'Day $day message $i',
            DateTime(2026, 10, day, 9, i),
          );
        }
      }
      await _mount(tester, client, ChatPage(roomId: room.id));
      final controller = tester.state<ChatController>(
        find.byType(ChatPageWithRoom),
      );
      expect(controller.scrollController.position.pixels, 0);
      // The jump waits for frames; the tester pumps them.
      var done = false;
      controller
          .jumpToDay(DateTime(2026, 10, 2))
          .whenComplete(() => done = true);
      for (var i = 0; i < 60 && !done; i++) {
        await tester.pump(const Duration(milliseconds: 50));
      }
      expect(done, isTrue);
      await tester.pumpAndSettle();
      // Taken from the loaded rows: no snackbar about a missing day.
      expect(find.text('Couldn’t load messages from that day.'), findsNothing);
      final header = tester.getBottomLeft(find.byType(AppBar)).dy;
      final first = tester.getTopLeft(find.text('Day 2 message 0')).dy;
      expect(first, greaterThan(header));
      expect(first, lessThan(header + 96));
      await _unmount(tester);
    });

    testWidgets('the Notion date picker returns the tapped day', (
      tester,
    ) async {
      DateTime? picked;
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => picked = await showNotionDatePicker(
                  context: context,
                  initialDate: DateTime(2026, 10, 16),
                  firstDate: DateTime(2026),
                  lastDate: DateTime(2026, 10, 23),
                ),
                child: const Text('Pick'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Pick'));
      await tester.pumpAndSettle();
      expect(find.text('Jump to date'), findsOneWidget);
      await tester.tap(find.text('12'));
      await tester.pumpAndSettle();
      expect(picked, DateTime(2026, 10, 12));
      expect(find.text('Jump to date'), findsNothing);
    });
  });
}
