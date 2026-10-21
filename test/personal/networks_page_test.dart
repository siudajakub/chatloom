// SPDX-License-Identifier: AGPL-3.0-or-later
// Settings → Networks (wave 4): one list with a status pill per network, a
// simple network page with the fix, placement and notification rules, and
// diagnostics behind "Advanced". Synthetic rooms only: no real ids, names
// or message text.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/bridge_contact_search_provisioning.dart';
import 'package:chatloom/personal/bridge_health.dart';
import 'package:chatloom/personal/bridge_health_monitor.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/network_sign_out.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/networks_page.dart';
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
const _whatsappBot = '@sh-whatsappbot:example.invalid';
const _telegramBot = '@telegrambot:example.invalid';
const _signalBot = '@signalbot:example.invalid';
const _peer = '@person:example.invalid';

final _now = DateTime.now().toUtc();
DateTime get _clock => _now;

class _Db implements DatabaseApi {
  final events = <String, List<Event>>{};

  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    bool onlySending = false,
    int? limit,
  }) async => events[room.id] ?? const [];

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client(_Db db) : super('synthetic networks', database: db);
  @override
  String get userID => _owner;
}

void _state(
  Room room,
  String type,
  Map<String, dynamic> content, {
  String key = '',
  String sender = _owner,
}) => room.setState(
  Event(
    room: room,
    type: type,
    stateKey: key,
    content: content,
    senderId: sender,
    eventId: '\$fixture-${room.id}-$type-$key',
    originServerTs: DateTime.utc(2026),
  ),
);

Room _portal(
  Client client,
  String id, {
  required String network,
  required String bot,
  String kind = 'dm',
}) {
  final room = Room(
    id: '!$id:example.invalid',
    client: client,
    membership: Membership.join,
  );
  client.rooms.add(room);
  _state(room, EventTypes.RoomName, {'name': 'Fictional $id'});
  _state(room, 'm.bridge', {
    'bridgebot': bot,
    'protocol': {'id': network},
    'com.beeper.room_type.v2': kind,
  }, sender: bot);
  for (final member in [_owner, bot, _peer]) {
    _state(room, EventTypes.RoomMember, {'membership': 'join'}, key: member);
  }
  room.summary.mJoinedMemberCount = 3;
  room.summary.mInvitedMemberCount = 0;
  return room;
}

Room _management(Client client, String id, String bot) {
  final room = Room(
    id: '!$id:example.invalid',
    client: client,
    membership: Membership.join,
    summary: RoomSummary.fromJson({
      'm.heroes': [bot],
      'm.joined_member_count': 2,
      'm.invited_member_count': 0,
    }),
  );
  client.rooms.add(room);
  for (final member in [_owner, bot]) {
    _state(room, EventTypes.RoomMember, {'membership': 'join'}, key: member);
  }
  return room;
}

Event _notice(Room room, String bot, Map<String, Object?> state, DateTime at) =>
    Event(
      room: room,
      type: EventTypes.Message,
      content: {
        'msgtype': 'm.notice',
        'body': '-',
        bridgeStateNoticeKey: state,
      },
      eventId: '\$fixture-notice-${at.millisecondsSinceEpoch}',
      senderId: bot,
      originServerTs: at,
    );

// Presentation adapter only; durable replica behaviour has its own tests.
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

Widget _host(Widget page, Client client, {double scale = 1}) =>
    Provider<MatrixState>.value(
      value: _Matrix(client),
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: NotionTheme.build(Brightness.dark),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: page,
      ),
    );

/// WhatsApp signed out (stored bridge notice), Telegram with a recent remote
/// message, Signal with nothing known.
class _Fixture {
  _Fixture() {
    client = _Client(db);
    whatsapp = _portal(client, 'wa', network: 'whatsapp', bot: _whatsappBot);
    _portal(
      client,
      'wa-group',
      network: 'whatsapp',
      bot: _whatsappBot,
      kind: 'group',
    );
    management = _management(client, 'wa-bot', _whatsappBot);
    db.events[management.id] = [
      _notice(management, _whatsappBot, {
        'state_event': 'BAD_CREDENTIALS',
        'timestamp':
            _now.subtract(const Duration(minutes: 30)).millisecondsSinceEpoch ~/
            1000,
        'remote_id': 'login-a',
        'remote_name': 'Fictional Account',
      }, _now.subtract(const Duration(minutes: 30))),
    ];
    telegram = _portal(client, 'tg', network: 'telegram', bot: _telegramBot);
    telegram.lastEvent = Event(
      room: telegram,
      type: EventTypes.Message,
      content: {'msgtype': 'm.text', 'body': '-'},
      eventId: r'$fixture-inbound',
      senderId: _peer,
      originServerTs: _now.subtract(const Duration(minutes: 5)),
    );
    _portal(client, 'sg', network: 'signal', bot: _signalBot);
    personal = _Private(client);
    monitor = BridgeHealthMonitor(client, clock: () => _clock);
  }

