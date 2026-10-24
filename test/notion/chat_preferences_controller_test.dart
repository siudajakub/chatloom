// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:io';
import 'dart:ui' as ui;

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/notification_eligibility.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/chat_preferences_page.dart';
import 'package:chatloom/personal/ui/notion_inbox_page.dart';
import 'package:chatloom/personal/ui/notion_network_adapter.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

const owner = '@fixture:example.invalid';
const bot = '@bridge:example.invalid';
const peer = '@person:example.invalid';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected I/O');
}

class _Client extends Client {
  _Client() : super('synthetic chat rules', database: _NoDatabase());
  @override
  String get userID => owner;
  final direct = <String, List<String>>{};
  @override
  Map<String, List<String>> get directChats => direct;
}

class _Room extends Room {
  final writes = <PushRuleState>[];
  _Room({required super.id, required super.client})
    : super(membership: Membership.join);
  @override
  PushRuleState get pushRuleState => PushRuleState.notify;
  @override
  Future<void> setPushRuleState(PushRuleState state) async {
    writes.add(state);
  }
}

void state(
  Room room,
  String type,
  Map<String, dynamic> content, {
  String key = '',
}) => room.setState(
  Event(
    room: room,
    type: type,
    stateKey: key,
    content: content,
    senderId: bot,
    eventId: '\$fixture-$type-$key',
    originServerTs: DateTime.utc(2026),
  ),
);

_Room room(
  _Client client,
  String id, {
  String? network = 'telegram',
  String kind = 'dm',
  bool technical = false,
  String? protocolName,
}) {
  final result = _Room(id: '!$id:example.invalid', client: client);
  client.rooms.add(result);
  state(result, EventTypes.RoomName, {
    'name': technical ? 'Bridge control' : 'Fictional $id',
  });
  if (network != null)
    state(result, 'm.bridge', {
      'bridgebot': bot,
      'protocol': {'id': network, 'displayname': ?protocolName},
      'com.beeper.room_type.v2': kind,
    });
  final members = [owner, bot, if (!technical) peer];
  for (final id in members)
    state(result, EventTypes.RoomMember, {'membership': 'join'}, key: id);
  result.summary.mJoinedMemberCount = members.length;
  result.summary.mInvitedMemberCount = 0;
  return result;
}

