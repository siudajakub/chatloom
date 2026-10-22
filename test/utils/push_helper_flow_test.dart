// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/message_notification.dart';
import 'package:chatloom/personal/notification_threads.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/push_diagnostics.dart';
import 'package:chatloom/personal/seen_chat_notifications.dart';
import 'package:chatloom/personal/storage/personal_store.dart';
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
  bool? returnNullIfSeen;

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

  @override
  Future<List<ActiveNotification>> getActiveNotifications() async => [];

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
  });

  tearDown(() {
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
      'Messages channel, inline Reply and incognito Dismiss action', () async {
    final f = fixture();
    f.client.fetch = () async => f.event();
    await f.push();
    final shown = f.plugin.shown.single;
    expect(shown.title, 'Synthetic-peer');
    expect(shown.body, 'Synthetic preview text');
    final android = shown.details!.android!;
    expect(android.channelId, 'fluffychat_push');
    expect(android.channelName, 'Messages');
    expect(android.visibility, NotificationVisibility.private);
    expect(android.actions!.map((a) => a.id), ['reply', 'dismiss']);
    final reply = android.actions!.first;
    expect(reply.title, 'Reply');
    expect(reply.inputs.single.label, 'Message');
    expect(reply.semanticAction, SemanticAction.reply);
    expect(reply.showsUserInterface, isFalse);
    // Android's sending state stays until the outcome replaces it.
    expect(reply.cancelNotification, isFalse);
    expect(android.actions!.last.title, 'Dismiss');
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
      'dismiss',
    ]);
    final g = fixture();
    g.client.fetch = () async => g.event();
    await g.push(test: true);
    expect(g.plugin.shown.last.details!.android!.actions!.map((a) => a.id), [
      'dismiss',
    ]);
  });

  test('previews off keep the generic text; read receipts only without '
      'incognito', () async {
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
    expect(android.actions!.map((a) => a.id), ['dismiss']);
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
