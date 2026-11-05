// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/pages/chat_list/chat_actions_menu.dart';
import 'package:chatloom/pages/chat_list/chat_list.dart' show chatMenuItems;
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/notification_eligibility.dart';
import 'package:chatloom/personal/push_rule_mirror.dart';
import 'package:chatloom/ui/notion/metadata_actions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import '../notion/conversation_test_support.dart';

class _Personal extends ConversationPersonal {
  _Personal(super.client);
  bool available = true;
  @override
  bool get ready => available;
  @override
  Future<void> put(String key, Map<String, dynamic> value) async {
    values[key] = value;
  }
}

void main() {
  test(
    'Aside eligibility also caps fallback and explicit all modes; Ignored cannot be bypassed',
    () async {
      final client = ConversationClient();
      final chat = ConversationRoom(client, '!fallback:example.invalid');
      final metadata = ConversationMetadata(
        entityId: chat.id,
        placement: ChatPlacement.aside,
        notificationMode: PersonalNotificationMode.all,
      );
      final plain = chat.message(r'$plain', 'Fictional text');
      final mention = chat.message(
        r'$mention',
        'Fictional mention',
        content: {
          'm.mentions': {
            'user_ids': [client.userID],
          },
        },
      );
      for (final mode in [
        null,
        PersonalNotificationMode.all,
        PersonalNotificationMode.mentionsOnly,
      ]) {
        expect(
          await personalNotificationEligible(
            plain,
            metadata,
            notificationMode: mode,
          ),
          isFalse,
        );
        expect(
          await personalNotificationEligible(
            mention,
            metadata,
            notificationMode: mode,
          ),
          isTrue,
        );
      }
      expect(
        await personalNotificationEligible(
          mention,
          metadata.setPlacement(ChatPlacement.ignored),
          placement: ChatPlacement.aside,
          notificationMode: PersonalNotificationMode.all,
        ),
        isFalse,
      );
    },
  );
  test(
    'menu moves a chat aside and back without changing ignored chats or private fields',
    () async {
      final client = ConversationClient();
      final chat = ConversationRoom(client, '!chat:example.invalid');
      final ignored = ConversationRoom(client, '!ignored:example.invalid');
      final personal = _Personal(client);
      addTearDown(personal.dispose);
      personal.values['org:${ignored.id}'] = {'ignored': true};
      personal.values['org:${chat.id}'] = {
        'notificationMode': 'all',
        'nickname': 'Fictional nickname',
        'futurePrivateField': true,
        'archived': true,
        'lowPriority': true,
      };
      ChatMenuItem<ChatMenuAction> action() => chatMenuItems(
        personal,
        chat,
        pinLabel: 'Pin',
        unpinLabel: 'Unpin',
      ).singleWhere((item) => item.action == ChatMenuAction.aside);
      expect(action().label, 'Move to Aside');
      await NotionMetadataActions.moveTo(
        personal,
        chat.id,
        ChatPlacement.aside,
      );
      var projection = InboxProjection(personal);
      expect(action().label, 'Move to Inbox');
      expect(projection.rooms(client.rooms), isEmpty);
      expect(projection.rooms(client.rooms, filter: InboxFilter.aside), [chat]);
      expect(projection.rooms(client.rooms, filter: InboxFilter.ignored), [
        ignored,
      ]);
      expect(personal.values['org:${ignored.id}'], {'ignored': true});
      expect(personal.values['org:${chat.id}']?['futurePrivateField'], isTrue);
      expect(projection.metadataFor(chat).nickname, 'Fictional nickname');
      expect(
        projection.notificationModeFor(chat),
        PersonalNotificationMode.mentionsOnly,
      );
      expect(chatLoomPushRuleTarget(personal).silence, {ignored.id});
      await NotionMetadataActions.moveTo(
        personal,
        chat.id,
        ChatPlacement.inbox,
      );
      projection = InboxProjection(personal);
      expect(projection.rooms(client.rooms), [chat]);
      expect(
        projection.notificationModeFor(chat),
        PersonalNotificationMode.all,
      );
      personal.available = false;
      expect(action().enabled, isFalse);
      await expectLater(
        NotionMetadataActions.moveTo(personal, chat.id, ChatPlacement.aside),
        throwsStateError,
      );
    },
  );

  test(
    'Aside restricts all merged sources; explicit mentions alert, other messages do not',
    () async {
      final client = ConversationClient();
      final first = ConversationRoom(client, '!first:example.invalid');
      final second = ConversationRoom(
        client,
        '!second:example.invalid',
        network: 'telegram',
      );
      final personal = _Personal(client);
      addTearDown(personal.dispose);
      final group = PersonGroup(
        id: 'fixture',
        name: 'Fictional person',
        members: [personal.ref(first), personal.ref(second)],
        defaultRoomId: first.id,
      );
      personal.values['person:fixture'] = group
          .toJson()
          .cast<String, dynamic>();
      personal.values['org:${second.id}'] = {'notificationMode': 'all'};
      await NotionMetadataActions.moveTo(
        personal,
        'person:fixture',
        ChatPlacement.aside,
      );
      final projection = InboxProjection(personal);
      expect(projection.rooms(client.rooms), isEmpty);
      expect(
        projection.rooms(client.rooms, filter: InboxFilter.aside),
        hasLength(1),
      );
      for (final chat in [first, second]) {
        expect(projection.placementFor(chat), ChatPlacement.aside);
        expect(
          projection.notificationModeFor(chat),
          PersonalNotificationMode.mentionsOnly,
        );
        Future<bool> eligible(
          Map<String, dynamic> content, {
          bool outgoing = false,
        }) => personalNotificationEligible(
          chat.message(
            r'$fixture',
            'Fictional text',
            content: content,
            outgoing: outgoing,
          ),
          projection.metadataFor(chat),
          notificationMode: projection.notificationModeFor(chat),
          placement: projection.placementFor(chat),
        );
        expect(await eligible({'body': 'Fictional text'}), isFalse);
        expect(
          await eligible({
            'm.mentions': {
              'user_ids': [client.userID],
            },
          }),
          isTrue,
        );
        expect(
          await eligible({
            'm.mentions': {
              'user_ids': ['@other:example.invalid'],
            },
          }),
          isFalse,
        );
        expect(
          await eligible({
            'm.mentions': {'room': true},
          }),
          isFalse,
        );
        expect(
          await eligible({
            'm.mentions': {
              'user_ids': [client.userID],
            },
          }, outgoing: true),
          isFalse,
        );
        // Thread replies alone do not qualify, even without a cached parent.
        expect(
          await eligible({
            'm.relates_to': {
              'rel_type': RelationshipTypes.thread,
              'event_id': r'$root',
              'm.in_reply_to': {'event_id': r'$parent'},
            },
          }),
          isFalse,
        );
      }
      expect(chatLoomPushRuleTarget(personal).silence, isEmpty);
    },
  );

  test(
    'inherited Aside applies to groups while a stricter mute and Ignored still win',
    () async {
      final client = ConversationClient();
      final chat = ConversationRoom(client, '!group:example.invalid');
      const bot = '@bridge:example.invalid';
      chat.state(EventTypes.RoomMember, {'membership': 'join'}, key: bot);
      chat.setState(
        Event(
          room: chat,
          type: 'm.bridge',
          stateKey: 'fixture',
          senderId: bot,
          eventId: r'$group-bridge',
          originServerTs: DateTime.utc(2026),
          content: {
            'bridgebot': bot,
            'protocol': {'id': 'whatsapp'},
            'com.beeper.room_type.v2': 'group',
          },
        ),
      );
      final personal = _Personal(client);
      addTearDown(personal.dispose);
      personal.values['network-policy:whatsapp'] = {'groupPlacement': 'aside'};
      var projection = InboxProjection(personal);
      expect(projection.placementFor(chat), ChatPlacement.aside);
      expect(
        projection.notificationModeFor(chat),
        PersonalNotificationMode.mentionsOnly,
      );
      personal.values['org:${chat.id}'] = {'notificationMode': 'muted'};
      projection = InboxProjection(personal);
      expect(
        projection.notificationModeFor(chat),
        PersonalNotificationMode.muted,
      );
      expect(chatLoomPushRuleTarget(personal).silence, {chat.id});
      personal.values['org:${chat.id}'] = {'ignored': true};
      projection = InboxProjection(personal);
      expect(projection.placementFor(chat), ChatPlacement.ignored);
      expect(
        projection.rooms(client.rooms, filter: InboxFilter.aside),
        isEmpty,
      );
      expect(projection.rooms(client.rooms, filter: InboxFilter.ignored), [
        chat,
      ]);
    },
  );
}
