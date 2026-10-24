// SPDX-License-Identifier: AGPL-3.0-or-later
// Bridge health: notice parsing, verdicts, healing, delivery failures, and
// the live monitor over synthetic rooms (no real ids, no message text).
import 'package:chatloom/personal/bridge_contact_search_provisioning.dart';
import 'package:chatloom/personal/bridge_health.dart';
import 'package:chatloom/personal/bridge_health_monitor.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState, ValueNotifier;
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

const _owner = '@owner:example.invalid';
const _bot = '@sh-whatsappbot:example.invalid';
const _ghost = '@whatsapp_1:example.invalid';

final _t0 = DateTime.utc(2026, 10, 20, 12);

int _seconds(DateTime at) => at.millisecondsSinceEpoch ~/ 1000;

Map<String, Object?> _state(
  String event, {
  DateTime? at,
  String? error,
  String? action,
  String login = 'login-a',
}) => {
  'state_event': event,
  'timestamp': _seconds(at ?? _t0),
  'ttl': 3600,
  'remote_id': login,
  'error': ?error,
  'user_action': ?action,
};

BridgeStateReport _report(
  String event, {
  DateTime? at,
  String? action,
  String login = 'login-a',
}) => BridgeStateReport.parse(
  _state(event, at: at, action: action, login: login),
  network: 'whatsapp',
  fallback: at ?? _t0,
  roomId: '!management:example.invalid',
)!;

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
  _Client(_Db db) : super('synthetic bridge health', database: db);
  @override
  String get userID => _owner;
}

Event _event(
  Room room, {
  required String sender,
  required DateTime at,
  String type = EventTypes.Message,
  Map<String, Object?> content = const {'msgtype': 'm.text', 'body': '-'},
  String id = 'e',
}) => Event(
  room: room,
  type: type,
  content: Map<String, dynamic>.from(content),
  eventId: '\$synthetic-$id-${at.millisecondsSinceEpoch}',
  senderId: sender,
  originServerTs: at,
);

