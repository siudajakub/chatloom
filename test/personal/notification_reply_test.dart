// SPDX-License-Identifier: AGPL-3.0-or-later
// Review R8: an inline notification Reply goes through the durable outbox,
// keeps the typed text as a draft on every failure, never sends with the app
// lock set and is handed to the running app exactly once. Fictional offline
// fixtures only; no message text is asserted in logs or notices.
import 'dart:async';
import 'dart:isolate';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/personal/immediate_outbox.dart';
import 'package:chatloom/personal/message_notification.dart';
import 'package:chatloom/personal/notification_reply.dart';
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

class _Shown {
  final int id;
  final String? title, body, payload;
  _Shown(this.id, this.title, this.body, this.payload);
}

class _Plugin implements FlutterLocalNotificationsPlugin {
  final shown = <_Shown>[];
  final cancelled = <int>[];

  @override
  Future<void> show({
    required int id,
    String? title,
    String? body,
    NotificationDetails? notificationDetails,
    String? payload,
  }) async => shown.add(_Shown(id, title, body, payload));

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
}

class _Personal extends ConversationPersonal {
  _Personal(super.client);
  final completed = <String>[];
  Object? loadFailure;
  Object? sendFailure;

  /// Draft saves fail from this (0-based) save on.
  int? failDraftsFrom;

  @override
  Future<void> loadLocal() async {
    if (loadFailure != null) throw loadFailure!;
  }

  @override
  Future<void> savePersonalDraft(
    String key,
    SendTarget target,
    String text,
  ) async {
    final from = failDraftsFrom;
    if (from != null && drafts.length >= from) {
      throw StateError('Synthetic storage failure');
    }
    await super.savePersonalDraft(key, target, text);
  }

  @override
  Future<ImmediateSendResult> sendImmediate(
    Room room,
    String text, {
    Event? replyTo,
    String? editEventId,
    String? threadId,
    ImmediateDurable? onDurable,
  }) async {
    if (sendFailure != null) throw sendFailure!;
    return super.sendImmediate(
      room,
      text,
      replyTo: replyTo,
      editEventId: editEventId,
      threadId: threadId,
      onDurable: onDurable,
    );
  }

  @override
  Future<void> completeImmediate(String actionId) async =>
      completed.add(actionId);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Client client;
  late ConversationRoom room;
  late _Personal personal;
  late _Plugin plugin;
  late int syncs;

  int notificationId() => messageNotificationId(client.clientName, room.id);
  String? draft([String? key]) =>
      personal.values[key ?? 'draft:${room.id}']?['text'] as String?;

