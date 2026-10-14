// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/ui/notion_chat_details_adapter.dart';
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
    'ordinary adapter mute targets its source and reports native failure',
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
      await tester.tap(find.text('Mute'));
      await tester.pump();
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