// Presentation adapter only; durable replica/ACK/conflict behavior has separate core tests.
class _Private extends PersonalClient {
  _Private(super.client)
    : super.forTesting(
        openStore: () async => throw StateError('No fixture files'),
      );
  bool available = true;
  @override
  bool get ready => available;
  @override
  Future<void> load() async {}
  final writes = <String>[];
  @override
  Future<void> put(String key, Map<String, dynamic> value) async {
    writes.add(key);
    pending['synthetic:$key'] = PersonalOperation(
      opId: 'synthetic:$key',
      kind: 'metadata.put',
      entityId: key,
      payload: {'value': value},
      createdAt: DateTime.utc(2026),
    );
    values[key] = value;
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

Widget host(Widget page, _Matrix matrix, {double scale = 1}) =>
    Provider<MatrixState>.value(
      value: matrix,
      child: RepaintBoundary(
        key: const Key('rules-capture'),
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: NotionTheme.build(Brightness.dark),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: Material(child: page),
        ),
      ),
    );

Future<void> capture(WidgetTester tester, String name) async {
  final directory = Platform.environment['CHAT_RULES_CAPTURE_DIR'];
  if (directory == null) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const Key('rules-capture')),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1.5);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    final file = File('$directory/$name.png');
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes!.buffer.asUint8List());
    image.dispose();
  });
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    final fonts = FontLoader('Roboto');
    for (final weight in ['Regular', 'Medium', 'Bold']) {
      fonts.addFont(rootBundle.load('assets/notion/fonts/Roboto-$weight.ttf'));
    }
    await fonts.load();
    final icons = Platform.environment['CHAT_RULES_ICON_FONT'];
    if (icons != null) {
      final loader = FontLoader('MaterialIcons')
        ..addFont(
          Future.value(ByteData.sublistView(await File(icons).readAsBytes())),
        );
      await loader.load();
    }
  });

  test(
    'canonical networks use protocol metadata; bot-only rooms are technical',
    () {
      final client = _Client();
      for (final entry in {
        'facebookgo': 'messenger',
        'instagramgo': 'instagram',
        'telegram': 'telegram',
      }.entries) {
        final source = room(client, entry.key, network: entry.key);
        expect(
          ConversationClassifier(client.rooms).classify(source).network,
          entry.value,
        );
      }
      final uuid = room(
        client,
        'uuid',
        network: '14b39324-4df5-4e33-9d61-b7924571f23d',
        protocolName: 'Slack',
      );
      final unresolved = room(client, 'unknown', network: 'unknown-instance');
      final matrix = room(client, 'matrix', network: null);
      final technical = room(client, 'control', technical: true);
      final classifier = ConversationClassifier(client.rooms);
      expect(classifier.classify(uuid).network, 'slack');
      expect(classifier.classify(unresolved).network, 'other');
      expect(classifier.classify(matrix).network, 'matrix');
      expect(classifier.classify(technical).technical, isTrue);
      state(uuid, EventTypes.RoomName, {'name': 'Telegram bridge bot'});
      expect(classifier.classify(uuid).technical, isFalse);
    },
  );

  test(
    'Telegram groups stay separate through drafts, new activity and due reminders; a pin keeps them on the main list',
    () {
      final client = _Client();
      final direct = room(client, 'direct');
      final group = room(client, 'group', kind: 'group');
      final technical = room(client, 'control', technical: true);
      final personal = _Private(client);
      addTearDown(personal.dispose);
      // Telegram groups are off the Groups view until the network allows it.
      personal.values['network-policy:telegram'] = {'showInGroups': true};
      personal.values['org:${group.id}'] = {'pinOrder': 0};
      personal.values['draft:${group.id}'] = {'text': 'Fictional draft'};
      personal.reminders['fixture-reminder'] = {
        'state': 'done',
        'conversation': personal.ref(group).toJson(),
        'dueAt': DateTime.utc(2026, 10, 16).toIso8601String(),
      };
      expect(InboxProjection(personal).rooms(client.rooms), [group, direct]);
      personal.values.remove('org:${group.id}');
      expect(InboxProjection(personal).rooms(client.rooms), [direct]);
      expect(
        InboxProjection(
          personal,
        ).rooms(client.rooms, filter: InboxFilter.groups),
        [group],
      );
      expect(
        InboxProjection(
          personal,
        ).rooms(client.rooms, filter: InboxFilter.technical),
        [technical],
      );
      group.lastEvent = Event(
        room: group,
        type: EventTypes.Message,
        eventId: r'$new',
        senderId: peer,
        originServerTs: DateTime.utc(2026, 10, 17),
        content: {'body': 'Fictional activity'},
      );
      expect(InboxProjection(personal).rooms(client.rooms), [direct]);
      personal.values['org:${group.id}'] = {'placement': 'inbox'};
      expect(InboxProjection(personal).rooms(client.rooms), contains(group));
      personal.values['org:${group.id}'] = {
        'placement': 'inbox',
        'ignored': true,
        'pinOrder': 0,
      };
      for (final filter in [
        InboxFilter.inbox,
        InboxFilter.unread,
        InboxFilter.drafts,
        InboxFilter.all,
        InboxFilter.groups,
      ]) {
        expect(
          InboxProjection(personal).rooms(client.rooms, filter: filter),
          isNot(contains(group)),
        );
      }
      expect(
        InboxProjection(
          personal,
        ).rooms(client.rooms, filter: InboxFilter.ignored),
        [group],
      );
      expect(
        InboxProjection(personal).rooms(
          client.rooms,
          filter: InboxFilter.ignored,
          query: 'nonexistent',
        ),
        isEmpty,
      );
    },
  );

  test('saved DM merge cannot hide an explicitly declared network group', () {
    final client = _Client();
    final first = room(client, 'private', network: 'whatsapp');
    final second = room(client, 'actual-group', kind: 'group');
    client.direct[peer] = [first.id, second.id];
    final personal = _Private(client);
    addTearDown(personal.dispose);
    final group = PersonGroup(
      id: 'invalid-merge',
      name: 'Fictional person',
      members: [personal.ref(first), personal.ref(second)],
      defaultRoomId: first.id,
    );
    personal.values['person:invalid-merge'] = group
        .toJson()
        .cast<String, dynamic>();
    personal.values['network-policy:telegram'] = {'showInGroups': true};
    final projection = InboxProjection(personal);
    expect(projection.groupFor(second), isNull);
    expect(projection.rooms(client.rooms), [first]);
    expect(projection.rooms(client.rooms, filter: InboxFilter.groups), [
      second,
    ]);
    expect(personal.values, contains('person:invalid-merge'));
  });

  test(
    'new groups inherit notifications and explicit source exceptions win',
    () async {
      final client = _Client();
      final personal = _Private(client);
      addTearDown(personal.dispose);
      personal.values['network-policy:telegram'] = {
        'groupNotifications': 'muted',
      };
      final group = room(client, 'new-group', kind: 'group');
      final dm = room(client, 'dm');
      var projection = InboxProjection(personal);
      expect(
        projection.notificationModeFor(group),
        PersonalNotificationMode.muted,
      );
      expect(projection.notificationModeFor(dm), PersonalNotificationMode.all);
      final event = Event(
        room: group,
        type: EventTypes.Message,
        senderId: peer,
        originServerTs: DateTime.utc(2026),
        eventId: r'$mention',
        content: {
          'm.mentions': {
            'user_ids': [owner],
          },
        },
      );
      expect(
        await personalNotificationEligible(
          event,
          projection.metadataFor(group),
          notificationMode: projection.notificationModeFor(group),
        ),
        isFalse,
      );
      personal.values['org:${group.id}'] = {'notificationMode': 'mentionsOnly'};
      projection = InboxProjection(personal);
      expect(
        await personalNotificationEligible(
          event,
          projection.metadataFor(group),
          notificationMode: projection.notificationModeFor(group),
        ),
        isTrue,
      );
      personal.values['org:${group.id}'] = {
        'notificationMode': 'all',
        'ignored': true,
      };
      projection = InboxProjection(personal);
      expect(
        projection.notificationModeFor(group),
        PersonalNotificationMode.muted,
      );
      expect(
        await personalNotificationEligible(
          event,
          projection.metadataFor(group),
          notificationMode: PersonalNotificationMode.all,
        ),
        isFalse,
      );
      expect(group.writes, isEmpty);
    },
  );

  test(
    'ignoring a merged person hides all sources and preserves per-source modes',
    () {
      final client = _Client();
      final first = room(client, 'first', network: 'whatsapp');
      final second = room(client, 'second');
      client.direct[peer] = [first.id, second.id];
      final personal = _Private(client);
      addTearDown(personal.dispose);
      final group = PersonGroup(
        id: 'person',
        name: 'Fictional person',
        members: [personal.ref(first), personal.ref(second)],
        defaultRoomId: first.id,
      );
      personal.values['person:person'] = group.toJson().cast<String, dynamic>();
      personal.values['org:person:person'] = {'ignored': true};
      personal.values['org:${second.id}'] = {
        'notificationMode': 'mentionsOnly',
      };
      final projection = InboxProjection(personal);
      expect(projection.rooms(client.rooms), isEmpty);
      expect(
        projection.rooms(client.rooms, filter: InboxFilter.ignored),
        hasLength(1),
      );
      expect(
        projection.notificationModeFor(first),
        PersonalNotificationMode.muted,
      );
      expect(
        projection.notificationModeFor(second),
        PersonalNotificationMode.muted,
      );
      expect(notionRoomNetworks(projection, first), {'whatsapp', 'telegram'});
      personal.values['org:person:person'] = {'ignored': false};
      expect(
        InboxProjection(personal).notificationModeFor(second),
        PersonalNotificationMode.mentionsOnly,
      );
    },
  );

  testWidgets(
    'private chat mode changes do not write account rules; ignore and restore retain it',
    (tester) async {
      final client = _Client();
      final source = room(client, 'direct');
      final personal = _Private(client);
      final matrix = _Matrix(client);
      await tester.pumpWidget(
        host(ChatPreferencesPage(personal: personal, room: source), matrix),
      );
      await tester.pumpAndSettle();
      final choice = find.widgetWithText(
        PreferenceChoice,
        'ChatLoom notifications',
      );
      await tester.ensureVisible(choice);
      // A picker row: a tap opens the glass sheet of choices (UI-10).
      await tester.tap(choice);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Mentions only').last);
      await tester.pumpAndSettle();
      expect(
        personal.values['org:${source.id}']?['notificationMode'],
        'mentionsOnly',
      );
      // "Low priority" (CS-06) is a second switch on this page.
      final ignore = find.widgetWithText(SwitchListTile, 'Ignore chat');
      final ignoreSwitch = find.descendant(
        of: ignore,
        matching: find.byType(Switch),
      );
      await tester.ensureVisible(ignore);
      await tester.tap(ignoreSwitch);
      await tester.pumpAndSettle();
      expect(
        InboxProjection(personal).notificationModeFor(source),
        PersonalNotificationMode.muted,
      );
      await tester.tap(ignoreSwitch);
      await tester.pumpAndSettle();
      expect(
        InboxProjection(personal).notificationModeFor(source),
        PersonalNotificationMode.mentionsOnly,
      );
      expect(source.writes, isEmpty);
      matrix.active = _Client();
      await tester.pumpWidget(
        host(ChatPreferencesPage(personal: personal, room: source), matrix),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SwitchListTile>(
              find.widgetWithText(SwitchListTile, 'Ignore chat'),
            )
            .onChanged,
        isNull,
      );
      await tester.pumpWidget(const SizedBox());
      personal.dispose();
    },
  );

  for (final width in [320.0, 1100.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('production category menu renders at $width and $scale', (
        tester,
      ) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = Size(width, 1000);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          host(
            NotionInboxPage(
              rows: const [ListTile(title: Text('Fictional private chat'))],
              pins: const [],
              onSettings: () {},
              onSearch: () {},
              selectedNetwork: 'telegram',
              networks: const ['messenger', 'telegram', 'whatsapp'],
              onNetworkSelected: (_) {},
              onViewSelected: (_) {},
              onManageNetworks: () {},
            ),
            _Matrix(_Client()),
            scale: scale,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('notion_dock_network')));
        await tester.pumpAndSettle();
        expect(find.text('Ignored'), findsOneWidget);
        expect(find.text('Technical'), findsOneWidget);
        await capture(
          tester,
          'category-menu-${width.toInt()}-${(scale * 100).toInt()}',
        );
        expect(tester.takeException(), isNull);
      });
    }
  }
}
