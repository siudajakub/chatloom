// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';
import 'dart:io';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/message_notification.dart';
import 'package:chatloom/personal/notification_threads.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/personal/seen_chat_notifications.dart';
import 'package:chatloom/personal/storage/personal_store.dart';
import 'package:chatloom/utils/background_push_catch_up.dart';
import 'package:chatloom/utils/notification_client_routing.dart';
import 'package:chatloom/utils/push_helper.dart';
import 'package:chatloom/utils/start_push_foreground_service.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '@synthetic-owner:example.invalid';
const _peer = '@synthetic-peer:example.invalid';
const _roomId = '!synthetic-room:example.invalid';
const _eventId = r'$synthetic-event';
const _secondRoomId = '!synthetic-second:example.invalid';
const _bot = '@synthetic-bridge-bot:example.invalid';
const _groupId = 'synthetic-person';

class _Database implements DatabaseApi {
  final events = <String, Event>{};
  @override
  Future<Event?> getEventById(String id, Room room) async => events[id];
  @override
  Future<User?> getUser(String userId, Room room) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database operation');
}

class _Store implements PersonalStore {
  final records = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, Map<String, dynamic>>> readPrefix(String prefix) async => {
    for (final entry in records.entries)
      if (entry.key.startsWith(prefix)) entry.key: entry.value,
  };
  @override
  Future<Map<String, dynamic>?> get(String key) async => records[key];
  @override
  Future<void> put(String key, Map<String, dynamic> value) async =>
      records[key] = value;
  @override
  Future<void> delete(String key) async => records.remove(key);
  @override
  Future<void> close() async {}
}

class _PushClient extends Client {
  _PushClient(super.name, this.db, {this.logged = true}) : super(database: db);
  final _Database db;
  bool logged;
  Future<Event?> Function()? fetch;
  int fetches = 0;
  int syncs = 0;
  bool? returnNullIfSeen;

  @override
  Future<void> oneShotSync({
    Duration? timeout,
    Duration? responseTimeout,
  }) async => syncs++;

  @override
  bool isLogged() => logged;
  @override
  String? get userID => _owner;
  @override
  String? get deviceID => 'SYNTHETIC';
  @override
  PushruleEvaluator get pushruleEvaluator => PushruleEvaluator.fromRuleset(
    PushRuleSet(
      underride: [
        PushRule(
          actions: ['notify'],
          conditions: [],
          default$: true,
          enabled: true,
          ruleId: 'synthetic.notify_all',
        ),
      ],
    ),
  );
  @override
  Future<Event?> getEventByPushNotification(
    PushNotification notification, {
    bool storeInDatabase = true,
    Duration timeoutForServerRequests = const Duration(seconds: 8),
    bool returnNullIfSeen = true,
  }) async {
    fetches++;
    this.returnNullIfSeen = returnNullIfSeen;
    return fetch!();
  }
}

class _Shown {
  final int id;
  final String? title, body, payload;
  final NotificationDetails? details;
  _Shown(this.id, this.title, this.body, this.payload, this.details);
}

class _Notifications implements FlutterLocalNotificationsPlugin {
  final shown = <_Shown>[];
  final cancelled = <int>[];
  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async {
    shown.add(_Shown(id, title, body, payload, notificationDetails));
  }

  @override
  Future<void> cancel({required int id, String? tag}) async {
    cancelled.add(id);
  }

  final active = <ActiveNotification>[];

  @override
  Future<List<ActiveNotification>> getActiveNotifications() async => active;

  @override
  T? resolvePlatformSpecificImplementation<
    T extends FlutterLocalNotificationsPlatform
  >() => null;

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected notification operation');
}

class _Fixture {
  final client = _PushClient('synthetic-account', _Database());
  final store = _Store();
  late final PersonalClient personal = PersonalClient.forTesting(
    client,
    openStore: () async => store,
  );
  final plugin = _Notifications();
  late final Room room = Room(id: _roomId, client: client);