void main() {
  group('BridgeStateReport', () {
    test('parses allowlisted fields and the seconds timestamp', () {
      final report = _report('BAD_CREDENTIALS');
      expect(report.network, 'whatsapp');
      expect(report.at, _t0);
      expect(report.login, 'login-a');
      expect(report.state, BridgeHealthState.loggedOut);
    });

    test('rejects unknown states and malformed content', () {
      expect(
        BridgeStateReport.parse(
          {'state_event': 'SOMETHING'},
          network: 'whatsapp',
          fallback: _t0,
        ),
        isNull,
      );
      expect(
        BridgeStateReport.parse('x', network: 'whatsapp', fallback: _t0),
        isNull,
      );
    });

    test('a bridge clock far in the future falls back to server time', () {
      final report = BridgeStateReport.parse(
        _state('UNKNOWN_ERROR', at: _t0.add(const Duration(days: 3))),
        network: 'whatsapp',
        fallback: _t0,
      )!;
      expect(report.at, _t0);
    });

    test('maps every state to a verdict', () {
      expect(_report('CONNECTED').state, BridgeHealthState.ok);
      expect(_report('BACKFILLING').state, BridgeHealthState.ok);
      expect(_report('CONNECTING').state, BridgeHealthState.degraded);
      // The bridge reconnects by itself: amber.
      expect(_report('TRANSIENT_DISCONNECT').state, BridgeHealthState.degraded);
      expect(_report('UNKNOWN_ERROR').state, BridgeHealthState.disconnected);
      expect(
        _report('BRIDGE_UNREACHABLE').state,
        BridgeHealthState.disconnected,
      );
      expect(_report('LOGGED_OUT').state, BridgeHealthState.loggedOut);
      expect(_report('UNCONFIGURED').state, BridgeHealthState.loggedOut);
      expect(
        _report('CONNECTED', action: 'OPEN_NATIVE').state,
        BridgeHealthState.degraded,
      );
      expect(
        _report('UNKNOWN_ERROR', action: 'RELOGIN').state,
        BridgeHealthState.loggedOut,
      );
    });
  });

  group('evaluateBridgeHealth', () {
    test('no signals is unknown, a CONNECTED notice is ok', () {
      final empty = BridgeSignals();
      expect(
        evaluateBridgeHealth('whatsapp', empty, _t0).state,
        BridgeHealthState.unknown,
      );
      final ok = BridgeSignals()..addReport(_report('CONNECTED'));
      expect(
        evaluateBridgeHealth('whatsapp', ok, _t0).state,
        BridgeHealthState.ok,
      );
    });

    test('the latest notice per login wins; CONNECTED clears an error', () {
      final signals = BridgeSignals()
        ..addReport(_report('BAD_CREDENTIALS'))
        ..addReport(
          _report('CONNECTED', at: _t0.add(const Duration(minutes: 5))),
        );
      expect(
        evaluateBridgeHealth('whatsapp', signals, _t0).state,
        BridgeHealthState.ok,
      );
      // An older notice never replaces a newer one.
      expect(signals.addReport(_report('UNKNOWN_ERROR')), isFalse);
    });

    test('the worst login of a network is shown with a human reason', () {
      final signals = BridgeSignals()
        ..addReport(_report('TRANSIENT_DISCONNECT', login: 'a'))
        ..addReport(_report('BAD_CREDENTIALS', login: 'b'));
      final health = evaluateBridgeHealth(
        'whatsapp',
        signals,
        _t0.add(const Duration(hours: 3)),
      );
      expect(health.state, BridgeHealthState.loggedOut);
      expect(health.title, 'WhatsApp is signed out');
      expect(health.reason, contains('sign in again'));
      expect(health.managementRoomId, '!management:example.invalid');
      expect(
        health.describe(_t0.add(const Duration(hours: 3))),
        endsWith('For 3 h.'),
      );
    });

    test('remote messages after the notice heal a stale problem', () {
      final signals = BridgeSignals()..addReport(_report('UNKNOWN_ERROR'));
      // Within the margin (a backlog flush) the problem stays.
      signals.addInbound(_t0.add(const Duration(seconds: 30)));
      expect(
        evaluateBridgeHealth('whatsapp', signals, _t0).state,
        BridgeHealthState.disconnected,
      );
      signals.addInbound(_t0.add(const Duration(minutes: 10)));
      expect(
        evaluateBridgeHealth('whatsapp', signals, _t0).state,
        BridgeHealthState.ok,
      );
    });

    test('repeated delivery failures without a reply degrade a network', () {
      final signals = BridgeSignals();
      final now = _t0.add(const Duration(minutes: 10));
      signals.addDelivery(BridgeDelivery(at: _t0, failed: true));
      expect(
        evaluateBridgeHealth('whatsapp', signals, now).state,
        BridgeHealthState.unknown,
      );
      signals.addDelivery(
        BridgeDelivery(at: _t0.add(const Duration(minutes: 1)), failed: true),
      );
      final health = evaluateBridgeHealth('whatsapp', signals, now);
      expect(health.state, BridgeHealthState.degraded);
      expect(health.title, 'WhatsApp isn’t delivering messages');
      // Older than the window: quiet again.
      expect(
        evaluateBridgeHealth(
          'whatsapp',
          signals,
          _t0.add(const Duration(hours: 2)),
        ).state,
        isNot(BridgeHealthState.degraded),
      );
      // A later success or remote message ends it.
      signals.addDelivery(
        BridgeDelivery(at: _t0.add(const Duration(minutes: 2)), failed: false),
      );
      expect(
        evaluateBridgeHealth('whatsapp', signals, now).state,
        isNot(BridgeHealthState.degraded),
      );
    });

    test('a new notice changes the signature (dismissal ends)', () {
      final a = evaluateBridgeHealth(
        'whatsapp',
        BridgeSignals()..addReport(_report('UNKNOWN_ERROR')),
        _t0,
      );
      final b = evaluateBridgeHealth(
        'whatsapp',
        BridgeSignals()..addReport(
          _report('UNKNOWN_ERROR', at: _t0.add(const Duration(hours: 1))),
        ),
        _t0,
      );
      expect(a.signature, isNot(b.signature));
      expect(a.signature, isNot(contains('login')));
    });

    test('delivery statuses parse only bridge/network failures', () {
      expect(
        BridgeDelivery.parse({
          'status': 'FAIL_RETRIABLE',
          'reason': 'm.bridge_unavailable',
        }, _t0)?.failed,
        isTrue,
      );
      expect(BridgeDelivery.parse({'status': 'SUCCESS'}, _t0)?.failed, false);
      expect(BridgeDelivery.parse({'status': 'PENDING'}, _t0), isNull);
      expect(
        BridgeDelivery.parse({
          'status': 'FAIL_PERMANENT',
          'reason': 'com.beeper.unsupported_event',
        }, _t0),
        isNull,
      );
    });

    test('bot ids name their network', () {
      expect(bridgeBotNetworkFromId('@sh-whatsappbot:x'), 'whatsapp');
      expect(bridgeBotNetworkFromId('@sh-metabot:x'), 'messenger');
      expect(bridgeBotNetworkFromId('@instagrambot:x'), 'instagram');
      expect(bridgeBotNetworkFromId('@telegramgobot:x'), 'telegram');
      expect(bridgeBotNetworkFromId('@alice:x'), isNull);
    });
  });

  group('BridgeHealthMonitor', () {
    late _Db db;
    late _Client client;
    late Room portal;
    late Room management;
    late DateTime now;

    setUp(() {
      db = _Db();
      client = _Client(db);
      now = _t0.add(const Duration(minutes: 30));
      portal = Room(
        id: '!portal:example.invalid',
        client: client,
        membership: Membership.join,
      );
      portal.setState(
        Event(
          room: portal,
          type: 'm.bridge',
          stateKey: 'bridge',
          content: {
            'bridgebot': _bot,
            'protocol': {'id': 'whatsapp'},
          },
          eventId: r'$synthetic-bridge',
          senderId: _bot,
          originServerTs: _t0,
        ),
      );
      management = Room(
        id: '!management:example.invalid',
        client: client,
        membership: Membership.join,
        summary: RoomSummary.fromJson({
          'm.heroes': [_bot],
          'm.joined_member_count': 2,
          'm.invited_member_count': 0,
        }),
      );
      client.rooms
        ..add(portal)
        ..add(management);
    });

    Future<BridgeHealthMonitor> attached() async {
      final monitor = BridgeHealthMonitor(client, clock: () => now);
      var notified = 0;
      void listener() => notified++;
      monitor.addListener(listener);
      addTearDown(() => monitor.removeListener(listener));
      await pumpEventQueue();
      return monitor;
    }

    test('reads the last stored notice of the management room', () async {
      db.events[management.id] = [
        _event(
          management,
          sender: _bot,
          at: _t0,
          content: {
            'msgtype': 'm.notice',
            'body': '-',
            bridgeStateNoticeKey: _state('BAD_CREDENTIALS'),
          },
        ),
      ];
      final monitor = await attached();
      final problem = monitor.problemFor(portal);
      expect(problem?.state, BridgeHealthState.loggedOut);
      expect(monitor.problems.single.network, 'whatsapp');
      expect(monitor.managementRoom('whatsapp'), same(management));
    });

    test('live notices and remote messages update the verdict', () async {
      final monitor = await attached();
      expect(monitor.problemFor(portal), isNull);
      client.onTimelineEvent.add(
        _event(
          management,
          sender: _bot,
          at: _t0,
          content: {
            'msgtype': 'm.text',
            'body': '-',
            bridgeStateNoticeKey: _state('TRANSIENT_DISCONNECT'),
          },
        ),
      );
      await pumpEventQueue();
      expect(monitor.problemFor(portal)?.state, BridgeHealthState.degraded);
      // A ghost message after the notice proves the bridge works again.
      client.onTimelineEvent.add(
        _event(portal, sender: _ghost, at: _t0.add(const Duration(minutes: 5))),
      );
      await pumpEventQueue();
      expect(monitor.problemFor(portal), isNull);
    });

    test('notices from anyone but a bridge bot are ignored', () async {
      final monitor = await attached();
      client.onTimelineEvent.add(
        _event(
          portal,
          sender: _ghost,
          at: _t0,
          content: {
            'msgtype': 'm.text',
            'body': '-',
            bridgeStateNoticeKey: _state('BAD_CREDENTIALS'),
          },
        ),
      );
      await pumpEventQueue();
      expect(monitor.problems, isEmpty);
    });

    test('bridge delivery failures degrade the network', () async {
      final monitor = await attached();
      for (var i = 0; i < 2; i++) {
        client.onTimelineEvent.add(
          _event(
            portal,
            sender: _bot,
            at: _t0.add(Duration(minutes: 20 + i)),
            type: bridgeMessageStatusType,
            content: {
              'status': 'FAIL_RETRIABLE',
              'reason': 'm.foreign_network_error',
            },
            id: 'status$i',
          ),
        );
      }
      await pumpEventQueue();
      expect(monitor.problemFor(portal)?.state, BridgeHealthState.degraded);
    });
  });

  group('live status from whoami (BR-01/BR-02)', () {
    BridgeStateReport live(
      String event, {
      DateTime? at,
      String login = 'login-a',
      String? error,
    }) => BridgeStateReport.fromLogin(
      network: 'whatsapp',
      loginId: login,
      loginName: 'Fictional Account',
      state: _state(event, at: at, login: login, error: error),
      fetchedAt: at ?? _t0,
    )!;

    BridgeHealth verdict(BridgeSignals signals, DateTime now) =>
        evaluateBridgeHealth('whatsapp', signals, now);

    test('a whoami login keeps its id, name and state', () {
      final report = live('BAD_CREDENTIALS', error: 'wa-logged-out');
      expect(report.live, isTrue);
      expect(report.login, 'login-a');
      expect(report.remoteName, 'Fictional Account');
      expect(report.error, 'wa-logged-out');
      final legacy = BridgeLogin.fromJson({
        'id': 'login-b',
        'state_event': 'CONNECTED',
      });
      expect(legacy?.stateDetails, {'state_event': 'CONNECTED'});
    });

    test('signed out shows at once, with a stable signature', () {
      final signals = BridgeSignals()..setLive([live('BAD_CREDENTIALS')], _t0);
      final health = verdict(signals, _t0);
      expect(health.state, BridgeHealthState.loggedOut);
      expect(health.title, 'WhatsApp is signed out');
      expect(health.signedIn, isFalse);
      signals.setLive([
        live('BAD_CREDENTIALS', at: _t0.add(const Duration(minutes: 5))),
      ], _t0.add(const Duration(minutes: 5)));
      final later = verdict(signals, _t0.add(const Duration(minutes: 5)));
      // The same state repeated keeps its identity and its start.
      expect(later.signature, health.signature);
      expect(later.since, _t0);
    });

    test('a passing state stays hidden for 3 minutes, then shows', () {
      final signals = BridgeSignals()
        ..setLive([live('TRANSIENT_DISCONNECT')], _t0);
      final early = verdict(signals, _t0.add(const Duration(minutes: 2)));
      expect(early.state, BridgeHealthState.ok);
      expect(
        nextBridgeHealthChange(signals, _t0.add(const Duration(minutes: 2))),
        _t0.add(BridgeHealthRules.transientDelay),
      );
      // A later answer repeating the state counts from its start.
      signals.setLive([
        live('TRANSIENT_DISCONNECT', at: _t0.add(const Duration(minutes: 2))),
      ], _t0.add(const Duration(minutes: 2)));
      final late = verdict(signals, _t0.add(const Duration(minutes: 3)));
      expect(late.state, BridgeHealthState.degraded);
      expect(late.summary, 'Reconnecting');
      expect(late.stateEvent, 'TRANSIENT_DISCONNECT');
      final error = BridgeSignals()..setLive([live('UNKNOWN_ERROR')], _t0);
      expect(
        verdict(error, _t0.add(const Duration(minutes: 1))).state,
        BridgeHealthState.ok,
      );
      expect(
        verdict(error, _t0.add(const Duration(minutes: 4))).state,
        BridgeHealthState.disconnected,
      );
    });

    test('no login at all is "Not signed in"', () {
      final signals = BridgeSignals()..setLive(const [], _t0);
      final health = verdict(signals, _t0);
      expect(health.state, BridgeHealthState.loggedOut);
      expect(health.summary, 'Not signed in');
      expect(health.signature, 'bridge:whatsapp:UNCONFIGURED:');
    });

    test('a current CONNECTED heals an old notice and allows sign-out', () {
      final signals = BridgeSignals()
        ..addReport(_report('BAD_CREDENTIALS'))
        ..setLive([
          live('CONNECTED', at: _t0.add(const Duration(minutes: 1))),
        ], _t0.add(const Duration(minutes: 1)));
      final health = verdict(signals, _t0.add(const Duration(minutes: 2)));
      expect(health.state, BridgeHealthState.ok);
      expect(health.signedIn, isTrue);
      // An answer older than the TTL is no evidence any more.
      final stale = verdict(signals, _t0.add(const Duration(hours: 1)));
      expect(stale.state, BridgeHealthState.loggedOut);
    });

    test('an old remote message alone is not "Connected"', () {
      final signals = BridgeSignals()..addInbound(_t0);
      expect(
        verdict(signals, _t0.add(const Duration(minutes: 10))).state,
        BridgeHealthState.ok,
      );
      final old = verdict(signals, _t0.add(const Duration(hours: 2)));
      expect(old.state, BridgeHealthState.unknown);
      expect(old.summary, 'Status unknown');
      expect(old.signedIn, isFalse);
    });

    test('a bridge that can’t be asked is "Status unknown", never healthy', () {
      final signals = BridgeSignals()..liveUnavailable = true;
      final health = verdict(signals, _t0);
      expect(health.state, BridgeHealthState.unknown);
      expect(health.unavailable, isTrue);
      expect(health.reason, contains('can’t check'));
      final checking = BridgeSignals()..liveChecking = true;
      expect(verdict(checking, _t0).checking, isTrue);
    });

    test('a sign-out from this device holds until the bridge confirms', () {
      final signals = BridgeSignals()
        ..setLive([live('CONNECTED')], _t0)
        ..signedOutAt = _t0.add(const Duration(seconds: 10));
      // An answer right after the command may still list the login.
      signals.setLive([
        live('CONNECTED', at: _t0.add(const Duration(seconds: 30))),
      ], _t0.add(const Duration(seconds: 30)));
      final pending = verdict(signals, _t0.add(const Duration(seconds: 40)));
      expect(pending.state, BridgeHealthState.loggedOut);
      expect(pending.userInitiated, isTrue);
      expect(pending.signedIn, isFalse);
      expect(pending.title, 'You signed out of WhatsApp');
      // The bridge confirms: no login left; still the user's own sign-out.
      signals.setLive(const [], _t0.add(const Duration(minutes: 3)));
      final confirmed = verdict(signals, _t0.add(const Duration(minutes: 3)));
      expect(confirmed.state, BridgeHealthState.loggedOut);
      expect(confirmed.userInitiated, isTrue);
      // Signed in again later: connected, the sign-out is forgotten.
      signals.setLive([
        live('CONNECTED', at: _t0.add(const Duration(minutes: 10))),
      ], _t0.add(const Duration(minutes: 10)));
      expect(signals.signedOutAt, isNull);
      expect(
        verdict(signals, _t0.add(const Duration(minutes: 10))).state,
        BridgeHealthState.ok,
      );
    });

    test('an outdated WhatsApp bridge says so', () {
      final signals = BridgeSignals()
        ..setLive([live('UNKNOWN_ERROR', error: 'wa-client-outdated')], _t0);
      final health = verdict(signals, _t0.add(const Duration(minutes: 5)));
      expect(health.title, 'WhatsApp bridge needs an update');
    });
  });

  group('BridgeHealthMonitor with whoami', () {
    late _Client client;
    late DateTime now;
    late Room portal;

    Room bridged(String id, String bot, String network) {
      final room = Room(
        id: '!$id:example.invalid',
        client: client,
        membership: Membership.join,
      );
      room.setState(
        Event(
          room: room,
          type: 'm.bridge',
          stateKey: 'bridge',
          content: {
            'bridgebot': bot,
            'protocol': {'id': network},
          },
          eventId: '\$synthetic-bridge-$id',
          senderId: bot,
          originServerTs: _t0,
        ),
      );
      client.rooms.add(room);
      return room;
    }

    BridgeWhoami whoami(String bot, List<Map<String, Object?>> logins) =>
        BridgeWhoami.fromJson({
          'bridge_bot': bot,
          'network': {'displayname': 'X', 'network_id': 'x'},
          'logins': logins,
        })!;

    setUp(() {
      client = _Client(_Db());
      now = _t0;
      portal = bridged('portal', _bot, 'whatsapp');
    });

    Future<BridgeHealthMonitor> attached(BridgeWhoamiLoader loader) async {
      final monitor = BridgeHealthMonitor(
        client,
        clock: () => now,
        whoami: loader,
        watchLifecycle: false,
      );
      void listener() {}
      monitor.addListener(listener);
      addTearDown(() => monitor.removeListener(listener));
      await pumpEventQueue();
      return monitor;
    }

    test('attaching asks the bridge once; its answer is the status', () async {
      var calls = 0;
      final monitor = await attached((bridge) async {
        calls++;
        return whoami(_bot, [
          {
            'id': 'login-a',
            'name': 'Fictional Account',
            'state': _state('BAD_CREDENTIALS'),
          },
        ]);
      });
      await pumpEventQueue();
      expect(calls, 1);
      expect(monitor.problemFor(portal)?.state, BridgeHealthState.loggedOut);
      // A network page asks again only after a minute.
      await monitor.refresh('whatsapp');
      expect(calls, 1);
      now = now.add(const Duration(minutes: 2));
      await monitor.refresh('whatsapp');
      expect(calls, 2);
    });

    test('no route means "Status unknown"; failures back off', () async {
      final unavailable = await attached((_) async => null);
      await pumpEventQueue();
      final health = unavailable.health['whatsapp'];
      expect(health?.state, BridgeHealthState.unknown);
      expect(health?.unavailable, isTrue);
    });

    test('a failing bridge, while others answer, is not responding', () async {
      final other = bridged('tg', '@telegrambot:example.invalid', 'telegram');
      expect(other.id, isNotEmpty);
      var fail = false;
      final monitor = await attached((bridge) async {
        if (bridge.network == 'whatsapp' && fail) {
          throw const BridgeProvisioningException(502);
        }
        return whoami(bridge.botId, [
          {'id': 'login-a', 'name': '', 'state': _state('CONNECTED', at: now)},
        ]);
      });
      await pumpEventQueue();
      expect(monitor.health['whatsapp']?.state, BridgeHealthState.ok);
      fail = true;
      for (final minutes in [1, 3, 5]) {
        now = _t0.add(Duration(minutes: minutes));
        await monitor.refresh('whatsapp', force: true);
        await monitor.refresh('telegram', force: true);
      }
      final health = monitor.health['whatsapp'];
      expect(health?.state, BridgeHealthState.disconnected);
      expect(health?.title, 'WhatsApp bridge isn’t responding');
      expect(monitor.health['telegram']?.state, BridgeHealthState.ok);
    });

    test('sign-out reads as signed out at once (CC-25)', () async {
      final monitor = await attached(
        (_) async => whoami(_bot, [
          {'id': 'login-a', 'name': '', 'state': _state('CONNECTED', at: now)},
        ]),
      );
      await pumpEventQueue();
      expect(monitor.health['whatsapp']?.signedIn, isTrue);
      monitor.noteSignedOut('whatsapp');
      final health = monitor.health['whatsapp'];
      expect(health?.state, BridgeHealthState.loggedOut);
      expect(health?.userInitiated, isTrue);
      expect(health?.signedIn, isFalse);
    });

    test('only an app in front polls: inactive and a hidden Mac window '
        'wait; coming back asks due bridges (BP-03)', () async {
      var calls = 0;
      final visible = ValueNotifier(true);
      addTearDown(visible.dispose);
      final monitor = BridgeHealthMonitor(
        client,
        clock: () => now,
        whoami: (_) async {
          calls++;
          return whoami(_bot, []);
        },
        watchLifecycle: false,
        windowVisible: visible,
      );
      void listener() {}
      monitor.addListener(listener);
      addTearDown(() => monitor.removeListener(listener));
      await pumpEventQueue();
      expect(calls, 1);
      expect(monitor.debugPollScheduled, isTrue);

      monitor.didChangeAppLifecycleState(AppLifecycleState.inactive);
      expect(monitor.debugPollScheduled, isFalse);
      now = now.add(const Duration(minutes: 10));
      monitor.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(calls, 2, reason: 'the overdue bridge is asked at once');
      expect(monitor.debugPollScheduled, isTrue);

      visible.value = false;
      expect(monitor.debugPollScheduled, isFalse);
      visible.value = true;
      expect(monitor.debugPollScheduled, isTrue);
    });
  });
}
