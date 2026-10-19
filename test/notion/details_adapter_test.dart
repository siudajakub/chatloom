// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_adapter.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_page.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _LocalDatabase implements DatabaseApi {
  final List<Event> events = const [];
  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    int? limit,
    bool onlySending = false,
  }) async => events.skip(start).take(limit ?? 100).toList();
  @override
  Future<List<String>> getEventIdList(
    Room room, {
    int start = 0,
    int? limit,
    bool includeSending = false,
  }) async => [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Room extends Room {
  PushRuleState actual = PushRuleState.notify;
  final writes = <PushRuleState>[];
  bool fail = true;
  _Room({required super.id, required super.client})
    : super(membership: Membership.join);
  @override
  PushRuleState get pushRuleState => actual;
  @override
  Future<void> setPushRuleState(PushRuleState value) async {
    writes.add(value);
    if (fail) throw StateError('synthetic rule failure');
    actual = value;
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });
  testWidgets(
    'profile ignores unrelated sync and coalesces source state bursts',
    (tester) async {
      final client = Client(
        'fictional profile refresh',
        database: _LocalDatabase(),
      );
      final room = _Room(id: '!profile:example.invalid', client: client);
      client.rooms.add(room);
      final personal = PersonalClient.of(client);
      await tester.pumpWidget(
        MaterialApp(
          home: NotionLiveChatDetails(personal: personal, room: room),
        ),
      );
      await tester.pumpAndSettle();
      NotionChatDetailsPage page() =>
          tester.widget(find.byType(NotionChatDetailsPage));
      final before = page();
      client.onSync.add(
        SyncUpdate(
          nextBatch: 'unrelated',
          rooms: RoomsUpdate(
            join: {'!other:example.invalid': JoinedRoomUpdate()},
          ),
        ),
      );
      client.onRoomState.add((
        roomId: '!other:example.invalid',
        state: StrippedStateEvent(
          senderId: '@fixture:example.invalid',
          type: EventTypes.RoomName,
          content: {'name': 'Other fictional room'},
        ),
      ));
      await tester.pump(const Duration(milliseconds: 40));
      expect(page(), same(before));
      for (var i = 0; i < 30; i++) {
        client.onRoomState.add((
          roomId: room.id,
          state: StrippedStateEvent(
            senderId: '@fixture:example.invalid',
            type: EventTypes.RoomName,
            content: {'name': 'Fictional source'},
          ),
        ));
      }
      await tester.pump();
      expect(
        page(),
        same(before),
        reason: 'A source burst waits for one coalesced refresh',
      );
      await tester.pump(const Duration(milliseconds: 20));
      expect(page(), isNot(same(before)));
      final refreshed = page();
      await tester.pump(const Duration(milliseconds: 40));
      expect(page(), same(refreshed));
      // Disposal cancels a pending refresh rather than calling setState later.
      client.onRoomState.add((
        roomId: room.id,
        state: StrippedStateEvent(
          senderId: '@fixture:example.invalid',
          type: EventTypes.RoomName,
          content: {},
        ),
      ));
      await tester.pump();
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(milliseconds: 40));
      expect(tester.takeException(), isNull);
      personal.dispose();
    },
  );
  testWidgets(
    'explicit account notifications target the source and report native failure',
    (tester) async {
      final client = Client(
        'fictional details source',
        database: _LocalDatabase(),
      );
      final room = _Room(
        id: '!fictional-source:example.invalid',
        client: client,
      );
      client.rooms.add(room);
      room.setState(
        Event(
          room: room,
          type: EventTypes.RoomName,
          stateKey: '',
          content: {'name': 'Fictional source'},
          eventId: r'$fixture-name',
          senderId: '@fixture:example.invalid',
          originServerTs: DateTime.utc(2026),
        ),
      );
      final personal = PersonalClient.of(client);
      personal.values['nickname:${room.id}'] = {'name': 42};
      personal.pending['pending-private'] = PersonalOperation(
        opId: 'pending-private',
        kind: 'put',
        entityId: 'org:${room.id}',
        createdAt: DateTime.utc(2026),
        payload: {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NotionLiveChatDetails(personal: personal, room: room),
        ),
      );
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.scrollUntilVisible(
        find.text('Account notifications · Beeper / Matrix'),
        250,
      );
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.text('Account notifications · Beeper / Matrix')),
        alignment: .5,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Account notifications · Beeper / Matrix'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Muted').last);
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text(
          'Could not finish changing notifications. Check the current rule and try again.',
        ),
        -200,
      );
      await tester.pumpAndSettle();
      expect(room.writes, [PushRuleState.dontNotify]);
      expect(room.actual, PushRuleState.notify);
      expect(
        find.text(
          'Could not finish changing notifications. Check the current rule and try again.',
        ),
        findsOneWidget,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      personal.dispose();
    },
  );
  testWidgets(
    'merged adapter never applies native mute to a representative source',
    (tester) async {
      final client = Client(
        'fictional merged details',
        database: _LocalDatabase(),
      );
      final first = _Room(id: '!one:example.invalid', client: client);
      final second = _Room(id: '!two:example.invalid', client: client);
      client.rooms.addAll([first, second]);
      final personal = PersonalClient.of(client);
      final group = PersonGroup(
        id: 'fictional-person',
        name: 'Anna',
        members: const [
          ConversationRef(
            accountId: '@fictional:example.invalid',
            roomId: '!one:example.invalid',
            network: 'whatsapp',
          ),
          ConversationRef(
            accountId: '@fictional:example.invalid',
            roomId: '!two:example.invalid',
            network: 'telegram',
          ),
        ],
        defaultRoomId: first.id,
      );
      await tester.pumpWidget(
        MaterialApp(
          home: NotionLiveChatDetails(personal: personal, group: group),
        ),
      );
      await tester.pump();
      final choose = find.widgetWithText(TextButton, 'Choose a source');
      expect(tester.widget<TextButton>(choose).onPressed, isNotNull);
      await tester.tap(choose);
      await tester.pumpAndSettle();
      expect(
        find.text('Network settings apply only to the selected source.'),
        findsOneWidget,
      );
      expect(first.writes, isEmpty);
      expect(second.writes, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      personal.dispose();
    },
  );
}
