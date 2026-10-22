// SPDX-License-Identifier: AGPL-3.0-or-later
// The person page of a merged person (FT-22). Fictional offline fixtures:
// bridged one-to-one rooms, no account, store or network.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat_details/chat_details.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/person_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '@fixture:example.invalid';
const _bot = '@bridge:example.invalid';
const _peer = '@person:example.invalid';

class _LocalDatabase implements DatabaseApi {
  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    int? limit,
    bool onlySending = false,
  }) async => const [];
  @override
  Future<List<String>> getEventIdList(
    Room room, {
    int start = 0,
    int? limit,
    bool includeSending = false,
  }) async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends Client {
  _Client() : super('synthetic person page', database: _LocalDatabase());
  @override
  String get userID => _owner;
  @override
  Map<String, List<String>> get directChats => const {};
}

/// Native push rules must never be written from the person page.
class _Room extends Room {
  final ruleWrites = <PushRuleState>[];
  _Room({required super.id, required super.client})
    : super(membership: Membership.join);
  @override
  Future<void> setPushRuleState(PushRuleState value) async =>
      ruleWrites.add(value);
}

void _state(
  Room room,
  String type,
  Map<String, dynamic> content, {
  String key = '',
  String sender = _bot,
}) => room.setState(
  Event(
    room: room,
    type: type,
    stateKey: key,
    content: content,
    senderId: sender,
    eventId: '\$fixture-$type-$key',
    originServerTs: DateTime.utc(2026),
  ),
);

_Room _room(_Client client, String id, String network) {
  final room = _Room(id: '!$id:example.invalid', client: client);
  client.rooms.add(room);
  _state(room, EventTypes.RoomName, {'name': 'Fictional $id'});
  _state(room, 'm.bridge', {
    'bridgebot': _bot,
    'protocol': {'id': network},
    'com.beeper.room_type.v2': 'dm',
  }, key: 'fixture');
  for (final member in [_owner, _bot, _peer]) {
    _state(room, EventTypes.RoomMember, {'membership': 'join'}, key: member);
  }
  room.summary.mJoinedMemberCount = 3;
  room.summary.mInvitedMemberCount = 0;
  return room;
}

class _Private extends PersonalClient {
  _Private(super.client)
    : super.forTesting(
        openStore: () async => throw StateError('No fixture files'),
      );
  @override
  bool get ready => true;
  @override
  Future<void> load() async {}
  @override
  Future<void> loadLocal() async {}
  final writes = <String>[];
  @override
  Future<void> put(String key, Map<String, dynamic> value) async {
    writes.add(key);
    values[key] = value;
    notifyListeners();
  }

  @override
  Future<void> delete(String key) async {
    writes.add('delete $key');
    values.remove(key);
    notifyListeners();
  }
}

class _Matrix extends MatrixState {
  Client active;
  _Matrix(this.active);
  @override
  Client get client => active;
  @override
  Matrix get widget => Matrix(clients: [active], store: AppSettings.store);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  late _Client client;
  late _Room whatsapp, telegram;
  late _Private personal;
  late PersonGroup group;

  setUp(() {
    client = _Client();
    whatsapp = _room(client, 'wa', 'whatsapp');
    telegram = _room(client, 'tg', 'telegram');
    personal = _Private(client);
    group = PersonGroup(
      id: 'person',
      name: 'Fictional person',
      members: [personal.ref(whatsapp), personal.ref(telegram)],
      defaultRoomId: whatsapp.id,
    );
    personal.values['person:person'] = group.toJson().cast<String, dynamic>();
  });
  tearDown(() => personal.dispose());

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      Provider<MatrixState>.value(
        value: _Matrix(client),
        child: MaterialApp(
          theme: NotionTheme.build(Brightness.dark),
          home: PersonPage(personal: personal, group: group),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tapRow(WidgetTester tester, String title) async {
    final row = find.widgetWithText(NotionListRow, title).first;
    // Centred: rows scroll under the glass header.
    await Scrollable.ensureVisible(tester.element(row), alignment: .5);
    await tester.pumpAndSettle();
    await tester.tap(row);
    await tester.pumpAndSettle();
  }

  testWidgets('one page: name, chats, routing, notifications', (tester) async {
    await mount(tester);
    expect(find.text('Fictional person'), findsOneWidget);
    expect(find.text('Chats'), findsOneWidget);
    expect(find.text('Default'), findsOneWidget);

    // Person-level notifications: private, never a native source page.
    await tapRow(tester, 'Notifications');
    expect(find.byType(ChatDetails), findsNothing);
    await tester.tap(find.text('Muted').last);
    await tester.pumpAndSettle();
    expect(
      personal.values['org:person:person']?['notificationMode'],
      PersonalNotificationMode.muted.name,
    );
    expect(whatsapp.ruleWrites, isEmpty);
    expect(telegram.ruleWrites, isEmpty);

    // "Always Telegram".
    await tapRow(tester, 'Send messages via');
    await tester.tap(find.text('Always Telegram'));
    await tester.pumpAndSettle();
    expect(personal.values['person-prefs:person']?['routing'], 'fixed');
    expect(personal.groups.single.defaultRoomId, telegram.id);
    // Older builds' group JSON carries no new field.
    expect(
      personal.values['person:person']!.keys.toSet(),
      {'id', 'name', 'members', 'defaultRoomId', 'revision'},
    );

    // The name of a network, live.
    await tapRow(tester, 'Name');
    await tester.tap(find.text('Use Telegram name'));
    await tester.pumpAndSettle();
    expect(find.text('Fictional tg'), findsWidgets);
    expect(personal.values['person-prefs:person']?['nameRoomId'], telegram.id);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a left chat stays listed with Remove and Undo', (tester) async {
    client.rooms.remove(telegram);
    final signal = _room(client, 'sig', 'signal');
    group = PersonGroup(
      id: 'person',
      name: 'Fictional person',
      members: [
        personal.ref(whatsapp),
        personal.ref(telegram),
        personal.ref(signal),
      ],
      defaultRoomId: whatsapp.id,
    );
    personal.values['person:person'] = group.toJson().cast<String, dynamic>();
    await mount(tester);
    expect(find.text('Left or deleted'), findsOneWidget);
    expect(
      find.text('The Telegram chat is no longer available'),
      findsOneWidget,
    );
    await tapRow(tester, 'Telegram');
    expect(find.text('Replace with another chat…'), findsOneWidget);
    await tester.tap(find.text('Remove from merged chat'));
    await tester.pumpAndSettle();
    expect(
      personal.groups.single.members.map((m) => m.roomId),
      [whatsapp.id, signal.id],
    );
    expect(find.text('Left or deleted'), findsNothing);
    await tester.tap(find.text('Undo'));
    await tester.pumpAndSettle();
    expect(personal.groups.single.members, hasLength(3));
    expect(tester.takeException(), isNull);
  });
}
