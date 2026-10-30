// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 5b integration review: behaviour that only breaks where two wave-5
// lanes meet. Fictional offline fixtures only (no account, store or network).
//
// * message-actions × chat-timeline: a deleted message leaves the gated
//   single-chat rows at once (setTimelineState, not setState).
// * settings-copy × message rows: the raw message source opens only with
//   developer options, also from a tapped deleted/unknown row.
// * push × merge-person: a notification reply follows "Send messages via".
// * inbox × merge-person: the person page says when a timed mute is active.
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat.dart';
import 'package:chatloom/pages/chat/event_info_dialog.dart';
import 'package:chatloom/pages/chat/message_deletion.dart';
import 'package:chatloom/personal/developer_options.dart';
import 'package:chatloom/personal/notification_reply.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/ui/person_page.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/widgets/matrix.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

/// A chat whose "delete for everyone" waits for [redaction].
class _DeletingRoom extends ConversationRoom {
  Completer<String?> redaction = Completer<String?>();
  int redactions = 0;
  _DeletingRoom(super.client, super.id);

  @override
  Future<String?> redactEvent(
    String eventId, {
    String? reason,
    String? txid,
    bool redactAllEdits = false,
  }) {
    redactions++;
    return redaction.future;
  }
}

Future<ChatController> _mountChat(
  WidgetTester tester,
  ConversationClient client,
  Room room,
) async {
  final state = ConversationMatrix(
    client,
    await SharedPreferences.getInstance(),
  );
  await tester.pumpWidget(
    Provider<MatrixState>.value(
      value: state,
      child: MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: ChatPageWithRoom(room: room),
      ),
    ),
  );
  await tester.pumpAndSettle();
  await tester.pump(const Duration(seconds: 1));
  await tester.pumpAndSettle();
  return tester.state<ChatController>(find.byType(ChatPageWithRoom));
}

// Person page fixtures: bridged one-to-one rooms the merge accepts.
const _owner = '@fixture:example.invalid';
const _bot = '@bridge:example.invalid';
const _peer = '@person:example.invalid';

