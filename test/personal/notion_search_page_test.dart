// SPDX-License-Identifier: AGPL-3.0-or-later
//
// The inbox has no compose button; the full-screen search finds chats,
// people of the connected networks (grouped by network) and messages, and
// starts new chats through the bridge only after an explicit, confirmed tap.
// Bridges are fakes; nothing leaves the test.
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat_list/inbox_controller.dart';
import 'package:chatloom/personal/bridge_contact_search.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/notion_inbox_page.dart';
import 'package:chatloom/personal/ui/notion_network_selector.dart';
import 'package:chatloom/personal/ui/notion_search_page.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart' show InboxFilter;

const _owner = '@owner:example.invalid';
const _waBot = '@sh-whatsappbot:beeper.local';
const _tgBot = '@sh-telegrambot:beeper.local';
const _alicja = '@sh-whatsapp_100:beeper.local';
const _anna = '@sh-whatsapp_200:beeper.local';
const _bogdan = '@sh-whatsapp_300:beeper.local';
const _annaTg = '@sh-telegram_1:beeper.local';
const _cezary = '@sh-telegram_2:beeper.local';

class _NoDatabase implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client() : super('synthetic search', database: _NoDatabase());
  @override
  String get userID => _owner;
}

void _state(
  Room room,
  String type,
  Map<String, dynamic> content, {
  String key = '',
  String sender = _waBot,
}) => room.setState(
  Event(
    room: room,
    type: type,
    stateKey: key,
    content: content,
    eventId: '\$fixture-${room.id}-$type-$key',
    senderId: sender,
    originServerTs: DateTime.utc(2026),
  ),
);

Room _room(
  Client client,
  String id, {
  required String bot,
  required String protocol,
  required Map<String, String> members,
  String? name,
  bool dm = false,
}) {
  final room = Room(
    id: id,
    client: client,
    membership: Membership.join,
    summary: RoomSummary.fromJson({
      'm.heroes': [bot],
      'm.joined_member_count': members.length + 2,
      'm.invited_member_count': 0,
    }),
  );
  client.rooms.add(room);
  _state(
    room,
    'm.bridge',
    {
      'bridgebot': bot,
      'protocol': {'id': protocol},
      'com.beeper.room_type.v2': dm ? 'dm' : 'group',
    },
    key: 'fixture',
    sender: bot,
  );
  if (name != null) {
    _state(room, EventTypes.RoomName, {'name': name}, sender: bot);
  }
  for (final entry in {_owner: 'Me', bot: 'bridge bot', ...members}.entries) {
    _state(
      room,
      EventTypes.RoomMember,
      {'membership': 'join', 'displayname': entry.value},
      key: entry.key,
      sender: bot,
    );
  }
  return room;
}

class _Fixture {
  _Fixture() {
    dm = _room(
      client,
      '!dm:example.invalid',
      bot: _waBot,
      protocol: 'whatsapp',
      members: {_alicja: 'Alicja Fikcyjna'},
      dm: true,
    );
    family = _room(
      client,
      '!family:example.invalid',
      bot: _waBot,
      protocol: 'whatsapp',
      members: {_anna: 'Anna Grupowa', _bogdan: 'Bogdan Fikcyjny'},
      name: 'Rodzina',
    );
    family.lastEvent = Event(
      room: family,
      type: EventTypes.Message,
      content: {'msgtype': MessageTypes.Text, 'body': 'Faktura w załączniku'},
      eventId: r'$fixture-invoice',
      senderId: _anna,
      originServerTs: DateTime.utc(2026, 10, 1),
    );
    _room(
      client,
      '!club:example.invalid',
      bot: _tgBot,
      protocol: 'telegram',
      members: {_annaTg: 'Anna Telegramowa', _cezary: 'Cezary Fikcyjny'},
      name: 'Klub',
    );
  }

  final client = _Client();
  late final personal = PersonalClient.of(client);
  late final inbox = InboxController(client, personal);
  late final Room dm, family;

  void dispose() {
    inbox.dispose();
    personal.dispose();
  }
}

