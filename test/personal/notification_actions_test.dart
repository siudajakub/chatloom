// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 5 push lane: notification actions on a merged person (FT-04), Mark as
// read after incognito was turned on (CC-29), bounded replies (CC-10).
// Fictional offline fixtures only; no message text in notices.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/message_notification.dart';
import 'package:chatloom/personal/notification_reply.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/utils/notification_background_handler.dart';
import 'package:chatloom/utils/notification_client_routing.dart';
import 'package:chatloom/utils/push_helper.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

const _reply = 'Fictional reply';

class _Plugin implements FlutterLocalNotificationsPlugin {
  final shown = <(int, String?)>[];
  final cancelled = <int>[];

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async => shown.add((id, body));

  @override
  Future<void> cancel({required int id, String? tag}) async =>
      cancelled.add(id);

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

class _Client extends ConversationClient {
  @override
  bool isLogged() => true;
  @override
  Uri get baseUri => Uri.parse('https://fixture.invalid');
}

class _Room extends ConversationRoom {
  _Room(super.client, super.id, {super.network});
  final receipts = <String?>[];
  final publicReceipts = <bool?>[];

  @override
  Future<void> setReadMarker(
    String? eventId, {
    String? mRead,
    bool? public,
  }) async {
    receipts.add(eventId);
    publicReceipts.add(public);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Client client;
  late _Room whatsapp, telegram;
  late ConversationPersonal personal;
  late PersonGroup person;
  late _Plugin plugin;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.personalNotificationPreviews.setItem(true);
    await AppSettings.personalIncognito.setItem(false);
    debugAppLockConfigured = () async => false;
    client = _Client();
    whatsapp = _Room(client, '!whatsapp:example.invalid');
    telegram = _Room(client, '!telegram:example.invalid', network: 'telegram');
    personal = ConversationPersonal(client);
    PersonalClient.debugUse(client, personal);
    person = PersonGroup(
      id: 'fictional-person',
      name: 'Fictional person',
      members: [personal.ref(whatsapp), personal.ref(telegram)],
      defaultRoomId: whatsapp.id,
    );
    personal.values['person:${person.id}'] = person
        .toJson()
        .cast<String, dynamic>();
    plugin = _Plugin();
    debugNotificationReplyPersonalOf = (_) => personal;
    debugNotificationReplyNeedsReview = (_) async => false;
    debugNotificationReplySync = (_) async {};
    debugNotificationReplySummary = false;
  });

  tearDown(() {
    debugAppLockConfigured = null;
    debugNotificationReplyPersonalOf = null;
    debugNotificationReplyNeedsReview = null;
    debugNotificationReplySync = null;
    debugNotificationReplySummary = null;
    personal.dispose();
  });

