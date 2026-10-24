// SPDX-License-Identifier: AGPL-3.0-or-later
// Network chat actions (wave 6 FX-01/FX-02/FX-05/BR-06/BR-08/BR-10/BR-11):
// bridge declarations, the events ChatLoom sends, the bridge's answer,
// message requests, the contact sheet, the request callout and bridge
// notices. Synthetic rooms and ids only; nothing reaches a server (the send
// is replaced by a test seam).
import 'dart:async';

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/composer_recipient_notice.dart';
import 'package:chatloom/pages/chat_details/participant_list_item.dart';
import 'package:chatloom/pages/chat_list/inbox_controller.dart';
import 'package:chatloom/personal/bridge_notices.dart';
import 'package:chatloom/personal/conversation_classification.dart';
import 'package:chatloom/personal/inbox_projection.dart';
import 'package:chatloom/personal/message_delivery.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/personal/network_chat_actions.dart';
import 'package:chatloom/personal/personal_client.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/contact_sheet.dart';
import 'package:chatloom/personal/ui/message_request_callout.dart';
import 'package:chatloom/personal/ui/network_action_flows.dart';
import 'package:chatloom/personal/ui/notion_inbox_view_chips.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '@fixture:example.invalid';
const _bot = '@instagrambot:example.invalid';
const _ghost = '@instagram_1:example.invalid';
const _stranger = '@someone:example.invalid';

class _Db implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client() : super('synthetic network actions', database: _Db());
  @override
  String get userID => _owner;
}

/// Records read markers instead of sending them.
class _Room extends Room {
  _Room({required super.id, required super.client})
    : super(membership: Membership.join);
  final markers = <bool>[];
  @override
  Future<void> setReadMarker(
    String? eventId, {
    String? mRead,
    bool? public,
  }) async {
    markers.add(public ?? true);
  }
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
    eventId: '\$fixture-${room.id}-$type-$key-${content.hashCode}',
    originServerTs: DateTime.utc(2026),
  ),
);

/// An Instagram-like DM portal. [features] is the bridge's
/// `com.beeper.room_features`; [channel] extra bridge-info channel flags.
_Room _portal(
  Client client, {
  String id = 'dm',
  Map<String, dynamic> features = const {},
  Map<String, dynamic> channel = const {},
  String featuresSender = _bot,
  String infoSender = _bot,
  String network = 'instagramgo',
  List<String> identifiers = const ['instagram:fictional.person'],
  String kind = 'dm',
}) {
  final room = _Room(id: '!$id:example.invalid', client: client);
  client.rooms.add(room);
  _state(room, EventTypes.RoomName, {'name': 'Fictional Person'});
  _state(
    room,
    'm.bridge',
    {
      'bridgebot': _bot,
      'protocol': {'id': network},
      'channel': {'id': 'remote-$id', ...channel},
      'com.beeper.room_type.v2': kind,
    },
    key: 'bridge-key',
    sender: infoSender,
  );
  _state(
    room,
    'com.beeper.room_features',
    features,
    key: 'bridge-key',
    sender: featuresSender,
  );
  _state(room, EventTypes.RoomMember, {'membership': 'join'}, key: _owner);
  _state(room, EventTypes.RoomMember, {
    'membership': 'join',
    'com.beeper.bridge.is_bridge_bot': true,
  }, key: _bot);
  _state(room, EventTypes.RoomMember, {
    'membership': 'join',
    'displayname': 'Fictional Person',
    'com.beeper.bridge.identifiers': identifiers,
  }, key: _ghost);
  room.summary.mJoinedMemberCount = 3;
  room.summary.mInvitedMemberCount = 0;
  room.summary.mHeroes = [_ghost];
  return room;
}

Event _status(Room room, String target, String status, {String? message}) =>
    Event(
      room: room,
      type: beeperMessageSendStatusType,
      content: {
        'status': status,
        'message': ?message,
        'm.relates_to': {'rel_type': 'm.reference', 'event_id': target},
      },
      senderId: _bot,
      eventId: '\$status-$target-$status',
      originServerTs: DateTime.now(),
    );