/// WhatsApp answers; Telegram's provisioning API is unreachable.
FakeProvisioning _bridges(_Fixture fixture, {bool reachable = true}) =>
    FakeProvisioning((bridge, request) {
      if (!reachable || bridge.botId == _tgBot) {
        throw const BridgeProvisioningException(404, errcode: 'M_UNRECOGNIZED');
      }
      return switch (request.path) {
        '/v3/whoami' => {
          'network': {'displayname': 'WhatsApp'},
          'bridge_bot': bridge.botId,
          'logins': [
            {
              'id': 'login',
              'name': 'Fictional',
              'state': {'state_event': 'CONNECTED'},
            },
          ],
        },
        '/v3/capabilities' => {
          'resolve_identifier': {
            'create_dm': true,
            'contact_list': true,
            'search': true,
            'lookup_phone': true,
          },
        },
        '/v3/contacts' => {
          'contacts': [
            {
              'id': '48600100900',
              'name': 'Anna Kontakt',
              'identifiers': ['tel:+48600100900'],
            },
          ],
        },
        '/v3/search_users' => {'results': <Object>[]},
        final path when path.startsWith('/v3/create_dm/') => () {
          // The bridge creates the portal; sync delivers the room.
          fixture.client.rooms.add(
            Room(
              id: '!created:example.invalid',
              client: fixture.client,
              membership: Membership.join,
            ),
          );
          return {'id': 'x', 'dm_room_mxid': '!created:example.invalid'};
        }(),
        _ => throw const BridgeProvisioningException(
          404,
          errcode: 'M_UNRECOGNIZED',
        ),
      };
    });

class FakeProvisioning implements BridgeProvisioningTransport {
  FakeProvisioning(this.handler);
  final Object? Function(BridgeEndpoint, BridgeProvisioningRequest) handler;
  final requests = <(String, BridgeProvisioningRequest)>[];
  List<String> get paths => [
    for (final r in requests) '${r.$2.method} ${r.$2.path}',
  ];

  @override
  Future<Object?> send(
    BridgeEndpoint bridge,
    BridgeProvisioningRequest request,
  ) async {
    requests.add((bridge.botId, request));
    return handler(bridge, request);
  }
}

class _Opened {
  final rooms = <String>[];
  final messages = <(String, String)>[];
  final views = <InboxFilter>[];
  final history = <String>[];
}

Future<void> _openSearch(
  WidgetTester tester,
  _Fixture fixture,
  BridgeDirectory directory,
  _Opened opened,
) async {
  tester.view.physicalSize = const Size(420, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    MaterialApp(
      theme: NotionTheme.build(Brightness.dark),
      localizationsDelegates: L10n.localizationsDelegates,
      supportedLocales: L10n.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => NotionSearchPage(
                    personal: fixture.personal,
                    inbox: fixture.inbox,
                    directory: directory,
                    closeOnOpen: false,
                    onOpenRoom: (room) => opened.rooms.add(room.id),
                    onOpenMessage: (room, event) =>
                        opened.messages.add((room.id, event)),
                    onSearchHistory: opened.history.add,
                    onSelectView: opened.views.add,
                  ),
                ),
              ),
              child: const Text('Open search'),
            ),
          ),
        ),
      ),
    ),
  );
  // Localizations load asynchronously before the first real frame.
  await tester.pumpAndSettle();
  await tester.tap(find.text('Open search'));
  await tester.pumpAndSettle();
}

