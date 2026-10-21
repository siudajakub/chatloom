// SPDX-License-Identifier: AGPL-3.0-or-later
// Bridge health: notice parsing, verdicts, healing, delivery failures, and
// the live monitor over synthetic rooms (no real ids, no message text).
import 'package:chatloom/personal/bridge_health.dart';
import 'package:chatloom/personal/bridge_health_monitor.dart';
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
      expect(
        _report('TRANSIENT_DISCONNECT').state,
        BridgeHealthState.disconnected,
      );
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
        BridgeSignals()
          ..addReport(
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
      expect(
        monitor.problemFor(portal)?.state,
        BridgeHealthState.disconnected,
      );
      // A ghost message after the notice proves the bridge works again.
      client.onTimelineEvent.add(
        _event(
          portal,
          sender: _ghost,
          at: _t0.add(const Duration(minutes: 5)),
        ),
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
}