  final db = _Db();
  late final _Client client;
  late final Room whatsapp;
  late final Room management;
  late final Room telegram;
  late final _Private personal;
  late final BridgeHealthMonitor monitor;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('status words', () {
    BridgeHealth health(BridgeHealthState state) => BridgeHealth(
      network: 'whatsapp',
      state: state,
      title: 't',
      reason: '',
      signature: 's',
    );

    test('one of three pills, none without any signal', () {
      expect(networkStatusOf(null), NetworkStatus.unknown);
      expect(networkStatusLabel(NetworkStatus.unknown), isNull);
      expect(
        networkStatusOf(health(BridgeHealthState.ok)),
        NetworkStatus.connected,
      );
      expect(
        networkStatusOf(health(BridgeHealthState.unknown)),
        NetworkStatus.connected,
      );
      expect(
        networkStatusOf(health(BridgeHealthState.degraded)),
        NetworkStatus.attention,
      );
      expect(
        networkStatusOf(health(BridgeHealthState.disconnected)),
        NetworkStatus.disconnected,
      );
      expect(
        networkStatusOf(health(BridgeHealthState.loggedOut)),
        NetworkStatus.disconnected,
      );
      expect(
        [
          for (final status in [
            NetworkStatus.connected,
            NetworkStatus.attention,
            NetworkStatus.disconnected,
          ])
            networkStatusLabel(status),
        ],
        ['Connected', 'Needs attention', 'Disconnected'],
      );
    });

    test('ages and counts read like a person wrote them', () {
      final now = DateTime.utc(2026, 10, 21, 12);
      expect(networkAgo(now, now), 'just now');
      expect(
        networkAgo(now.subtract(const Duration(minutes: 5)), now),
        '5 min ago',
      );
      expect(
        networkAgo(now.subtract(const Duration(hours: 3)), now),
        '3 h ago',
      );
      expect(
        networkAgo(now.subtract(const Duration(hours: 30)), now),
        'yesterday',
      );
      expect(
        networkAgo(now.subtract(const Duration(days: 4)), now),
        '4 days ago',
      );
      expect(networkChatCount(0), 'No chats yet');
      expect(networkChatCount(1), '1 chat');
      expect(networkChatCount(12), '12 chats');
    });

    test('the row line shows the problem, else account and chats', () {
      const healthy = NetworkSummary(
        network: 'telegram',
        chats: 3,
        accounts: ['Fictional Account'],
      );
      expect(healthy.subtitle, 'Fictional Account · 3 chats');
      final now = DateTime.utc(2026, 10, 21, 12);
      final signals = BridgeSignals()
        ..addReport(
          BridgeStateReport.parse(
            {
              'state_event': 'BAD_CREDENTIALS',
              'timestamp': now.millisecondsSinceEpoch ~/ 1000,
            },
            network: 'whatsapp',
            fallback: now,
          )!,
        );
      final problem = NetworkSummary(
        network: 'whatsapp',
        chats: 3,
        health: evaluateBridgeHealth('whatsapp', signals, now),
      );
      expect(problem.subtitle, 'Signed out');
      expect(problem.status, NetworkStatus.disconnected);
    });

    test('verdicts carry a short summary without the network name', () {
      final now = DateTime.utc(2026, 10, 21, 12);
      String summary(String event, {String? action}) {
        final signals = BridgeSignals()
          ..addReport(
            BridgeStateReport.parse(
              {
                'state_event': event,
                'timestamp': now.millisecondsSinceEpoch ~/ 1000,
                'user_action': ?action,
              },
              network: 'whatsapp',
              fallback: now,
            )!,
          );
        return evaluateBridgeHealth('whatsapp', signals, now).summary;
      }

      expect(summary('BAD_CREDENTIALS'), 'Signed out');
      expect(summary('UNCONFIGURED'), 'Not signed in');
      expect(summary('TRANSIENT_DISCONNECT'), 'Disconnected');
      expect(summary('BRIDGE_UNREACHABLE'), 'Bridge isn’t running');
      expect(summary('CONNECTING'), 'Reconnecting');
      expect(
        summary('CONNECTED', action: 'OPEN_NATIVE'),
        'Open the app on your phone',
      );
      expect(summary('CONNECTED'), 'Connected');
    });

    test('the account name is read from the notice, capped', () {
      final now = DateTime.utc(2026, 10, 21, 12);
      BridgeStateReport? parse(Object? name) => BridgeStateReport.parse(
        {'state_event': 'CONNECTED', 'remote_name': name},
        network: 'whatsapp',
        fallback: now,
      );
      expect(parse('Fictional Account')?.remoteName, 'Fictional Account');
      expect(parse('x' * 65)?.remoteName, isNull);
      expect(parse(42)?.remoteName, isNull);
    });
  });