Future<void> _type(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.pump(NotionSearchPage.typingDebounce);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('the inbox has no compose button; Search is the entry point', (
    tester,
  ) async {
    var searches = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: NotionInboxPage(
          pins: const [],
          onSettings: () {},
          onSearch: () => searches++,
          onNetworkSelected: (_) {},
          networks: const ['whatsapp'],
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.edit_square), findsNothing);
    expect(find.byTooltip('New chat'), findsNothing);
    expect(find.text('Chats'), findsOneWidget);
    expect(find.textContaining('Use Search'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('notion_dock_search')));
    await tester.pumpAndSettle();
    expect(searches, 1);
  });

  testWidgets(
    'typing finds people by network without sending the query anywhere',
    (tester) async {
      final fixture = _Fixture();
      final transport = _bridges(fixture);
      final directory = BridgeDirectory(BridgeProvisioningApi(transport));
      final opened = _Opened();
      await _openSearch(tester, fixture, directory, opened);
      // Opening asks each bridge who it is; no query, no contacts yet.
      expect(transport.paths, containsAll(['GET /v3/whoami']));
      expect(transport.paths.where((p) => p.contains('contacts')), isEmpty);
      expect(find.text('Your networks'), findsOneWidget);
      expect(find.text('Find people and start chats'), findsOneWidget);
      expect(find.text('People from your chats only'), findsOneWidget);

      await _type(tester, 'anna');
      // People of bridged chats and bridge contacts, under their network.
      expect(find.text('Telegram'), findsOneWidget);
      expect(find.text('WhatsApp'), findsOneWidget);
      expect(find.byType(NotionNetworkGlyph), findsNWidgets(2));
      expect(find.text('Anna Telegramowa'), findsOneWidget);
      expect(find.text('From your chats'), findsOneWidget);
      expect(find.text('Anna Grupowa'), findsOneWidget);
      expect(find.text('In Rodzina'), findsOneWidget);
      expect(find.text('Anna Kontakt'), findsOneWidget);
      expect(find.text('+48600100900 · Contact'), findsOneWidget);
      final waHeader = tester.getTopLeft(find.text('WhatsApp')).dy;
      expect(
        tester.getTopLeft(find.text('Anna Grupowa')).dy,
        greaterThan(waHeader),
      );
      expect(
        tester.getTopLeft(find.text('Anna Kontakt')).dy,
        greaterThan(tester.getTopLeft(find.text('Anna Grupowa')).dy),
      );
      // Never a Matrix id or directory.
      expect(find.textContaining('beeper.local'), findsNothing);
      expect(find.textContaining('example.invalid'), findsNothing);
      expect(find.textContaining('Discover'), findsNothing);
      // Contacts came without the query; nothing carried "anna".
      expect(transport.paths, contains('GET /v3/contacts'));
      for (final (_, request) in transport.requests) {
        expect(request.body, isNull);
        expect(request.path.toLowerCase(), isNot(contains('anna')));
      }

      // An explicit tap sends the query to that network only.
      await tester.tap(find.text('Search WhatsApp for “anna”'));
      await tester.pumpAndSettle();
      final searches = transport.requests.where(
        (r) => r.$2.path == '/v3/search_users',
      );
      expect(searches.single.$1, _waBot);
      expect(searches.single.$2.body, {'query': 'anna'});
      expect(
        find.text('Search done. New people appear above.'),
        findsOneWidget,
      );
      expect(transport.paths.where((p) => p.contains('create_dm')), isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
    },
  );

  testWidgets('starting a chat asks first; only a confirmed tap creates it', (
    tester,
  ) async {
    final fixture = _Fixture();
    final transport = _bridges(fixture);
    final directory = BridgeDirectory(BridgeProvisioningApi(transport));
    final opened = _Opened();
    await _openSearch(tester, fixture, directory, opened);
    await _type(tester, 'grupowa');
    await tester.tap(find.text('Anna Grupowa'));
    await tester.pumpAndSettle();
    expect(
      find.text('Start a WhatsApp chat with Anna Grupowa?'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(transport.paths.where((p) => p.contains('create_dm')), isEmpty);
    expect(opened.rooms, isEmpty);

    await tester.tap(find.text('Anna Grupowa'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start chat'));
    await tester.pumpAndSettle();
    final created = transport.requests.where(
      (r) => r.$2.path.startsWith('/v3/create_dm/'),
    );
    expect(created, hasLength(1));
    expect(created.single.$1, _waBot);
    expect(Uri.decodeComponent(created.single.$2.path.split('/').last), _anna);
    expect(opened.rooms, ['!created:example.invalid']);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets('chats and messages open where they were found', (tester) async {
    final fixture = _Fixture();
    final directory = BridgeDirectory(BridgeProvisioningApi(_bridges(fixture)));
    final opened = _Opened();
    await _openSearch(tester, fixture, directory, opened);
    await _type(tester, 'alicja');
    expect(find.text('Chats'), findsOneWidget);
    // Her chat is listed once, under Chats, not again under WhatsApp.
    expect(find.text('Alicja Fikcyjna'), findsOneWidget);
    await tester.tap(find.text('Alicja Fikcyjna'));
    await tester.pumpAndSettle();
    expect(opened.rooms, [fixture.dm.id]);

    await _type(tester, 'faktura');
    expect(find.text('Messages'), findsOneWidget);
    expect(find.textContaining('Faktura w załączniku'), findsOneWidget);
    await tester.tap(find.textContaining('Faktura w załączniku'));
    await tester.pumpAndSettle();
    expect(opened.messages, [(fixture.family.id, r'$fixture-invoice')]);

    await tester.tap(find.text('Search message history for “faktura”'));
    await tester.pumpAndSettle();
    expect(opened.history, ['faktura']);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets(
    'unreachable bridges: a note, people from chats, and no new chats',
    (tester) async {
      final fixture = _Fixture();
      final transport = _bridges(fixture, reachable: false);
      final directory = BridgeDirectory(BridgeProvisioningApi(transport));
      final opened = _Opened();
      await _openSearch(tester, fixture, directory, opened);
      await _type(tester, 'anna');
      expect(find.text('Only people from your chats'), findsOneWidget);
      expect(find.text('Anna Grupowa'), findsOneWidget);
      expect(find.text('Anna Telegramowa'), findsOneWidget);
      expect(find.textContaining('Search WhatsApp'), findsNothing);
      await tester.tap(find.text('Anna Grupowa'));
      await tester.pumpAndSettle();
      expect(find.text('Can’t start a new chat yet'), findsOneWidget);
      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();
      expect(transport.paths.where((p) => p.contains('create_dm')), isEmpty);
      expect(opened.rooms, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
      fixture.dispose();
    },
  );

  testWidgets('inbox views on the empty search switch the view and close it', (
    tester,
  ) async {
    final fixture = _Fixture();
    final directory = BridgeDirectory.disabled('Not available in tests.');
    final opened = _Opened();
    await _openSearch(tester, fixture, directory, opened);
    expect(find.text('People from your chats only'), findsNWidgets(2));
    await tester.tap(find.text('Archive'));
    await tester.pumpAndSettle();
    expect(opened.views, [InboxFilter.archive]);
    expect(find.text('Open search'), findsOneWidget);
    expect(find.byType(NotionSearchPage), findsNothing);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets('search keeps the covered inbox live while it is shown', (
    tester,
  ) async {
    final fixture = _Fixture();
    // The inbox route is covered by the search page (CC-23).
    fixture.inbox.active = false;
    final opened = _Opened();
    await _openSearch(
      tester,
      fixture,
      BridgeDirectory.disabled('Not available in tests.'),
      opened,
    );
    expect(fixture.inbox.active, isTrue);
    await tester.tap(find.byTooltip('Close search'));
    await tester.pumpAndSettle();
    expect(find.byType(NotionSearchPage), findsNothing);
    expect(fixture.inbox.active, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets('a failed network search explains itself and can be retried', (
    tester,
  ) async {
    final fixture = _Fixture();
    final working = _bridges(fixture);
    var fail = true;
    final transport = FakeProvisioning((bridge, request) {
      if (fail && request.path == '/v3/search_users') {
        throw const BridgeProvisioningException(503);
      }
      return working.handler(bridge, request);
    });
    final directory = BridgeDirectory(BridgeProvisioningApi(transport));
    await _openSearch(tester, fixture, directory, _Opened());
    await _type(tester, 'anna');
    await tester.tap(find.text('Search WhatsApp for “anna”'));
    await tester.pumpAndSettle();
    expect(
      find.text(
        'Couldn’t search WhatsApp. The bridge had a problem. Try again later.',
      ),
      findsOneWidget,
    );
    fail = false;
    await tester.tap(find.text('Search WhatsApp for “anna”'));
    await tester.pumpAndSettle();
    expect(find.text('Search done. New people appear above.'), findsOneWidget);
    expect(
      transport.paths.where((path) => path.contains('search_users')),
      hasLength(2),
    );
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });

  testWidgets('the empty search starts with recent people', (tester) async {
    final fixture = _Fixture();
    fixture.dm.lastEvent = Event(
      room: fixture.dm,
      type: EventTypes.Message,
      content: {'msgtype': MessageTypes.Text, 'body': 'Fictional hello'},
      eventId: r'$fixture-recent',
      senderId: _alicja,
      originServerTs: DateTime.utc(2026, 10, 2),
    );
    final opened = _Opened();
    await _openSearch(
      tester,
      fixture,
      BridgeDirectory.disabled('Not available in tests.'),
      opened,
    );
    expect(find.text('Recent'), findsOneWidget);
    final recent = find.byKey(ValueKey('search-recent:${fixture.dm.id}'));
    expect(recent, findsOneWidget);
    // Groups are not people.
    expect(
      find.byKey(ValueKey('search-recent:${fixture.family.id}')),
      findsNothing,
    );
    await tester.tap(recent);
    await tester.pumpAndSettle();
    expect(opened.rooms, [fixture.dm.id]);
    await tester.pumpWidget(const SizedBox.shrink());
    fixture.dispose();
  });
}