Event _notice(Room room, Map<String, Object?> content, {String? sender}) =>
    Event(
      room: room,
      type: EventTypes.Message,
      content: {'msgtype': MessageTypes.Notice, ...content},
      senderId: sender ?? _ghost,
      eventId: '\$notice-${content.hashCode}',
      originServerTs: DateTime.utc(2026),
    );

class _Private extends PersonalClient {
  _Private(super.client)
    : super.forTesting(
        openStore: () async => throw StateError('No fixture files'),
      );
  @override
  bool get ready => true;
  @override
  Future<void> load() async {}
}

Widget _app(Widget child) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: NotionTheme.build(Brightness.dark),
  localizationsDelegates: L10n.localizationsDelegates,
  supportedLocales: L10n.supportedLocales,
  home: Scaffold(body: child),
);

/// Mounts [child] and lets localizations load.
Future<void> _mount(WidgetTester tester, Widget child) async {
  await tester.pumpWidget(_app(child));
  await tester.pumpAndSettle();
  expect(find.byType(Scaffold), findsOneWidget, reason: 'app mounted');
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  tearDown(() => NetworkChatActions.sendOverride = null);

  group('declarations', () {
    test('room features and channel flags from the room\'s own bot', () {
      final client = _Client();
      final room = _portal(
        client,
        features: {
          'delete_chat': true,
          'delete_chat_for_everyone': true,
          'block_user': true,
          'report_spam': true,
          'message_request': {'accept_with_button': 2},
        },
        channel: {
          'com.beeper.message_request': true,
          'com.beeper.user_blocked': true,
        },
      );
      final features = NetworkChatFeatures.of(room);
      expect(features.network, 'instagram');
      expect(features.bridgeBot, _bot);
      expect(features.deleteChat, isTrue);
      expect(features.deleteChatForEveryone, isTrue);
      expect(features.blockUser, isTrue);
      expect(features.reportSpam, isTrue);
      expect(features.acceptWithButton, isTrue);
      expect(features.messageRequest, isTrue);
      expect(features.userBlocked, isTrue);
      expect(isMessageRequest(room), isTrue);
      // Memoised until a source state event is replaced.
      expect(identical(NetworkChatFeatures.of(room), features), isTrue);
    });

    test('a member\'s forged declaration offers nothing', () {
      final client = _Client();
      final forgedFeatures = _portal(
        client,
        features: {'delete_chat': true, 'block_user': true},
        featuresSender: _stranger,
      );
      expect(NetworkChatFeatures.of(forgedFeatures).deleteChat, isFalse);
      expect(NetworkChatFeatures.of(forgedFeatures).blockUser, isFalse);
      final forgedInfo = _portal(
        client,
        id: 'forged',
        features: {'delete_chat': true},
        channel: {'com.beeper.message_request': true},
        infoSender: _stranger,
      );
      expect(NetworkChatFeatures.of(forgedInfo).deleteChat, isFalse);
      expect(isMessageRequest(forgedInfo), isFalse);
    });

    test('two bridges in one room are ambiguous: nothing offered', () {
      final client = _Client();
      final room = _portal(client, features: {'delete_chat': true});
      _state(
        room,
        'm.bridge',
        {
          'bridgebot': '@otherbot:example.invalid',
          'protocol': {'id': 'whatsapp'},
          'channel': {'id': 'x'},
        },
        key: 'other',
        sender: '@otherbot:example.invalid',
      );
      expect(NetworkChatFeatures.of(room).deleteChat, isFalse);
    });

    test('event contents match bridgev2 (omitzero fields left out)', () {
      expect(deleteChatContent(), isEmpty);
      expect(deleteChatContent(forEveryone: true, fromMessageRequest: true), {
        'delete_for_everyone': true,
        'from_message_request': true,
      });
      expect(blockUserContent(block: true), {'block': true});
      expect(blockUserContent(block: true, reportSpam: true), {
        'block': true,
        'report_spam': true,
      });
      // Unblocking never reports.
      expect(blockUserContent(block: false, reportSpam: true), {
        'block': false,
      });
    });
  });

  group('actions wait for the bridge', () {
    test('delete: refused by the network, the row comes back', () async {
      final client = _Client();
      final room = _portal(client, features: {'delete_chat': true});
      final sent = <(String, Map<String, Object>)>[];
      NetworkChatActions.sendOverride = (room, type, content) async {
        sent.add((type, content));
        expect(NetworkChatActions.isDeleting(room), isTrue);
        scheduleMicrotask(
          () => client.onTimelineEvent.add(
            _status(
              room,
              r'$delete',
              'FAIL_PERMANENT',
              message: 'Chat not found',
            ),
          ),
        );
        return r'$delete';
      };
      final result = await NetworkChatActions.deleteChat(
        room,
        forEveryone: true,
      );
      expect(result.outcome, NetworkActionOutcome.rejected);
      expect(result.text, 'Chat not found.');
      // forEveryone is dropped where the bridge does not declare it.
      expect(sent.single.$1, beeperDeleteChatType);
      expect(sent.single.$2, isEmpty);
      expect(NetworkChatActions.isDeleting(room), isFalse);
    });

    test('delete: the bridge removing the room is the success', () async {
      final client = _Client();
      final room = _portal(
        client,
        features: {'delete_chat': true, 'delete_chat_for_everyone': true},
      );
      final changes = <String>[];
      final sub = NetworkChatActions.changes(client).listen(changes.add);
      NetworkChatActions.sendOverride = (room, type, content) async {
        expect(content, {'delete_for_everyone': true});
        scheduleMicrotask(() {
          room.membership = Membership.leave;
          client.onSync.add(SyncUpdate(nextBatch: ''));
        });
        return r'$delete';
      };
      final result = await NetworkChatActions.deleteChat(
        room,
        forEveryone: true,
      );
      expect(result.done, isTrue);
      expect(changes, [room.id]);
      await sub.cancel();
    });

    test('delete: no answer brings the row back and says so', () async {
      final client = _Client();
      final room = _portal(client, features: {'delete_chat': true});
      NetworkChatActions.sendOverride = (room, type, content) async =>
          r'$delete';
      final result = await NetworkChatActions.deleteChat(
        room,
        wait: const Duration(milliseconds: 20),
      );
      expect(result.outcome, NetworkActionOutcome.noAnswer);
      expect(result.text, contains('Instagram hasn’t answered yet'));
      expect(NetworkChatActions.isDeleting(room), isFalse);
    });

    test('nothing is sent where the bridge declares nothing', () async {
      final client = _Client();
      final room = _portal(client);
      var sends = 0;
      NetworkChatActions.sendOverride = (room, type, content) async {
        sends++;
        return r'$x';
      };
      expect(
        (await NetworkChatActions.deleteChat(room)).outcome,
        NetworkActionOutcome.rejected,
      );
      expect(
        (await NetworkChatActions.setBlocked(room, block: true)).outcome,
        NetworkActionOutcome.rejected,
      );
      expect(sends, 0);
    });

    test('block: SUCCESS from the bot; spam report only if declared', () async {
      final client = _Client();
      final room = _portal(client, features: {'block_user': true});
      final sent = <Map<String, Object>>[];
      NetworkChatActions.sendOverride = (room, type, content) async {
        expect(type, beeperBlockUserType);
        sent.add(content);
        // A status from anyone but the bridge bot is ignored.
        scheduleMicrotask(() {
          client.onTimelineEvent.add(
            Event(
              room: room,
              type: beeperMessageSendStatusType,
              content: {
                'status': 'FAIL_PERMANENT',
                'm.relates_to': {'event_id': r'$block'},
              },
              senderId: _stranger,
              eventId: r'$forged',
              originServerTs: DateTime.now(),
            ),
          );
          client.onTimelineEvent.add(_status(room, r'$block', 'SUCCESS'));
        });
        return r'$block';
      };
      final result = await NetworkChatActions.setBlocked(
        room,
        block: true,
        reportSpam: true,
      );
      expect(result.done, isTrue);
      expect(sent, [
        {'block': true},
      ]);
    });

    test(
      'accept: the bridge clearing the request flag is the success',
      () async {
        final client = _Client();
        final room = _portal(
          client,
          features: {
            'message_request': {'accept_with_button': 2},
          },
          channel: {'com.beeper.message_request': true},
        );
        NetworkChatActions.sendOverride = (room, type, content) async {
          expect(type, beeperAcceptMessageRequestType);
          expect(content, isEmpty);
          scheduleMicrotask(() {
            _state(
              room,
              'm.bridge',
              {
                'bridgebot': _bot,
                'protocol': {'id': 'instagramgo'},
                'channel': {'id': 'remote-dm'},
              },
              key: 'bridge-key',
              sender: _bot,
            );
            client.onSync.add(SyncUpdate(nextBatch: ''));
          });
          return r'$accept';
        };
        final result = await NetworkChatActions.acceptRequest(room);
        expect(result.done, isTrue);
        expect(isMessageRequest(room), isFalse);
      },
    );
  });

  group('message requests', () {
    test('classified, filtered into Requests, quiet, kept in the inbox', () {
      final client = _Client();
      final request = _portal(
        client,
        channel: {'com.beeper.message_request': true},
      );
      final friend = _portal(client, id: 'friend');
      final classifier = ConversationClassifier(client.rooms);
      expect(classifier.classify(request).messageRequest, isTrue);
      expect(classifier.classify(friend).messageRequest, isFalse);

      final personal = _Private(client);
      final projection = InboxProjection.snapshot(personal);
      final index = projection.buildIndex(client.rooms);
      expect(projection.select(index, filter: InboxFilter.requests), [request]);
      // Not hidden from the main list (Needs J: Instagram moves them out).
      expect(projection.select(index), containsAll([request, friend]));
      expect(
        InboxProjection(personal).notificationModeFor(request),
        PersonalNotificationMode.mentionsOnly,
      );
      expect(
        InboxProjection(personal).notificationModeFor(friend),
        PersonalNotificationMode.all,
      );
      personal.dispose();
    });

    test('a chat being deleted leaves the inbox index', () async {
      final client = _Client();
      final room = _portal(client, features: {'delete_chat': true});
      final personal = _Private(client);
      final completer = Completer<String?>();
      NetworkChatActions.sendOverride = (room, type, content) =>
          completer.future;
      final pending = NetworkChatActions.deleteChat(
        room,
        wait: const Duration(milliseconds: 20),
      );
      await Future<void>.delayed(Duration.zero);
      final projection = InboxProjection.snapshot(personal);
      expect(projection.select(projection.buildIndex(client.rooms)), isEmpty);
      completer.complete(null);
      expect((await pending).outcome, NetworkActionOutcome.rejected);
      final again = InboxProjection.snapshot(personal);
      expect(again.select(again.buildIndex(client.rooms)), [room]);
      personal.dispose();
    });

    test('no public read receipt before the request is accepted', () async {
      final client = _Client();
      client.baseUri = Uri.parse('https://example.invalid');
      await AppSettings.sendPublicReadReceipts.setItem(true);
      final request = _portal(
        client,
        channel: {'com.beeper.message_request': true},
      );
      final friend = _portal(client, id: 'friend');
      await PersonalPrivacy.markRead(request, r'$seen', manual: true);
      await PersonalPrivacy.markRead(friend, r'$seen', manual: true);
      expect(request.markers, [false]);
      expect(friend.markers, [true]);
      // Replying accepts the request: the receipt after it may be public.
      await PersonalPrivacy.markRead(request, r'$seen2', acceptedReply: true);
      expect(request.markers, [false, true]);
    });

    test('projectInbox: the Requests view leaves archived requests out', () {
      InboxRecord record(
        String id, {
        bool request = false,
        bool archived = false,
      }) => InboxRecord(
        representativeRoomId: id,
        entityId: id,
        displayName: id,
        messageRequest: request,
        metadata: ConversationMetadata(entityId: id, archived: archived),
      );
      final result = projectInbox([
        record('a', request: true),
        record('b'),
        record('c', request: true, archived: true),
      ], filter: InboxFilter.requests);
      expect(result.map((r) => r.entityId), ['a']);
    });
  });

  group('bridge notices (BR-08)', () {
    test('known notices become service lines in ChatLoom\'s words', () {
      final client = _Client();
      final room = _portal(client, network: 'whatsapp');
      String? text(Map<String, Object?> content) =>
          bridgeServiceNotice(_notice(room, content))?.text;
      expect(
        text({
          'body':
              'Decrypting message from WhatsApp failed, waiting for sender '
              'to re-send... ([learn more](https://example.invalid))',
          'fi.mau.whatsapp.undecryptable': true,
        }),
        'Waiting for this message. This can take a while.',
      );
      expect(
        text({
          'body': 'An error occurred while processing an incoming message',
          'fi.mau.bridge.internal_error': 'x',
        }),
        'A message from WhatsApp couldn’t be shown. Open WhatsApp to see it.',
      );
      expect(
        text({
          'body': 'Old photo. Requesting old media is not enabled.',
          'fi.mau.whatsapp.failed_media': {'x': 1},
        }),
        'Old photo isn’t available here.',
      );
      expect(
        text({
          'body': 'Failed to bridge video, please view it on the WhatsApp app',
        }),
        'This video couldn’t be shown here. Open WhatsApp to see it.',
      );
      expect(
        text({'body': 'Set the disappearing message timer to 1 day'}),
        'Disappearing messages: 1 day',
      );
      expect(
        text({
          'body':
              'Automatically turned off disappearing messages because '
              'incoming message is not disappearing',
        }),
        'Disappearing messages turned off',
      );
      // A caption after the sentence keeps the bubble.
      expect(text({'body': 'Old photo. Not enabled.\n\nA caption'}), isNull);
      // A contact's own notice text stays a message.
      expect(text({'body': 'See you at 6'}), isNull);
      // The inbox preview uses the same words.
      final preview = personalEventPreview(
        _notice(room, {'body': 'Set the disappearing message timer to 1 week'}),
      );
      expect(preview, contains('Disappearing messages: 1 week'));
    });

    test('never in a native Matrix room, never for own events', () {
      final client = _Client();
      final room = Room(id: '!native:example.invalid', client: client);
      expect(
        bridgeServiceNotice(
          _notice(room, {
            'body': 'Set the disappearing message timer to 1 day',
          }),
        ),
        isNull,
      );
      final bridged = _portal(client, id: 'own');
      expect(
        bridgeServiceNotice(
          _notice(bridged, {
            'body': 'Set the disappearing message timer to 1 day',
          }, sender: _owner),
        ),
        isNull,
      );
    });
  });

  group('pins and view-once media', () {
    test('bridged pins stay in ChatLoom; view-once media is flagged', () {
      final client = _Client();
      final room = _portal(client, network: 'telegram');
      expect(pinStaysInChatLoom(room), 'Telegram');
      expect(
        pinStaysInChatLoom(Room(id: '!native:example.invalid', client: client)),
        isNull,
      );
      Event media(Map<String, Object?> extra) => Event(
        room: room,
        type: EventTypes.Message,
        content: {'msgtype': MessageTypes.Image, 'body': 'x', ...extra},
        senderId: _ghost,
        eventId: '\$m-${extra.length}',
        originServerTs: DateTime.utc(2026),
      );
      expect(
        isViewLimited(
          media({
            'com.beeper.view_limited': {'type': 'count', 'count': 1},
          }),
        ),
        isTrue,
      );
      expect(isViewLimited(media({})), isFalse);
    });

    test('a known portal names its bridge bot (BR-11)', () {
      final client = _Client();
      _portal(client);
      expect(knownBridgeBot(client, 'instagram'), _bot);
      expect(knownBridgeBot(client, 'whatsapp'), isNull);
    });
  });

  group('contact sheet (FX-05)', () {
    test('identifiers: phone and username, never internal ids', () {
      final client = _Client();
      final room = _portal(
        client,
        identifiers: [
          'tel:+48 600 000 000',
          'telegram:fictional',
          'slack-internal:U123',
          'telegram:fictional',
        ],
      );
      expect(contactIdentifiers(room, _ghost), const [
        ContactIdentifier(ContactIdentifierKind.phone, '+48600000000'),
        ContactIdentifier(ContactIdentifierKind.username, '@fictional'),
      ]);
      expect(contactIdentifiers(room, _stranger), isEmpty);
      expect(isBridgeBotMember(room, _bot), isTrue);
      expect(bridgedContactRoom(client, _ghost), room);
      expect(bridgedContactRoom(client, _bot), isNull);
      expect(directPortalWith(client, _ghost), room);
    });

    testWidgets('a bridged contact: network, username, block; no ghost ID', (
      tester,
    ) async {
      final client = _Client();
      final room = _portal(client, features: {'block_user': true});
      await _mount(
        tester,
        Builder(
          builder: (context) =>
              ContactSheet(room: room, userId: _ghost, host: context),
        ),
      );
      await tester.pump();
      expect(find.text('Fictional Person'), findsWidgets);
      expect(find.text('Instagram'), findsOneWidget);
      expect(find.text('@fictional.person'), findsOneWidget);
      expect(find.text('Block on Instagram'), findsOneWidget);
      expect(find.text('Ignore here'), findsOneWidget);
      expect(find.textContaining('example.invalid'), findsNothing);
      expect(find.textContaining('matrix.to'), findsNothing);
      // Opened from the DM itself: no "Message" row back to it.
      expect(find.byKey(const ValueKey('contact-message')), findsNothing);
      expect(tester.takeException(), isNull);
    });

    testWidgets('participants: identifier subtitle, never the ghost ID', (
      tester,
    ) async {
      final client = _Client();
      final room = _portal(client);
      final user = room.unsafeGetUserFromMemoryOrFallback(_ghost);
      expect(ParticipantListItem.subtitleFor(user), '@fictional.person');
      await _mount(tester, ParticipantListItem(user));
      await tester.pump();
      expect(find.text('Fictional Person'), findsOneWidget);
      expect(find.text('@fictional.person'), findsOneWidget);
      expect(find.text(_ghost), findsNothing);
      expect(tester.takeException(), isNull);
    });
  });

  group('request callout (FX-02)', () {
    testWidgets('Accept, Delete and Block where declared; Accept hides it', (
      tester,
    ) async {
      final client = _Client();
      final room = _portal(
        client,
        features: {
          'delete_chat': true,
          'block_user': true,
          'message_request': {'accept_with_button': 2},
        },
        channel: {'com.beeper.message_request': true},
      );
      final sent = <String>[];
      NetworkChatActions.sendOverride = (room, type, content) async {
        sent.add(type);
        return r'$accept';
      };
      await _mount(tester, MessageRequestCallout(room: room));
      await tester.pump();
      expect(
        find.text('Message request from Fictional Person on Instagram'),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('message-request-accept')), findsOne);
      expect(find.byKey(const ValueKey('message-request-delete')), findsOne);
      expect(find.byKey(const ValueKey('message-request-block')), findsOne);
      await tester.tap(find.byKey(const ValueKey('message-request-accept')));
      await tester.pump();
      expect(sent, [beeperAcceptMessageRequestType]);
      // The bridge answers: SUCCESS for the accept event.
      client.onTimelineEvent.add(_status(room, r'$accept', 'SUCCESS'));
      await tester.pumpAndSettle();
      expect(
        find
            .text('Message request from Fictional Person on Instagram')
            .hitTestable(),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('only the declared buttons; nothing for an ordinary chat', (
      tester,
    ) async {
      final client = _Client();
      final request = _portal(
        client,
        channel: {'com.beeper.message_request': true},
      );
      await _mount(tester, MessageRequestCallout(room: request));
      await tester.pump();
      expect(find.byKey(const ValueKey('message-request-callout')), findsOne);
      expect(
        find.byKey(const ValueKey('message-request-accept')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('message-request-block')), findsNothing);

      final friend = _portal(client, id: 'friend');
      await _mount(tester, MessageRequestCallout(room: friend));
      await tester.pump();
      expect(
        find.byKey(const ValueKey('message-request-callout')),
        findsNothing,
      );
    });

    testWidgets('the composer says that replying accepts', (tester) async {
      final client = _Client();
      final room = _portal(
        client,
        channel: {'com.beeper.message_request': true},
      );
      await _mount(
        tester,
        ComposerRecipientNotice(room: room, confirm: (_) async {}),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(ComposerRecipientNotice.requestText('Fictional Person')),
        findsOneWidget,
      );
    });

    testWidgets('delete asks first, with "also for" only where declared', (
      tester,
    ) async {
      final client = _Client();
      final room = _portal(
        client,
        features: {'delete_chat': true, 'delete_chat_for_everyone': true},
      );
      final question = deleteChatQuestion(room, name: 'Fictional Person');
      expect(question.title, 'Delete chat with Fictional Person?');
      expect(question.message, contains('This can’t be undone'));
      expect(question.option, 'Also delete it for Fictional Person');
      final plain = _portal(
        client,
        id: 'plain',
        features: {'delete_chat': true},
      );
      expect(deleteChatQuestion(plain, name: 'X').option, isNull);

      final sent = <Map<String, Object>>[];
      NetworkChatActions.sendOverride = (room, type, content) async {
        sent.add(content);
        return null;
      };
      await _mount(
        tester,
        Builder(
          builder: (context) => TextButton(
            onPressed: () =>
                deleteNetworkChatFlow(context, room, name: 'Fictional Person'),
            child: const Text('open'),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(find.text('Delete chat with Fictional Person?'), findsOneWidget);
      // Cancel sends nothing.
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(sent, isEmpty);
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('network-action-option')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('network-action-confirm')));
      await tester.pumpAndSettle();
      expect(sent, [
        {'delete_for_everyone': true},
      ]);
      // The send failed (no event id): the user is told, the row is back.
      expect(find.textContaining('Couldn’t reach the server'), findsOneWidget);
      expect(NetworkChatActions.isDeleting(room), isFalse);
    });

    testWidgets('the Requests chip appears only while there are requests', (
      tester,
    ) async {
      await _mount(
        tester,
        const NotionInboxViewChips(
          selected: InboxFilter.inbox,
          onViewSelected: null,
        ),
      );
      expect(find.text('Requests'), findsNothing);
      await _mount(
        tester,
        const NotionInboxViewChips(
          selected: InboxFilter.inbox,
          onViewSelected: null,
          requestCount: 2,
        ),
      );
      expect(find.text('Requests'), findsOneWidget);
      expect(find.text('2'), findsOneWidget);
    });
  });

  test('the inbox controller rebuilds when a deletion starts', () async {
    final client = _Client();
    final room = _portal(client, features: {'delete_chat': true});
    final personal = _Private(client);
    final inbox = InboxController(
      client,
      personal,
      debounce: Duration.zero,
      maxWait: Duration.zero,
    );
    final generation = inbox.generation;
    NetworkChatActions.sendOverride = (room, type, content) async => null;
    await NetworkChatActions.deleteChat(room);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(inbox.generation, greaterThan(generation));
    inbox.dispose();
    personal.dispose();
  });
}