  _Fixture({bool direct = true}) {
    client.rooms.add(room);
    if (direct) {
      client.accountData['m.direct'] = BasicEvent(
        type: 'm.direct',
        content: {
          _peer: [_roomId],
        },
      );
    }
  }

  void mode(PersonalNotificationMode mode) {
    store.records['account:$_owner:value:org:$_roomId'] = {
      'value': ConversationMetadata(
        entityId: _roomId,
      ).setNotificationMode(mode).toJson().cast<String, dynamic>(),
      'revision': 1,
    };
  }

  /// Merges [room] with a second direct chat of the same person.
  Room merge() {
    final second = Room(id: _secondRoomId, client: client);
    client.rooms.add(second);
    client.accountData['m.direct'] = BasicEvent(
      type: 'm.direct',
      content: {
        _peer: [_roomId, _secondRoomId],
      },
    );
    store.records['account:$_owner:value:person:$_groupId'] = {
      'value': PersonGroup(
        id: _groupId,
        name: 'Synthetic person',
        members: [
          ConversationRef(accountId: _owner, roomId: _roomId),
          ConversationRef(accountId: _owner, roomId: _secondRoomId),
        ],
        defaultRoomId: _roomId,
      ).toJson().cast<String, dynamic>(),
      'revision': 1,
    };
    return second;
  }

  Event event({
    String id = _eventId,
    String sender = _peer,
    String body = 'Synthetic preview text',
    DateTime? at,
    Room? inRoom,
  }) => Event(
    room: inRoom ?? room,
    type: EventTypes.Message,
    eventId: id,
    senderId: sender,
    originServerTs: at ?? DateTime.utc(2026, 10, 17, 12),
    content: {'msgtype': 'm.text', 'body': body},
  );

  Future<void> push({
    List<Client>? clients,
    String eventId = _eventId,
    String roomId = _roomId,
    bool test = false,
  }) async {
    final outcome = await pushHelper(
      PushNotification(
        roomId: roomId,
        eventId: eventId,
        counts: const PushNotificationCounts(unread: 1),
        devices: const [],
      ),
      clients: clients ?? [client],
      flutterLocalNotificationsPlugin: plugin,
      test: test,
    );
    // The background catch-up decides on the returned outcome.
    expect(outcome, await _lastOutcome());
  }

  /// The catch-up backlog of [arrived] at 13:00 on the fixture's day.
  Future<int> backlog(List<Event> arrived, {int perThread = 3}) =>
      pushBacklogHelper(
        client,
        arrived,
        plugin: plugin,
        perThread: perThread,
        now: () => DateTime.utc(2026, 10, 17, 13),
      );
}