  testWidgets('one list: problems first, one pill each, tap opens', (
    tester,
  ) async {
    final fixture = _Fixture();
    final opened = <String>[];
    await tester.pumpWidget(
      _host(
        NetworksPage(
          personal: fixture.personal,
          monitor: fixture.monitor,
          onOpen: opened.add,
        ),
        fixture.client,
      ),
    );
    await tester.pumpAndSettle();
    final rows = tester
        .widgetList<NetworkRow>(find.byType(NetworkRow))
        .map((row) => row.summary.network)
        .toList();
    expect(rows, ['whatsapp', 'signal', 'telegram']);
    Finder inRow(String network, Finder finder) => find.descendant(
      of: find.byKey(ValueKey('network-$network')),
      matching: finder,
    );
    expect(inRow('whatsapp', find.text('Disconnected')), findsOneWidget);
    expect(inRow('whatsapp', find.text('Signed out')), findsOneWidget);
    expect(inRow('telegram', find.text('Connected')), findsOneWidget);
    expect(inRow('telegram', find.text('1 chat')), findsOneWidget);
    expect(inRow('signal', find.byType(NotionStatusPill)), findsNothing);
    // The technical bridge chat is not a network of its own.
    expect(find.text('Matrix'), findsNothing);
    // No settings jargon on the list.
    expect(find.text('Notifications for all groups'), findsNothing);
    await tester.tap(find.byKey(const ValueKey('network-telegram')));
    expect(opened, ['telegram']);
    await tester.pumpWidget(const SizedBox());
    fixture.personal.dispose();
  });

