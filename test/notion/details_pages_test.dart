// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 6 details-pages: glass headers, picker rows, timed mute, unarchive,
// Matrix-only rows and the disappearing-message timer. Fictional data only.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/chat_app_bar_title.dart';
import 'package:chatloom/personal/disappearing_label.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/chat_preferences_page.dart';
import 'package:chatloom/personal/ui/notion_chat_details_adapter.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_choice.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
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
  _Client() : super('synthetic details pages', database: _NoDatabase());
  @override
  String get userID => owner;
  @override
  Map<String, List<String>> get directChats => const {};
}

class _Room extends Room {
  _Room({required super.id, required super.client})
    : super(membership: Membership.join);
  @override
  PushRuleState get pushRuleState => PushRuleState.notify;
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
  Future<void> put(String key, Map<String, dynamic> value) async {
    values[key] = value;
    notifyListeners();
  }
}

class _Matrix extends MatrixState {
  final Client active;
  _Matrix(this.active);
  @override
  Client get client => active;
  @override
  Matrix get widget => Matrix(clients: [active], store: AppSettings.store);
}

void _state(
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

_Room _room(_Client client, String id, {String? network, String kind = 'dm'}) {
  final result = _Room(id: '!$id:example.invalid', client: client);
  client.rooms.add(result);
  _state(result, EventTypes.RoomName, {'name': 'Fictional $id'});
  if (network != null) {
    _state(result, 'm.bridge', {
      'bridgebot': bot,
      'protocol': {'id': network},
      'com.beeper.room_type.v2': kind,
    });
  }
  for (final id in [owner, bot, peer]) {
    _state(result, EventTypes.RoomMember, {'membership': 'join'}, key: id);
  }
  result.summary.mJoinedMemberCount = 3;
  return result;
}

Widget _host(Widget page, Client client) => Provider<MatrixState>.value(
  value: _Matrix(client),
  child: MaterialApp(theme: NotionTheme.build(Brightness.dark), home: page),
);

void _tall(WidgetTester tester) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(800, 3200);
  addTearDown(tester.view.reset);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('disappearing timer label (FX-13)', () {
    test('durations and modes read as people say them', () {
      expect(disappearingTimerLabelOf(null), isNull);
      expect(disappearingTimerLabelOf(const {}), isNull);
      expect(
        disappearingTimerLabelOf({'type': 'after_send', 'timer': 86400000}),
        '1 day',
      );
      expect(
        disappearingTimerLabelOf({'type': 'after_send', 'timer': 604800000}),
        '1 week',
      );
      expect(
        disappearingTimerLabelOf({'type': 'after_read', 'timer': 28800000}),
        '8 hours after reading',
      );
      expect(disappearingTimerLabelOf({'type': 'after_send'}), 'On');
      expect(disappearingTimerLabelOf('malformed'), 'On');
      expect(disappearingDurationLabel(const Duration(days: 90)), '90 days');
      expect(
        disappearingDurationLabel(const Duration(minutes: 5)),
        '5 minutes',
      );
      expect(disappearingDurationLabel(const Duration(seconds: 1)), '1 second');
    });

    testWidgets('the header line shows the timer', (tester) async {
      final client = _Client();
      final room = _room(client, 'timer', network: 'telegram');
      _state(room, beeperDisappearingTimerKey, {
        'type': 'after_send',
        'timer': 86400000,
      });
      String? label;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              label = ChatHeaderSubtitle.infoLabel(context, room);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(label, 'Telegram · ⏱ 1 day');
    });
  });

  group('chat details (FX-07, FX-09, FX-13)', () {
    testWidgets(
      'bridged group: no Matrix admin rows or View contact, human encryption',
      (tester) async {
        _tall(tester);
        final client = _Client();
        final room = _room(client, 'group', network: 'telegram', kind: 'group');
        final personal = _Private(client);
        await tester.pumpWidget(
          _host(NotionLiveChatDetails(personal: personal, room: room), client),
        );
        await tester.pumpAndSettle();
        expect(find.text('Participants'), findsOneWidget);
        expect(find.text('Access & visibility'), findsNothing);
        expect(find.text('Permissions'), findsNothing);
        expect(find.text('View contact'), findsNothing);
        expect(find.text('Conversation capabilities'), findsOneWidget);
        await tester.tap(find.text('Encryption & recovery'));
        await tester.pumpAndSettle();
        expect(find.text('Open Privacy & security'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        personal.dispose();
      },
    );

    testWidgets('native Matrix group keeps the Matrix admin rows', (
      tester,
    ) async {
      _tall(tester);
      final client = _Client();
      final room = _room(client, 'native');
      final personal = _Private(client);
      expect(
        InboxProjection(personal).classifier.classify(room).network,
        'matrix',
      );
      await tester.pumpWidget(
        _host(NotionLiveChatDetails(personal: personal, room: room), client),
      );
      await tester.pumpAndSettle();
      expect(find.text('Access & visibility'), findsOneWidget);
      expect(find.text('Permissions'), findsOneWidget);
      expect(find.text('Conversation capabilities'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      personal.dispose();
    });

    testWidgets(
      'archived chat unarchives with Undo; timed mute shows its end and unmutes',
      (tester) async {
        _tall(tester);
        final client = _Client();
        final room = _room(client, 'dm', network: 'whatsapp');
        _state(room, beeperDisappearingTimerKey, {
          'type': 'after_send',
          'timer': 604800000,
        });
        final personal = _Private(client);
        personal.values['org:${room.id}'] = {
          'entityId': room.id,
          'archived': true,
          'muted': true,
          'mutedUntil': DateTime.now()
              .add(const Duration(hours: 2))
              .toUtc()
              .toIso8601String(),
        };
        await tester.pumpWidget(
          _host(NotionLiveChatDetails(personal: personal, room: room), client),
        );
        await tester.pumpAndSettle();
        // DM: View contact stays; the timer is shown read-only.
        expect(find.text('View contact'), findsOneWidget);
        expect(find.text('Disappearing messages'), findsOneWidget);
        expect(find.text('1 week'), findsOneWidget);
        // Timed mute.
        expect(find.text('Unmute'), findsOneWidget);
        expect(find.textContaining('Muted until'), findsOneWidget);
        // Unarchive.
        expect(find.text('Unarchive chat'), findsOneWidget);
        await tester.tap(find.text('Unarchive chat'));
        await tester.pumpAndSettle();
        expect(personal.values['org:${room.id}']?['archived'], isFalse);
        expect(find.text('Chat unarchived'), findsOneWidget);
        expect(find.text('Archive chat'), findsOneWidget);
        await tester.tap(find.text('Unmute'));
        await tester.pumpAndSettle();
        expect(personal.values['org:${room.id}']?['muted'], isFalse);
        expect(find.text('Mute…'), findsOneWidget);
        await tester.pumpWidget(const SizedBox.shrink());
        personal.dispose();
      },
    );
  });

  testWidgets('chat preferences: Mute… with durations, picker rows', (
    tester,
  ) async {
    _tall(tester);
    final client = _Client();
    final room = _room(client, 'prefs', network: 'telegram');
    final personal = _Private(client);
    await tester.pumpWidget(
      _host(ChatPreferencesPage(personal: personal, room: room), client),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DropdownButton<String>), findsNothing);
    await tester.tap(find.text('Mute…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('For 1 hour'));
    await tester.pumpAndSettle();
    final stored = personal.values['org:${room.id}']!;
    expect(stored['muted'], isTrue);
    expect(stored['mutedUntil'], isA<String>());
    expect(find.text('Unmute'), findsOneWidget);
    // A picker row opens a glass sheet of choices.
    await tester.tap(find.widgetWithText(PreferenceChoice, 'Show chat in'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Main list').last);
    await tester.pumpAndSettle();
    expect(personal.values['org:${room.id}']?['placement'], 'inbox');
    await tester.pumpWidget(const SizedBox.shrink());
    personal.dispose();
  });

  group('NotionPickerRow / NotionChoicePill', () {
    testWidgets('a null option differs from a dismissed sheet', (tester) async {
      final picked = <String?>[];
      String? value = 'a';
      await tester.pumpWidget(
        MaterialApp(
          theme: NotionTheme.build(Brightness.light),
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) => Column(
                children: [
                  NotionChoicePill<String?>(
                    title: 'Network',
                    value: value,
                    neutral: null,
                    options: const [
                      NotionChoice(null, 'All networks'),
                      NotionChoice('a', 'Alpha'),
                    ],
                    onChanged: (v) => setState(() {
                      picked.add(v);
                      value = v;
                    }),
                  ),
                  const NotionPickerRow<int>(
                    label: 'Disabled',
                    value: 1,
                    options: [NotionChoice(1, 'One')],
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.text('Alpha'), findsOneWidget);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      // Dismiss: nothing picked.
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(picked, isEmpty);
      await tester.tap(find.text('Alpha'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('All networks'));
      await tester.pumpAndSettle();
      expect(picked, [null]);
      expect(find.text('All networks'), findsOneWidget);
      // Disabled row: no sheet.
      await tester.tap(find.text('Disabled'));
      await tester.pumpAndSettle();
      expect(find.byType(NotionSheet), findsNothing);
    });
  });
}