Future<PushOutcome?> _lastOutcome() async =>
    (await PushDiagnostics.read()).last?.outcome;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const sentinel = 'synthetic-service';
  final fixtures = <_Fixture>[];

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.personalNotificationPreviews.setItem(true);
    await AppSettings.personalIncognito.setItem(true);
    await PushDiagnostics.reset();
    ForegroundServices.runningServices.add(sentinel);
    debugAppLockConfigured = () async => false;
    NotificationThreads.debugReset();
    // AppSettings keeps one preferences instance for the whole file: forget
    // the messages earlier tests notified.
    await NotifiedMessages.saved;
    NotifiedMessages.debugReset();
    await AppSettings.store.remove(NotifiedMessages.storeKey);
    pushFetchRetryDelay = const Duration(milliseconds: 10);
  });

  tearDown(() {
    pushFetchRetryDelay = const Duration(seconds: 3);
    debugAppLockConfigured = null;
    ForegroundServices.runningServices.remove(sentinel);
    pushPersonalClientOf = PersonalClient.of;
    for (final fixture in fixtures) {
      fixture.personal.dispose();
    }
    fixtures.clear();
  });

  _Fixture fixture({bool direct = true}) {
    final value = _Fixture(direct: direct);
    fixtures.add(value);
    pushPersonalClientOf = (_) => value.personal;
    return value;
  }

  test('a push without an account goes to the single signed-in account, '
      'with the id cancel and summary use', () async {
    final f = fixture();
    final signedOut = _PushClient('signed-out', _Database(), logged: false);
    f.client.fetch = () async => f.event();
    await f.push(clients: [signedOut, f.client]);
    expect(f.plugin.shown, hasLength(1));
    final shown = f.plugin.shown.single;
    expect(shown.id, messageNotificationId('synthetic-account', _roomId));
    expect(
      ChatLoomPushPayload.fromString(shown.payload!).clientName,
      'synthetic-account',
    );
    expect(f.client.returnNullIfSeen, isFalse);
    expect(await _lastOutcome(), PushOutcome.shown);
  });

  test(
    'two signed-in accounts and no account in the push stay ambiguous',
    () async {
      final f = fixture();
      final other = _PushClient('other', _Database());
      f.client.fetch = () async => f.event();
      await f.push(clients: [other, f.client]);
      expect(f.plugin.shown, isEmpty);
      expect(f.client.fetches, 0);
      expect(await _lastOutcome(), PushOutcome.noClient);
    },
  );

  test('message preview: sender title, decrypted text, private visibility, '
      'Messages channel, inline Reply and a private Mark as read under '
      'incognito', () async {
    final f = fixture();
    f.client.fetch = () async => f.event();
    await f.push();
    final shown = f.plugin.shown.single;
    expect(shown.title, 'Synthetic-peer');
    expect(shown.body, 'Synthetic preview text');
    final android = shown.details!.android!;
    expect(android.channelId, 'chatloom_messages_v2');
    expect(android.channelName, 'Messages');
    // The channel's short buzz and own sound, also for Android 7.
    expect(android.vibrationPattern, [0, 120]);
    expect(android.enableVibration, isTrue);
    expect(android.playSound, isTrue);
    expect(
      (android.sound! as RawResourceAndroidNotificationSound).sound,
      'chatloom_message',
    );
    expect(android.visibility, NotificationVisibility.private);
    // Incognito reads privately (CS-32): same action as without it.
    expect(android.actions!.map((a) => a.id), ['reply', 'markAsRead']);
    final reply = android.actions!.first;
    expect(reply.title, 'Reply');
    expect(reply.inputs.single.label, 'Message');
    expect(reply.semanticAction, SemanticAction.reply);
    expect(reply.showsUserInterface, isFalse);
    // Android's sending state stays until the outcome replaces it.
    expect(reply.cancelNotification, isFalse);
    expect(android.actions!.last.title, 'Mark as read');
  });

  test('no inline Reply where the account cannot write or on the '
      'diagnostics test', () async {
    final f = fixture();
    f.room.setState(
      Event(
        room: f.room,
        type: EventTypes.RoomPowerLevels,
        stateKey: '',
        eventId: r'$synthetic-power-levels',
        senderId: _peer,
        originServerTs: DateTime.utc(2026, 10, 17),
        content: {
          'events_default': 50,
          'users': {_peer: 100},
        },
      ),
    );
    f.client.fetch = () async => f.event();
    await f.push();
    expect(f.plugin.shown.last.details!.android!.actions!.map((a) => a.id), [
      'markAsRead',
    ]);
    final g = fixture();
    g.client.fetch = () async => g.event();
    await g.push(test: true);
    expect(g.plugin.shown.last.details!.android!.actions!.map((a) => a.id), [
      'markAsRead',
    ]);
  });

  test('previews off keep the generic text and only Mark as read', () async {
    final f = fixture();
    await AppSettings.personalNotificationPreviews.setItem(false);
    await AppSettings.personalIncognito.setItem(false);
    f.client.fetch = () async => f.event();
    await f.push();
    final shown = f.plugin.shown.single;
    expect(shown.title, 'ChatLoom');
    expect(shown.body, 'Open the app to read your message.');
    // Without previews the chat is not named, so there is no blind Reply.
    expect(shown.details!.android!.actions!.single.id, 'markAsRead');
  });

  test('with the app lock set, previews on still show no sender, chat or '
      'text, and keep private visibility', () async {
    final f = fixture();
    debugAppLockConfigured = () async => true;
    f.client.fetch = () async => f.event();
    await f.push();
    final shown = f.plugin.shown.single;
    expect(shown.title, 'New message');
    expect(shown.body, 'Open the app to read');
    final android = shown.details!.android!;
    expect(android.styleInformation, isNull);
    expect(android.visibility, NotificationVisibility.private);
    // The app lock requires opening (and unlocking) the app to reply.
    expect(android.actions!.map((a) => a.id), ['markAsRead']);
    expect(await _lastOutcome(), PushOutcome.shown);
  });

  test('the generic fallback alert also hides the chat name under the app '
      'lock', () async {
    final f = fixture();
    debugAppLockConfigured = () async => true;
    f.client.fetch = () async =>
        throw TimeoutException('Synthetic unresolved event');
    await expectLater(f.push(), throwsA(isA<TimeoutException>()));
    final shown = f.plugin.shown.single;
    expect(shown.title, 'New message');
    expect(shown.body, 'Open the app to read');
  });

  test('fallback eligibility is decided before the fetch: a known chat that '
      'notifies for everything gets a generic alert on timeout', () async {
    final f = fixture();
    f.client.fetch = () async =>
        throw TimeoutException('Synthetic unresolved event');
    await expectLater(f.push(), throwsA(isA<TimeoutException>()));
    final shown = f.plugin.shown.single;
    expect(shown.id, messageNotificationId('synthetic-account', _roomId));
    expect(shown.body, 'Open the app to read your message.');
    expect(await _lastOutcome(), PushOutcome.shownFallback);
  });

  test('an unknown chat never falls back to a generic alert', () async {
    final f = fixture();
    f.client.rooms.clear();
    f.client.fetch = () async =>
        throw TimeoutException('Synthetic unresolved event');
    await expectLater(f.push(), throwsA(isA<TimeoutException>()));
    expect(f.plugin.shown, isEmpty);
    expect(await _lastOutcome(), PushOutcome.timeout);
  });

  test('a privately muted chat is skipped without any fetch', () async {
    final f = fixture();
    f.mode(PersonalNotificationMode.muted);
    f.client.fetch = () async => f.event();
    await f.push();
    expect(f.client.fetches, 0);
    expect(f.plugin.shown, isEmpty);
    expect(await _lastOutcome(), PushOutcome.muted);
  });

  test('mentions-only chats neither alert nor fall back', () async {
    final f = fixture();
    f.mode(PersonalNotificationMode.mentionsOnly);
    f.client.fetch = () async =>
        throw TimeoutException('Synthetic unresolved event');
    await expectLater(f.push(), throwsA(isA<TimeoutException>()));
    expect(f.plugin.shown, isEmpty);
    f.client.fetch = () async => f.event();
    await f.push();
    expect(f.plugin.shown, isEmpty);
    expect(await _lastOutcome(), PushOutcome.mentionsOnly);
  });

  test('own messages never alert', () async {
    final f = fixture();
    f.client.fetch = () async => f.event(sender: _owner);
    await f.push();
    expect(f.plugin.shown, isEmpty);
    expect(await _lastOutcome(), PushOutcome.own);
  });

  test('a message read on another device is cleared, not shown; the test '
      'notification bypasses only that check', () async {
    final f = fixture();
    f.room.roomAccountData['m.fully_read'] = BasicEvent(
      type: 'm.fully_read',
      content: {'event_id': _eventId},
    );
    f.client.fetch = () async => f.event();
    await f.push();
    expect(f.plugin.shown, isEmpty);
    expect(
      f.plugin.cancelled,
      contains(messageNotificationId('synthetic-account', _roomId)),
    );
    expect(await _lastOutcome(), PushOutcome.seen);
    await f.push(test: true);
    expect(f.plugin.shown.single.title, 'Synthetic-peer (test)');
    expect(await _lastOutcome(), PushOutcome.shown);
  });

  test('a newer locally known read position hides an older message, an older '
      'one does not (no ten-minute slack)', () async {
    final f = fixture();
    f.room.roomAccountData['m.fully_read'] = BasicEvent(
      type: 'm.fully_read',
      content: {'event_id': r'$synthetic-marker'},
    );
    final message = f.event(at: DateTime.utc(2026, 10, 17, 12));
    f.client.db.events[r'$synthetic-marker'] = f.event(
      id: r'$synthetic-marker',
      at: DateTime.utc(2026, 10, 17, 11, 55),
    );
    f.client.fetch = () async => message;
    await f.push();
    expect(f.plugin.shown, hasLength(1));
    f.client.db.events[r'$synthetic-marker'] = f.event(
      id: r'$synthetic-marker',
      at: DateTime.utc(2026, 10, 17, 12, 1),
    );
    await f.push();
    expect(f.plugin.shown, hasLength(1));
    expect(await _lastOutcome(), PushOutcome.seen);
  });

  testWidgets('a push for a room shown on an open merged person page stays '
      'silent, like the open single chat', (tester) async {
    final f = fixture();
    SeenChatNotifications.debugSurfaceVisible = () => true;
    addTearDown(() {
      SeenChatNotifications.debugSurfaceVisible = null;
      SeenChatNotifications.debugReset();
    });
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    late BuildContext page;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) {
            page = context;
            return const SizedBox.expand();
          },
        ),
      ),
    );
    // The merged page reports its source rooms; the route has no room id.
    SeenChatNotifications.seen(page, [f.room], atBottom: () => false);
    f.client.fetch = () async => f.event();
    await tester.runAsync(f.push);
    expect(f.plugin.shown, isEmpty);
    expect(await tester.runAsync(_lastOutcome), PushOutcome.activeRoom);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(f.push);
    expect(f.plugin.shown, hasLength(1));
  });

  test(
    'a group message shows the chat as title and the sender in the body',
    () async {
      final f = fixture(direct: false);
      f.client.fetch = () async => f.event();
      await f.push();
      final shown = f.plugin.shown.single;
      expect(shown.body, 'Synthetic-peer: Synthetic preview text');
    },
  );

  test('count-only pushes in a burst sync once and still clear read chats '
      '(BP-06a)', () async {
    final f = fixture();
    final other = Room(
      id: _secondRoomId,
      client: f.client,
      notificationCount: 1,
    );
    f.client.rooms.add(other);
    final read = messageNotificationId('synthetic-account', _roomId);
    Future<void> countPush() async {
      f.plugin.active
        ..clear()
        ..add(ActiveNotification(id: read, groupKey: 'synthetic-account'));
      expect(
        await pushHelper(
          PushNotification(
            counts: const PushNotificationCounts(unread: 1),
            devices: const [],
          ),
          clients: [f.client],
          flutterLocalNotificationsPlugin: f.plugin,
        ),
        PushOutcome.cleared,
      );
    }

    await countPush();
    await countPush();
    expect(f.client.syncs, 1, reason: 'the second count matches local state');
    expect(f.plugin.cancelled, [read, read]);
  });

  group('one notification per merged person', () {
    test('messages from both networks of a person replace one notification '
        'titled by the person; each tap opens the network of its message', () async {
      final f = fixture();
      final second = f.merge();
      f.client.fetch = () async => f.event(id: r'$first');
      await f.push(eventId: r'$first');
      f.client.fetch = () async => f.event(
        id: r'$second',
        inRoom: second,
        at: DateTime.utc(2026, 10, 17, 12, 1),
      );
      await f.push(eventId: r'$second', roomId: _secondRoomId);
      final person = personNotificationId('synthetic-account', _groupId);
      expect(f.plugin.shown.map((n) => n.id), [person, person]);
      expect(f.plugin.shown.map((n) => n.title), [
        'Synthetic person',
        'Synthetic person',
      ]);
      final payloads = [
        for (final n in f.plugin.shown) ChatLoomPushPayload.fromString(n.payload!),
      ];
      expect(payloads.map((p) => p.roomId), [_roomId, _secondRoomId]);
      expect(payloads.last.eventId, r'$second');
    });

    test('an older message handled after a newer one keeps the newer one as '
        'tap target and time', () async {
      final f = fixture();
      final second = f.merge();
      final newer = DateTime.utc(2026, 10, 17, 12, 5);
      f.client.fetch = () async =>
          f.event(id: r'$newer', inRoom: second, at: newer);
      await f.push(eventId: r'$newer', roomId: _secondRoomId);
      f.client.fetch = () async => f.event(id: r'$older');
      await f.push(eventId: r'$older');
      final last = f.plugin.shown.last;
      final payload = ChatLoomPushPayload.fromString(last.payload!);
      expect(payload.roomId, _secondRoomId);
      expect(payload.eventId, r'$newer');
      expect(last.details!.android!.when, newer.millisecondsSinceEpoch);
    });

    test('read on another device: the network\'s own notification goes; the '
        'shared one stays while the other network is unread', () async {
      final f = fixture();
      final second = f.merge();
      second.lastEvent = f.event(
        id: r'$unread-elsewhere',
        inRoom: second,
        at: DateTime.utc(2026, 10, 17, 11),
      );
      f.room.roomAccountData['m.fully_read'] = BasicEvent(
        type: 'm.fully_read',
        content: {'event_id': _eventId},
      );
      f.client.fetch = () async => f.event();
      await f.push();
      expect(await _lastOutcome(), PushOutcome.seen);
      final person = personNotificationId('synthetic-account', _groupId);
      expect(
        f.plugin.cancelled,
        contains(messageNotificationId('synthetic-account', _roomId)),
      );
      expect(f.plugin.cancelled, isNot(contains(person)));

      second.roomAccountData['m.fully_read'] = BasicEvent(
        type: 'm.fully_read',
        content: {'event_id': r'$unread-elsewhere'},
      );
      await f.push();
      expect(f.plugin.cancelled, contains(person));
    });
  });

  group('missed pushes (2026-10-27)', () {
    test('a fetch that failed on the network is retried once and then '
        'shows the message', () async {
      final f = fixture();
      f.client.fetch = () async {
        if (f.client.fetches == 1) {
          throw const SocketException('Synthetic network down');
        }
        return f.event();
      };
      await f.push();
      expect(f.client.fetches, 2);
      expect(f.plugin.shown.single.body, 'Synthetic preview text');
      expect(await _lastOutcome(), PushOutcome.shown);
    });

    test('a second network failure is not retried again: the generic '
        'fallback follows', () async {
      final f = fixture();
      f.client.fetch = () async =>
          throw const SocketException('Synthetic network down');
      PushOutcome? reported;
      await expectLater(
        pushHelper(
          PushNotification(
            roomId: _roomId,
            eventId: _eventId,
            counts: const PushNotificationCounts(unread: 1),
            devices: const [],
          ),
          clients: [f.client],
          flutterLocalNotificationsPlugin: f.plugin,
          onOutcome: (outcome) => reported = outcome,
        ),
        throwsA(isA<SocketException>()),
      );
      expect(f.client.fetches, 2);
      expect(reported, PushOutcome.shownFallback);
      expect(f.plugin.shown.single.body, 'Open the app to read your message.');
    });

    test('an answer from the server is not retried', () async {
      final f = fixture();
      f.client.fetch = () async =>
          throw Exception('Unable to find event for this push notification!');
      await expectLater(f.push(), throwsA(isA<Exception>()));
      expect(f.client.fetches, 1);
    });

    test('a burst of failed pushes is followed by one catch-up', () async {
      final f = fixture();
      f.client.rooms.clear(); // unknown chats: no generic fallback either
      f.client.fetch = () async =>
          throw const SocketException('Synthetic network down');
      var syncs = 0;
      final catchUp = PushCatchUp(
        sync: (_) async {
          syncs++;
          return const <Event>[];
        },
      );
      final runs = <Future<int?>>[];
      await Future.wait([
        for (var i = 0; i < 5; i++)
          pushHelper(
            PushNotification(
              roomId: _roomId,
              eventId: '\$synthetic-burst-$i',
              counts: const PushNotificationCounts(unread: 5),
              devices: const [],
            ),
            clients: [f.client],
            flutterLocalNotificationsPlugin: f.plugin,
            onOutcome: (outcome) {
              expect(outcome, PushOutcome.fetchFailed);
              if (PushCatchUp.wanted(
                outcome,
                mobile: true,
                lifecycle: AppLifecycleState.paused,
              )) {
                final run = catchUp.run(f.client);
                if (run != null) runs.add(run);
              }
            },
          ).then<void>((_) {}, onError: (Object _) {}),
      ]);
      await Future.wait(runs);
      expect(f.client.fetches, 10, reason: 'each push retried once');
      expect(syncs, 1);
      expect(f.plugin.shown, isEmpty);
    });

    test('the catch-up backlog alerts once for unread messages no push '
        'showed; a later push of one of them stays silent', () async {
      final f = fixture();
      f.room.notificationCount = 2;
      final first = f.event(id: r'$backlog-1', body: 'First');
      final second = f.event(
        id: r'$backlog-2',
        body: 'Second',
        at: DateTime.utc(2026, 10, 17, 12, 1),
      );
      expect(await f.backlog([first, second]), 2);
      expect(f.plugin.shown.map((n) => n.body), ['First', 'Second']);
      // A burst alerts once: only the last one is not silent.
      expect(f.plugin.shown.map((n) => n.details!.android!.silent), [
        true,
        false,
      ]);
      expect(
        ChatLoomPushPayload.fromString(f.plugin.shown.last.payload!).eventId,
        r'$backlog-2',
      );
      // The same backlog again, and the late push: nothing new.
      expect(await f.backlog([first, second]), 0);
      f.client.fetch = () async => second;
      await f.push(eventId: r'$backlog-2');
      expect(f.plugin.shown, hasLength(2));
      expect(await _lastOutcome(), PushOutcome.shown);
    });

    test('a message a push already showed is not in the backlog', () async {
      final f = fixture();
      f.room.notificationCount = 2;
      final pushed = f.event(id: r'$pushed');
      f.client.fetch = () async => pushed;
      await f.push(eventId: r'$pushed');
      final missed = f.event(
        id: r'$missed',
        body: 'Missed',
        at: DateTime.utc(2026, 10, 17, 12, 1),
      );
      expect(await f.backlog([pushed, missed]), 1);
      expect(f.plugin.shown.map((n) => n.body), [
        'Synthetic preview text',
        'Missed',
      ]);
    });

    test('read, answered, muted, mentions-only, not counted and old '
        'messages are not in the backlog', () async {
      List<Event> two(_Fixture f) => [
        f.event(id: r'$older', at: DateTime.utc(2026, 10, 17, 12)),
        f.event(id: r'$newer', at: DateTime.utc(2026, 10, 17, 12, 1)),
      ];

      final read = fixture();
      read.room.notificationCount = 2;
      read.room.roomAccountData['m.fully_read'] = BasicEvent(
        type: 'm.fully_read',
        content: {'event_id': r'$newer'},
      );
      expect(await read.backlog(two(read)), 0, reason: 'read elsewhere');

      final answered = fixture();
      answered.room.notificationCount = 1;
      expect(
        await answered.backlog([
          ...two(answered),
          answered.event(
            id: r'$own-reply',
            sender: _owner,
            at: DateTime.utc(2026, 10, 17, 12, 2),
          ),
        ]),
        0,
        reason: 'the account wrote after them',
      );

      final muted = fixture();
      muted.room.notificationCount = 2;
      muted.mode(PersonalNotificationMode.muted);
      expect(await muted.backlog(two(muted)), 0);

      final mentions = fixture();
      mentions.room.notificationCount = 2;
      mentions.mode(PersonalNotificationMode.mentionsOnly);
      expect(await mentions.backlog(two(mentions)), 0);

      final uncounted = fixture();
      expect(await uncounted.backlog(two(uncounted)), 0);

      final old = fixture();
      old.room.notificationCount = 1;
      expect(
        await old.backlog([
          old.event(id: r'$yesterday', at: DateTime.utc(2026, 10, 16, 12)),
        ]),
        0,
      );

      for (final f in [read, answered, muted, mentions, uncounted, old]) {
        expect(f.plugin.shown, isEmpty);
      }
    });

    test('the backlog is capped per conversation and per run, newest '
        'conversations first', () async {
      final f = fixture(direct: false);
      final rooms = [
        f.room..notificationCount = 4,
        for (var r = 1; r < 5; r++)
          Room(
            id: '!synthetic-backlog-$r:example.invalid',
            client: f.client,
            notificationCount: 4,
          ),
      ];
      f.client.rooms
        ..clear()
        ..addAll(rooms);
      final arrived = [
        for (final (r, room) in rooms.indexed)
          for (var m = 0; m < 4; m++)
            f.event(
              id: '\$backlog-$r-$m',
              body: 'Room $r message $m',
              inRoom: room,
              at: DateTime.utc(2026, 10, 17, 12, r * 10 + m),
            ),
      ];
      // Five conversations, four messages each: the eight alerts are the
      // newest of every conversation, then a second one of the three newest.
      expect(await f.backlog(arrived), 8);
      final perRoom = <String, int>{};
      for (final shown in f.plugin.shown) {
        final room = ChatLoomPushPayload.fromString(shown.payload!).roomId!;
        perRoom[room] = (perRoom[room] ?? 0) + 1;
      }
      expect(perRoom[rooms[0].id], 1);
      expect(perRoom[rooms[1].id], 1);
      expect(perRoom[rooms[4].id], 2);
      expect(perRoom.values.fold<int>(0, (a, b) => a + b), 8);
      expect(f.plugin.shown.last.body, 'Synthetic-peer: Room 4 message 3');
      expect(f.plugin.shown.where((n) => !n.details!.android!.silent), [
        f.plugin.shown.last,
      ]);
      // perThread bounds a single conversation.
      final g = fixture();
      g.room.notificationCount = 5;
      expect(
        await g.backlog([
          for (var m = 0; m < 5; m++)
            g.event(id: '\$single-$m', at: DateTime.utc(2026, 10, 17, 12, m)),
        ], perThread: 2),
        2,
      );
    });
  });

  group('bot and service chats', () {
    void bridge(_Fixture f) => f.room.setState(
      Event(
        room: f.room,
        type: 'm.bridge',
        stateKey: 'synthetic',
        eventId: r'$synthetic-bridge',
        senderId: _bot,
        originServerTs: DateTime.utc(2026, 10, 17),
        content: {
          'bridgebot': _bot,
          'protocol': {'id': 'whatsapp'},
        },
      ),
    );

    test('a bridge bot message is quiet (shade only, no sound or pop-up)', () async {
      final f = fixture();
      bridge(f);
      f.client.fetch = () async => f.event(sender: _bot);
      await f.push();
      final android = f.plugin.shown.single.details!.android!;
      expect(android.channelId, PersonalNotificationChannels.serviceId);
      expect(android.importance, Importance.low);
      expect(android.priority, Priority.low);
      expect(android.playSound, isFalse);
      expect(android.enableVibration, isFalse);
      expect(android.vibrationPattern, isNull);
    });

    test('a bot reply the user is waiting for alerts normally', () async {
      final f = fixture();
      bridge(f);
      f.room.lastEvent = f.event(
        id: r'$own-command',
        sender: _owner,
        at: DateTime.now().subtract(const Duration(minutes: 2)),
      );
      f.client.fetch = () async => f.event(sender: _bot);
      await f.push();
      final android = f.plugin.shown.single.details!.android!;
      expect(android.channelId, PersonalNotificationChannels.messagesId);
      expect(android.importance, Importance.high);
    });

    test('a person in the same chat still alerts normally', () async {
      final f = fixture();
      bridge(f);
      f.client.fetch = () async => f.event();
      await f.push();
      expect(
        f.plugin.shown.single.details!.android!.channelId,
        PersonalNotificationChannels.messagesId,
      );
    });
  });
}