class _LocalDatabase implements DatabaseApi {
  @override
  Future<List<Event>> getEventList(
    Room room, {
    int start = 0,
    int? limit,
    bool onlySending = false,
  }) async => const [];
  @override
  Future<List<String>> getEventIdList(
    Room room, {
    int start = 0,
    int? limit,
    bool includeSending = false,
  }) async => const [];
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _PersonClient extends Client {
  _PersonClient()
    : super('synthetic review person', database: _LocalDatabase());
  @override
  String get userID => _owner;
  @override
  Map<String, List<String>> get directChats => const {};
}

Room _bridged(Client client, String id, String network) {
  final room = Room(
    id: '!$id:example.invalid',
    client: client,
    membership: Membership.join,
  );
  client.rooms.add(room);
  void state(String type, Map<String, dynamic> content, {String key = ''}) =>
      room.setState(
        Event(
          room: room,
          type: type,
          stateKey: key,
          content: content,
          senderId: _bot,
          eventId: '\$fixture-$type-$key',
          originServerTs: DateTime.utc(2026),
        ),
      );
  state(EventTypes.RoomName, {'name': 'Fictional $id'});
  state('m.bridge', {
    'bridgebot': _bot,
    'protocol': {'id': network},
    'com.beeper.room_type.v2': 'dm',
  }, key: 'fixture');
  for (final member in [_owner, _bot, _peer]) {
    state(EventTypes.RoomMember, {'membership': 'join'}, key: member);
  }
  room.summary.mJoinedMemberCount = 3;
  room.summary.mInvitedMemberCount = 0;
  return room;
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
  Future<void> loadLocal() async {}
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

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('single chat rows (gated by the timeline revision)', () {
    late ConversationClient client;
    late _DeletingRoom room;
    late ConversationPersonal personal;

    setUp(() {
      client = ConversationClient();
      room = _DeletingRoom(client, '!review-delete:example.invalid');
      room.message(r'$review-1', 'Older fictional row', minute: 1);
      room.message(
        r'$review-own',
        'Own fictional row to delete',
        outgoing: true,
        minute: 2,
      );
      room.message(r'$review-3', 'Newest fictional row', minute: 3);
      personal = ConversationPersonal(client);
      PersonalClient.debugUse(client, personal);
    });
    tearDown(() {
      MessageDeletions.debugReset(client);
      personal.dispose();
    });

    testWidgets('a deleted message leaves at once and comes back with Retry '
        'when the deletion fails', (tester) async {
      // Created in the test's own zone: an error completed from setUp's
      // zone would never reach the deletion's await.
      room.redaction = Completer<String?>();
      final controller = await _mountChat(tester, client, room);
      const text = 'Own fictional row to delete';
      expect(find.text(text), findsOneWidget);
      final own = room.sourceEvents.firstWhere(
        (e) => e.eventId == r'$review-own',
      );
      final revision = controller.timelineRevision;
      unawaited(controller.redactEventAction(own));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      // The bubble's exit motion runs before the redaction goes out.
      await tester.pumpAndSettle();
      expect(room.redactions, 1);
      // Hidden without waiting for any timeline update.
      expect(controller.timelineRevision, greaterThan(revision));
      expect(find.text(text), findsNothing);
      expect(find.text('Newest fictional row'), findsOneWidget);

      room.redaction.completeError(StateError('Synthetic refusal'));
      await tester.pumpAndSettle();
      expect(find.text(text), findsOneWidget);
      expect(
        find.textContaining('Couldn’t delete the message'),
        findsOneWidget,
      );
      expect(find.text('Retry'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });

    testWidgets('without developer options a tapped row never opens the raw '
        'message source', (tester) async {
      final controller = await _mountChat(tester, client, room);
      await DeveloperOptions.setEnabled(false);
      expect(DeveloperOptions.enabled, isFalse);
      // What a tapped "Deleted by …" or unknown-event row calls.
      controller.showEventInfo(room.sourceEvents.first);
      await tester.pumpAndSettle();
      expect(find.byType(EventInfoDialog), findsNothing);
      expect(find.text('Message info'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
  });

  group('notification reply of a merged person', () {
    late ConversationClient client;
    late ConversationRoom whatsapp, telegram;
    late ConversationPersonal personal;
    late PersonGroup person;

    setUp(() {
      client = ConversationClient();
      whatsapp = ConversationRoom(client, '!review-wa:example.invalid');
      telegram = ConversationRoom(
        client,
        '!review-tg:example.invalid',
        network: 'telegram',
      );
      personal = ConversationPersonal(client);
      person = PersonGroup(
        id: 'review-person',
        name: 'Fictional person',
        members: [personal.ref(whatsapp), personal.ref(telegram)],
        defaultRoomId: whatsapp.id,
      );
      personal.values['person:${person.id}'] = person
          .toJson()
          .cast<String, dynamic>();
    });
    tearDown(() => personal.dispose());

    test('Automatic answers on the network of the notified message', () {
      expect(
        notificationReplyRoom(personal, telegram, eventId: r'$fictional'),
        same(telegram),
      );
    });

    test('"Always <network>" answers on that network, like the composer', () {
      personal.values[personPreferencesKey(person.id)] =
          const PersonPreferences(routing: PersonRouting.fixed).toJson();
      expect(
        notificationReplyRoom(personal, telegram, eventId: r'$fictional'),
        same(whatsapp),
      );
      expect(
        notificationReplyRoom(personal, whatsapp, eventId: r'$fictional'),
        same(whatsapp),
      );
    });

    test('a default chat that was left is never the reply target', () {
      personal.values[personPreferencesKey(person.id)] =
          const PersonPreferences(routing: PersonRouting.fixed).toJson();
      // FT-01: the person stays merged with its remaining chat.
      whatsapp.membership = Membership.leave;
      expect(
        notificationReplyRoom(personal, telegram, eventId: r'$fictional'),
        same(telegram),
      );
    });
  });

  group('person page', () {
    late _PersonClient client;
    late Room whatsapp, telegram;
    late _Private personal;
    late PersonGroup group;

    setUp(() {
      client = _PersonClient();
      whatsapp = _bridged(client, 'wa', 'whatsapp');
      telegram = _bridged(client, 'tg', 'telegram');
      personal = _Private(client);
      group = PersonGroup(
        id: 'person',
        name: 'Fictional person',
        members: [personal.ref(whatsapp), personal.ref(telegram)],
        defaultRoomId: whatsapp.id,
      );
      personal.values['person:person'] = group.toJson().cast<String, dynamic>();
    });
    tearDown(() => personal.dispose());

    Future<void> mount(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        Provider<MatrixState>.value(
          value: _Matrix(client),
          child: MaterialApp(
            theme: NotionTheme.build(Brightness.dark),
            home: PersonPage(personal: personal, group: group),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    String notificationsSubtitle(WidgetTester tester) => tester
        .widget<NotionListRow>(
          find.widgetWithText(NotionListRow, 'Notifications').first,
        )
        .subtitle!;

    testWidgets('a timed mute from the inbox shows instead of the mode', (
      tester,
    ) async {
      personal.values['org:person:person'] = {
        'notificationMode': PersonalNotificationMode.all.name,
      };
      await mount(tester);
      expect(notificationsSubtitle(tester), 'All messages · every network');

      final until = DateTime.now().add(const Duration(hours: 1));
      await personal.put('org:person:person', {
        'notificationMode': PersonalNotificationMode.all.name,
        'muted': true,
        'mutedUntil': until.toUtc().toIso8601String(),
      });
      await tester.pumpAndSettle();
      expect(notificationsSubtitle(tester), startsWith('Muted until '));
      expect(notificationsSubtitle(tester), endsWith('mentions still notify'));

      // An ended mute no longer counts.
      await personal.put('org:person:person', {
        'notificationMode': PersonalNotificationMode.all.name,
        'muted': true,
        'mutedUntil': DateTime.now()
            .subtract(const Duration(minutes: 1))
            .toUtc()
            .toIso8601String(),
      });
      await tester.pumpAndSettle();
      expect(notificationsSubtitle(tester), 'All messages · every network');
    });
  });
}