  Future<NotificationReplyOutcome> reply([String? input = _reply]) =>
      sendNotificationReply(
        client: client,
        roomId: room.id,
        input: input,
        plugin: plugin,
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
    await AppSettings.personalNotificationPreviews.setItem(true);
    debugAppLockConfigured = () async => false;
    client = _Client();
    room = ConversationRoom(client, '!reply:example.invalid');
    personal = _Personal(client);
    plugin = _Plugin();
    syncs = 0;
    debugNotificationReplyPersonalOf = (_) => personal;
    debugNotificationReplyNeedsReview = (_) async => false;
    debugNotificationReplySync = (_) async => syncs++;
    debugNotificationReplySummary = false;
  });

  tearDown(() {
    debugAppLockConfigured = null;
    debugNotificationReplyPersonalOf = null;
    debugNotificationReplyNeedsReview = null;
    debugNotificationReplySync = null;
    debugNotificationReplySummary = null;
    notificationReplyClaimTimeout = const Duration(seconds: 10);
    personal.dispose();
  });

  test('a reply is sent once through the outbox with exactly the typed '
      'text, then the draft is restored, the attempt retired and the '
      'notification removed', () async {
    expect(await reply(), NotificationReplyOutcome.sent);
    final send = personal.sends.single;
    expect(send.room, room);
    expect(send.text, _reply);
    expect(send.reply, isNull, reason: 'A notification reply is not a quote');
    expect(send.edit, isNull);
    expect(syncs, 1);
    // Written ahead of the send, taken out after acceptance.
    expect(personal.drafts.map((d) => d.text), [_reply, '']);
    expect(personal.drafts.first.target.conversation, personal.ref(room));
    expect(personal.completed, ['fixture-action-1']);
    expect(plugin.cancelled, [notificationId()]);
    expect(plugin.shown, isEmpty);
  });

  test('an existing draft is kept: the reply joins it while sending and the '
      'draft returns to its earlier text afterwards', () async {
    personal.values['draft:${room.id}'] = {
      'text': 'Earlier fictional draft',
      'target': SendTarget(conversation: personal.ref(room)).toJson(),
    };
    expect(await reply(), NotificationReplyOutcome.sent);
    expect(personal.drafts.map((d) => d.text), [
      'Earlier fictional draft\n$_reply',
      'Earlier fictional draft',
    ]);
    expect(personal.sends.single.text, _reply);
  });

  for (final (state, outcome) in [
    (ImmediateSendState.failed, NotificationReplyOutcome.notSent),
    (ImmediateSendState.unknown, NotificationReplyOutcome.notConfirmed),
  ]) {
    test('a ${state.name} send keeps the text as the draft and replaces the '
        'notification with a notice that opens the chat', () async {
      personal.sendState = state;
      expect(await reply(), outcome);
      expect(draft(), _reply);
      expect(personal.completed, isEmpty);
      final notice = plugin.shown.single;
      expect(notice.id, notificationId());
      expect(notice.title, 'Fictional conversation');
      expect(notice.body, notificationReplyNotice(outcome));
      expect(notice.body, isNot(contains(_reply)));
      final payload = ChatLoomPushPayload.fromString(notice.payload!);
      expect(payload.roomId, room.id);
      expect(payload.clientName, client.clientName);
      expect(payload.eventId, isNull);
    });
  }

  test('with the app lock set nothing is sent: the text waits in the draft '
      'and the notice names no chat', () async {
    debugAppLockConfigured = () async => true;
    expect(await reply(), NotificationReplyOutcome.locked);
    expect(personal.sends, isEmpty);
    expect(syncs, 0);
    expect(draft(), _reply);
    final notice = plugin.shown.single;
    expect(notice.title, genericNotificationTitle);
    expect(
      notice.body,
      notificationReplyNotice(NotificationReplyOutcome.locked),
    );
  });

  test('an encrypted chat that needs a trust review, or one the account '
      'cannot write to, is not sent from the shade', () async {
    debugNotificationReplyNeedsReview = (_) async => true;
    expect(await reply(), NotificationReplyOutcome.needsReview);
    expect(personal.sends, isEmpty);
    expect(draft(), _reply);

    debugNotificationReplyNeedsReview = (_) async => false;
    personal.values.remove('draft:${room.id}');
    room.sendingAllowed = false;
    expect(await reply(), NotificationReplyOutcome.notSent);
    expect(personal.sends, isEmpty);
    expect(draft(), _reply);
  });

  test('a trust check or send that throws keeps the draft', () async {
    debugNotificationReplyNeedsReview = (_) async =>
        throw TimeoutException('Synthetic member list timeout');
    expect(await reply(), NotificationReplyOutcome.notSent);
    expect(draft(), _reply);

    debugNotificationReplyNeedsReview = (_) async => false;
    personal.values.remove('draft:${room.id}');
    personal.sendFailure = StateError('Encrypted outbox unavailable');
    expect(await reply(), NotificationReplyOutcome.notSent);
    expect(draft(), _reply);
  });

  test(
    'fails closed without the encrypted store: nothing sent, told so',
    () async {
      personal.loadFailure = StateError('Synthetic storage failure');
      expect(await reply(), NotificationReplyOutcome.unavailable);
      expect(personal.sends, isEmpty);
      expect(
        plugin.shown.single.body,
        notificationReplyNotice(NotificationReplyOutcome.unavailable),
      );

      personal.loadFailure = null;
      personal.failDraftsFrom = 0;
      expect(await reply(), NotificationReplyOutcome.unavailable);
      expect(personal.sends, isEmpty, reason: 'No draft, no send');
    },
  );

  test('an accepted reply whose draft cannot be restored keeps its attempt, '
      'so sending the leftover draft copy cannot duplicate it', () async {
    personal.failDraftsFrom = 1;
    expect(await reply(), NotificationReplyOutcome.sent);
    expect(personal.completed, isEmpty);
    expect(draft(), _reply);
    expect(plugin.cancelled, [notificationId()]);
  });

  test(
    'blank input sends nothing, writes nothing and ends the sending state',
    () async {
      expect(await reply('   '), NotificationReplyOutcome.empty);
      expect(await reply(null), NotificationReplyOutcome.empty);
      expect(personal.sends, isEmpty);
      expect(personal.drafts, isEmpty);
      expect(plugin.cancelled, [notificationId(), notificationId()]);
    },
  );

  test('a merged person: the reply waits in the person draft when it is '
      'empty or aimed at this chat, otherwise in the chat draft', () async {
    final telegram = ConversationRoom(
      client,
      '!reply-telegram:example.invalid',
      network: 'telegram',
    );
    final group = PersonGroup(
      id: 'fictional-person',
      name: 'Fictional person',
      members: [personal.ref(room), personal.ref(telegram)],
      defaultRoomId: room.id,
    );
    personal.values['person:${group.id}'] = group
        .toJson()
        .cast<String, dynamic>();
    const personKey = 'draft:person:fictional-person';
    personal.sendState = ImmediateSendState.failed;

    expect(await reply(), NotificationReplyOutcome.notSent);
    expect(draft(personKey), _reply);
    expect(personal.drafts.last.target.conversation, personal.ref(room));

    // A person draft aimed at another network is never retargeted.
    personal.values[personKey] = {
      'text': 'Telegram fictional draft',
      'target': SendTarget(conversation: personal.ref(telegram)).toJson(),
    };
    expect(await reply(), NotificationReplyOutcome.notSent);
    expect(draft(personKey), 'Telegram fictional draft');
    expect(draft(), _reply);
  });

  test('the notification action routes Reply to the outbox, never straight '
      'to the room', () async {
    await notificationTap(
      NotificationResponse(
        notificationResponseType:
            NotificationResponseType.selectedNotificationAction,
        actionId: ChatLoomNotificationActions.reply.name,
        input: _reply,
        payload: ChatLoomPushPayload(
          client.clientName,
          room.id,
          r'$fictional',
        ).toString(),
      ),
      clients: [client],
    );
    expect(personal.sends.single.text, _reply);
    expect(personal.completed, ['fixture-action-1']);
  });

  group('hand-off to the running app', () {
    NotificationResponse response() => NotificationResponse(
      notificationResponseType:
          NotificationResponseType.selectedNotificationAction,
      id: 7,
      actionId: ChatLoomNotificationActions.reply.name,
      input: _reply,
      payload: 'fictional|!room:example.invalid|null',
    );

    test('the running app claims a forwarded reply exactly once', () async {
      final main = ReceivePort();
      addTearDown(main.close);
      final claims = <bool>[];
      main.listen((message) {
        final forwarded = NotificationResponseJson.fromJsonString(
          message as String,
        );
        expect(forwarded.input, _reply);
        claims
          ..add(claimNotificationReply(forwarded))
          ..add(claimNotificationReply(forwarded));
      });
      expect(await forwardNotificationReply(main.sendPort, response()), isTrue);
      expect(claims, [true, false]);
    });

    test('an unclaimed reply times out to the background, and a late claim '
        'by the app is refused (no double handling)', () async {
      notificationReplyClaimTimeout = const Duration(milliseconds: 50);
      final main = ReceivePort();
      addTearDown(main.close);
      final messages = <String>[];
      main.listen((message) => messages.add(message as String));
      expect(
        await forwardNotificationReply(main.sendPort, response()),
        isFalse,
      );
      expect(
        claimNotificationReply(
          NotificationResponseJson.fromJsonString(messages.single),
        ),
        isFalse,
      );
    });

    test('a reply delivered directly needs no claim', () {
      expect(claimNotificationReply(response()), isTrue);
    });
  });
}
