// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:fluffychat/config/setting_keys.dart';
import 'package:fluffychat/l10n/l10n.dart';
import 'package:fluffychat/personal/message_notification.dart';
import 'package:fluffychat/personal/personal_client.dart';
import 'package:fluffychat/personal/push_diagnostics.dart';
import 'package:fluffychat/personal/storage/personal_store.dart';
import 'package:fluffychat/utils/notification_client_routing.dart';
import 'package:fluffychat/utils/push_helper.dart';
import 'package:fluffychat/utils/start_push_foreground_service.dart';
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

  Event event({
    String id = _eventId,
    String sender = _peer,
    String body = 'Synthetic preview text',
    DateTime? at,
  }) => Event(
    room: room,
    type: EventTypes.Message,
    eventId: id,
    senderId: sender,
    originServerTs: at ?? DateTime.utc(2026, 10, 17, 12),
    content: {'msgtype': 'm.text', 'body': body},
  );

  Future<void> push({
    List<Client>? clients,
    String eventId = _eventId,
    bool test = false,
  }) async {
    final l10n = await L10n.delegate.load(const Locale('en'));
    await pushHelper(
      PushNotification(
        roomId: _roomId,
        eventId: eventId,
        counts: const PushNotificationCounts(unread: 1),
        devices: const [],
      ),
      clients: clients ?? [client],
      l10n: l10n,
      flutterLocalNotificationsPlugin: plugin,
      test: test,
    );
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
      FluffyChatPushPayload.fromString(shown.payload!).clientName,
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
      'Messages channel and incognito Dismiss action', () async {
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
    expect(android.actions!.single.id, 'dismiss');
    expect(android.actions!.single.title, 'Dismiss');
  });

  test('previews off keep the generic text; read receipts only without '
      'incognito', () async {
    final f = fixture();
    await AppSettings.personalNotificationPreviews.setItem(false);
    await AppSettings.personalIncognito.setItem(false);
    f.client.fetch = () async => f.event();
    await f.push();
    final shown = f.plugin.shown.single;
    expect(shown.title, 'Personal Chat');
    expect(shown.body, 'Open the app to read your message.');
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
}