  NotificationResponse markAsRead(Room room, String eventId) =>
      NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        id: personNotificationId(client.clientName, person.id),
        actionId: ChatLoomNotificationActions.markAsRead.name,
        payload: ChatLoomPushPayload(
          client.clientName,
          room.id,
          eventId,
        ).toString(),
      );

  group('Mark as read on a merged person', () {
    test('marks the notified message and the other network up to that '
        'time, never a later message', () async {
      final notified = telegram.message(r'$notified', 'Fictional', minute: 20);
      telegram.lastEvent = notified;
      whatsapp.lastEvent = whatsapp.message(
        r'$earlier',
        'Fictional',
        minute: 10,
      );
      await notificationTap(
        markAsRead(telegram, r'$notified'),
        clients: [client],
      );
      expect(telegram.receipts, [r'$notified']);
      expect(whatsapp.receipts, [r'$earlier']);

      whatsapp.receipts.clear();
      telegram.receipts.clear();
      whatsapp.lastEvent = whatsapp.message(r'$later', 'Fictional', minute: 30);
      await notificationTap(
        markAsRead(telegram, r'$notified'),
        clients: [client],
      );
      expect(telegram.receipts, [r'$notified']);
      expect(whatsapp.receipts, isEmpty, reason: 'Not shown, not read');
    });

    test(
      'a local echo as the other network\'s preview is never marked',
      () async {
        telegram.lastEvent = telegram.message(r'$notified', 'Fictional');
        whatsapp.lastEvent = whatsapp.message(
          'local-echo',
          'Fictional',
          outgoing: true,
          minute: 5,
          status: EventStatus.error,
        );
        await notificationTap(
          markAsRead(telegram, r'$notified'),
          clients: [client],
        );
        expect(whatsapp.receipts, isEmpty);
        expect(telegram.receipts, [r'$notified']);
      },
    );

    test('under incognito (also on a notification posted before it was '
        'turned on) Mark as read is private: read marker and private '
        'receipt only, even with public receipts on (CS-32, CC-29)', () async {
      await AppSettings.personalIncognito.setItem(true);
      await AppSettings.sendPublicReadReceipts.setItem(true);
      telegram.lastEvent = telegram.message(r'$notified', 'Fictional');
      await notificationTap(
        markAsRead(telegram, r'$notified'),
        clients: [client],
      );
      expect(telegram.receipts, [r'$notified']);
      expect(telegram.publicReceipts, [false]);
    });

    test(
      'without incognito Mark as read follows the receipt setting',
      () async {
        await AppSettings.sendPublicReadReceipts.setItem(true);
        telegram.lastEvent = telegram.message(r'$notified', 'Fictional');
        await notificationTap(
          markAsRead(telegram, r'$notified'),
          clients: [client],
        );
        expect(telegram.publicReceipts, [true]);
        telegram.publicReceipts.clear();
        await AppSettings.sendPublicReadReceipts.setItem(false);
        await notificationTap(
          markAsRead(telegram, r'$notified'),
          clients: [client],
        );
        expect(telegram.publicReceipts, [false]);
      },
    );
  });

  group('Reply on a merged person', () {
    test('goes to the network of the notified message and updates the '
        'notification the user replied on', () async {
      personal.sendState = ImmediateSendState.failed;
      final outcome = await sendNotificationReply(
        client: client,
        roomId: telegram.id,
        input: _reply,
        plugin: plugin,
        eventId: r'$notified',
      );
      expect(outcome, NotificationReplyOutcome.notSent);
      expect(personal.sends.single.room, same(telegram));
      // The shared notification, not a per-network one.
      expect(
        plugin.shown.single.$1,
        personNotificationId(client.clientName, person.id),
      );
      expect(plugin.shown.single.$2, isNot(contains(_reply)));

      plugin.shown.clear();
      await sendNotificationReply(
        client: client,
        roomId: telegram.id,
        input: _reply,
        plugin: plugin,
        notificationId: 41,
      );
      expect(plugin.shown.single.$1, 41);
    });

    test('a send that outlasts the bound is reported as not confirmed and '
        'the text stays in the draft', () async {
      personal.transportGate = Completer<void>();
      final outcome = await sendNotificationReply(
        client: client,
        roomId: whatsapp.id,
        input: _reply,
        plugin: plugin,
        limit: const Duration(milliseconds: 300),
      );
      expect(outcome, NotificationReplyOutcome.notConfirmed);
      expect(
        plugin.shown.single.$2,
        notificationReplyNotice(NotificationReplyOutcome.notConfirmed),
      );
      expect(personal.values['draft:person:${person.id}']?['text'], _reply);
    });

    test(
      'a bound used up before sending reports not sent, never a send',
      () async {
        debugNotificationReplyNeedsReview = (_) => Completer<bool>().future;
        final outcome = await sendNotificationReply(
          client: client,
          roomId: whatsapp.id,
          input: _reply,
          plugin: plugin,
          limit: const Duration(milliseconds: 300),
        );
        expect(outcome, NotificationReplyOutcome.notSent);
        expect(personal.sends, isEmpty);
      },
    );
  });
}