  testWidgets(
    'a signed-out network says so, offers sign-in, hides diagnostics',
    (tester) async {
      final fixture = _Fixture();
      final chats = <Room>[];
      await tester.pumpWidget(
        _host(
          NetworkDetailPage(
            personal: fixture.personal,
            network: 'whatsapp',
            monitor: fixture.monitor,
            onOpenChat: chats.add,
            clock: () => _clock,
          ),
          fixture.client,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('WhatsApp'), findsWidgets);
      expect(find.text('Fictional Account'), findsOneWidget);
      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.text('WhatsApp is signed out'), findsOneWidget);
      expect(find.text('Last message received'), findsNothing);
      await tester.tap(find.text('Sign in'));
      expect(chats, [fixture.management]);

      await tester.ensureVisible(
        find.byKey(const ValueKey('network-advanced')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('network-advanced')));
      await tester.pumpAndSettle();
      expect(find.text('Last message received'), findsOneWidget);
      expect(find.text('Signed out · reported 30 min ago'), findsOneWidget);
      expect(find.text('2 chats · 1 group'), findsOneWidget);
      await tester.ensureVisible(
        find.byKey(const ValueKey('network-bridge-chat')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('network-bridge-chat')));
      expect(chats, [fixture.management, fixture.management]);

      await tester.ensureVisible(
        find.byKey(const ValueKey('network-advanced')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('network-advanced')));
      await tester.pumpAndSettle();
      expect(find.text('Last message received'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      fixture.personal.dispose();
    },
  );

  testWidgets(
    'placement and group notifications save the private network rule',
    (tester) async {
      final fixture = _Fixture();
      final existing = _portal(
        fixture.client,
        'tg-group',
        network: 'telegram',
        bot: _telegramBot,
        kind: 'group',
      );
      await tester.pumpWidget(
        _host(
          NetworkDetailPage(
            personal: fixture.personal,
            network: 'telegram',
            monitor: fixture.monitor,
            clock: () => _clock,
          ),
          fixture.client,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Working normally.'), findsOneWidget);
      // Telegram groups default to their own view.
      final placement = find.byKey(const ValueKey('network-groups-placement'));
      expect(
        find.descendant(of: placement, matching: find.text('Groups')),
        findsWidgets,
      );
      expect(
        InboxProjection(fixture.personal).placementFor(existing),
        ChatPlacement.groups,
      );
      await tester.tap(placement);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Main list'));
      await tester.pumpAndSettle();
      expect(
        fixture.personal.values['network-policy:telegram']?['groupPlacement'],
        'inbox',
      );
      expect(
        InboxProjection(fixture.personal).placementFor(existing),
        ChatPlacement.inbox,
      );

      final groups = find.byKey(const ValueKey('network-group-notifications'));
      await tester.ensureVisible(groups);
      await tester.pumpAndSettle();
      await tester.tap(groups);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Muted').last);
      await tester.pumpAndSettle();
      final discovered = _portal(
        fixture.client,
        'tg-new-group',
        network: 'telegram',
        bot: _telegramBot,
        kind: 'group',
      );
      final projection = InboxProjection(fixture.personal);
      expect(
        projection.notificationModeFor(existing),
        PersonalNotificationMode.muted,
      );
      expect(
        projection.notificationModeFor(discovered),
        PersonalNotificationMode.muted,
      );
      expect(
        projection.notificationModeFor(fixture.telegram),
        PersonalNotificationMode.all,
      );
      expect(fixture.personal.values['network-policy:telegram'], {
        'groupPlacement': 'inbox',
        'notifications': null,
        'groupNotifications': 'muted',
      });
      expect(fixture.personal.writes, [
        'network-policy:telegram',
        'network-policy:telegram',
      ]);
      expect(find.text('Same as all chats'), findsNothing);
      await tester.pumpWidget(const SizedBox());
      fixture.personal.dispose();
    },
  );

  testWidgets('without private sync the rules are read-only with a fix', (
    tester,
  ) async {
    final fixture = _Fixture();
    fixture.personal.available = false;
    await tester.pumpWidget(
      _host(
        NetworkDetailPage(
          personal: fixture.personal,
          network: 'telegram',
          monitor: fixture.monitor,
          clock: () => _clock,
        ),
        fixture.client,
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Private sync is off'), findsOneWidget);
    expect(find.text('Set up'), findsOneWidget);
    for (final key in [
      'network-groups-placement',
      'network-notifications',
      'network-group-notifications',
    ]) {
      expect(
        tester.widget<NotionListRow>(find.byKey(ValueKey(key))).onTap,
        isNull,
      );
    }
    // Status still shows.
    expect(find.text('Connected'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    fixture.personal.dispose();
  });

  for (final width in [320.0, 1100.0]) {
    testWidgets('list and network page fit $width at 200 percent text', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 1000);
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final fixture = _Fixture();
      await tester.pumpWidget(
        _host(
          NetworksPage(
            personal: fixture.personal,
            monitor: fixture.monitor,
            onOpen: (_) {},
          ),
          fixture.client,
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Disconnected'), findsOneWidget);
      await tester.pumpWidget(
        _host(
          NetworkDetailPage(
            personal: fixture.personal,
            network: 'whatsapp',
            monitor: fixture.monitor,
            clock: () => _clock,
          ),
          fixture.client,
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      final advanced = find.byKey(const ValueKey('network-advanced'));
      await tester.ensureVisible(advanced);
      await tester.pumpAndSettle();
      await tester.tap(advanced);
      await tester.pumpAndSettle();
      expect(find.text('Last message received'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      fixture.personal.dispose();
    });
  }
  group('sign out of a network', () {
    /// WhatsApp connected: its last state notice says CONNECTED.
    _Fixture connected() {
      final fixture = _Fixture();
      fixture.db.events[fixture.management.id] = [
        _notice(fixture.management, _whatsappBot, {
          'state_event': 'CONNECTED',
          'timestamp':
              _now
                  .subtract(const Duration(minutes: 3))
                  .millisecondsSinceEpoch ~/
              1000,
          'remote_id': 'login-a',
          'remote_name': 'Fictional Account',
        }, _now.subtract(const Duration(minutes: 3))),
      ];
      return fixture;
    }

    BridgeWhoami whoami({
      String prefix = '!wa',
      String? management,
      List<Map<String, Object?>> logins = const [
        {
          'id': 'login-a',
          'name': 'Fictional Account',
          'state': {'state_event': 'CONNECTED'},
        },
        {
          'id': 'login-old',
          'name': 'Old',
          'state': {'state_event': 'LOGGED_OUT'},
        },
      ],
    }) => BridgeWhoami.fromJson({
      'bridge_bot': _whatsappBot,
      'network': {'displayname': 'WhatsApp', 'network_id': 'whatsapp'},
      'command_prefix': prefix,
      'management_room': ?management,
      'logins': logins,
    })!;

    Future<List<(String, String)>> run(
      _Fixture fixture,
      BridgeWhoamiReader reader,
    ) async {
      void listener() {}
      fixture.monitor.addListener(listener);
      await pumpEventQueue();
      final sent = <(String, String)>[];
      try {
        await NetworkSignOut(
          client: fixture.client,
          monitor: fixture.monitor,
          whoami: reader,
          send: (room, body) async => sent.add((room.id, body)),
        ).signOut('whatsapp');
      } finally {
        fixture.monitor.removeListener(listener);
        fixture.personal.dispose();
      }
      return sent;
    }

    test('whoami gives the login and the exact prefix', () async {
      final fixture = connected();
      final sent = await run(fixture, (_) async => whoami());
      expect(sent, [(fixture.management.id, '!wa logout login-a')]);
    });

    test('in the management room the prefix is not needed', () async {
      final fixture = connected();
      final sent = await run(
        fixture,
        (_) async => whoami(prefix: '', management: fixture.management.id),
      );
      expect(sent, [(fixture.management.id, 'logout login-a')]);
    });

    test('without whoami the login comes from the bridge notice', () async {
      final fixture = connected();
      final sent = await run(
        fixture,
        (_) async => throw const BridgeProvisioningException(404),
      );
      expect(sent, [(fixture.management.id, 'logout login-a')]);
    });

    test('nothing is sent when the account is unknown', () async {
      final fixture = connected();
      fixture.db.events[fixture.management.id] = [];
      await expectLater(
        run(fixture, (_) async => null),
        throwsA(isA<PersonalCapabilityUnavailable>()),
      );
      final signedOut = connected();
      await expectLater(
        run(signedOut, (_) async => whoami(logins: const [])),
        throwsA(
          isA<PersonalCapabilityUnavailable>().having(
            (e) => e.reason,
            'reason',
            'This network is already signed out.',
          ),
        ),
      );
    });

    testWidgets('a connected network offers sign-out behind a confirmation', (
      tester,
    ) async {
      final fixture = connected();
      final signedOut = <String>[];
      await tester.pumpWidget(
        _host(
          NetworkDetailPage(
            personal: fixture.personal,
            network: 'whatsapp',
            monitor: fixture.monitor,
            clock: () => _clock,
            signOut: (network) async => signedOut.add(network),
          ),
          fixture.client,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Connected'), findsOneWidget);
      await tester.tap(find.text('Sign out of WhatsApp'));
      await tester.pumpAndSettle();
      expect(find.text('Sign out of WhatsApp?'), findsOneWidget);
      expect(
        find.text(
          'Chats from this network will stop syncing until you sign in again.',
        ),
        findsOneWidget,
      );
      // Cancel sends nothing.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(signedOut, isEmpty);

      await tester.tap(find.text('Sign out of WhatsApp'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NotionButton, 'Sign out'));
      await tester.pumpAndSettle();
      expect(signedOut, ['whatsapp']);
      expect(find.byKey(const ValueKey('network-sign-out')), findsNothing);
      expect(find.textContaining('Signed out of WhatsApp.'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      fixture.personal.dispose();
    });

    testWidgets('a failed sign-out explains and offers the button again', (
      tester,
    ) async {
      final fixture = connected();
      await tester.pumpWidget(
        _host(
          NetworkDetailPage(
            personal: fixture.personal,
            network: 'whatsapp',
            monitor: fixture.monitor,
            clock: () => _clock,
            signOut: (_) async => throw const PersonalCapabilityUnavailable(
              'ChatLoom couldn’t find your account on this network. '
              'Open the bridge chat to sign out there.',
            ),
          ),
          fixture.client,
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Sign out of WhatsApp'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(NotionButton, 'Sign out'));
      await tester.pumpAndSettle();
      expect(find.text('Could not complete this action'), findsOneWidget);
      expect(find.textContaining('couldn’t find your account'), findsOneWidget);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('network-sign-out')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      fixture.personal.dispose();
    });

    testWidgets('a signed-out network has no sign-out button', (tester) async {
      final fixture = _Fixture();
      await tester.pumpWidget(
        _host(
          NetworkDetailPage(
            personal: fixture.personal,
            network: 'whatsapp',
            monitor: fixture.monitor,
            clock: () => _clock,
            signOut: (_) async => fail('nothing may be sent'),
          ),
          fixture.client,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Disconnected'), findsOneWidget);
      expect(find.byKey(const ValueKey('network-sign-out')), findsNothing);
      await tester.pumpWidget(const SizedBox());
      fixture.personal.dispose();
    });
  });
}
