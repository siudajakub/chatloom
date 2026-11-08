// SPDX-License-Identifier: AGPL-3.0-or-later
// Offline source-bound policy, link projection and forwarding fixtures only.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat_input_row.dart';
import 'package:chatloom/pages/chat/events/poll.dart';
import 'package:chatloom/pages/chat/message_link_actions.dart';
import 'package:chatloom/pages/chat/start_poll_bottom_sheet.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/personal/privacy.dart';
import 'package:chatloom/personal/ui/conversation_content_controller.dart';
import 'package:chatloom/personal/ui/forward_sheet.dart';
import 'package:chatloom/personal/whatsapp/whatsapp_action_policy.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:matrix/src/models/timeline_chunk.dart';
import 'package:personal_core/personal_core.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

Map<String, dynamic> _interactive({String? body}) => {
  'msgtype': MessageTypes.Text,
  'body': body ?? 'Legacy fallback',
  'format': 'org.matrix.custom.html',
  'formatted_body': '<b>Legacy fallback</b>',
  WhatsAppInteractiveContent.contentKey: {
    'schema_version': 1,
    'body': 'A fictional announcement',
    'actions': [
      {
        'kind': 'url',
        'label': 'View post',
        'url': 'https://example.invalid/post_(a)',
      },
      {'kind': 'url', 'label': 'More', 'url': 'https://example.invalid/more'},
    ],
  },
};

ConversationRoom _room(String network) {
  final room = ConversationRoom(
    ConversationClient(),
    '!fixture:example.invalid',
    network: network,
  );
  room.state(bridgeFeaturesEventType, {
    'id': 'fixture',
    'poll': 2,
  }, key: 'fixture');
  return room;
}

Map<String, dynamic> _pollContent() => PollEventContent(
  mText: 'Which day?',
  pollStartContent: PollStartContent(
    kind: PollKind.disclosed,
    maxSelections: 1,
    question: PollQuestion(mText: 'Which day?'),
    answers: [
      PollAnswer(id: 'one', mText: 'Monday'),
      PollAnswer(id: 'two', mText: 'Tuesday'),
    ],
  ),
).toJson();

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  test('each bridge state type and protocol alias blocks only WhatsApp', () {
    for (final type in [
      'm.bridge',
      'uk.half-shot.bridge',
      'com.beeper.bridge',
    ]) {
      for (final protocol in ['whatsapp', 'whatsappgo', ' WhatsApp ']) {
        final room = _room('matrix');
        room.states.remove('m.bridge');
        room.state(type, {
          'protocol': {'id': protocol},
        }, key: 'source');
        expect(WhatsAppActionPolicy.isWhatsApp(room), isTrue);
        for (final action in WhatsAppAction.values) {
          expect(WhatsAppActionPolicy.allows(room, action), isFalse);
        }
      }
    }
    for (final network in ['matrix', 'telegram', 'messenger', 'unknown']) {
      final room = _room(network);
      expect(WhatsAppActionPolicy.isWhatsApp(room), isFalse);
      expect(WhatsAppActionPolicy.allows(room, WhatsAppAction.vote), isTrue);
      expect(
        WhatsAppActionPolicy.allows(room, WhatsAppAction.replyButton),
        isFalse,
      );
      expect(
        WhatsAppActionPolicy.allows(room, WhatsAppAction.listReply),
        isFalse,
      );
    }
  });

  test('the composer source decides whether a poll can be created', () {
    expect(composerAttachOffers(_room('whatsapp')).poll, isFalse);
    expect(composerAttachOffers(_room('matrix')).poll, isTrue);
    final unknown = _room('unknown');
    unknown.states.remove(bridgeFeaturesEventType);
    expect(composerAttachOffers(unknown).poll, isTrue);
  });

  test(
    'direct and final transport hooks block WhatsApp mutations in both privacy modes',
    () async {
      for (final incognito in [false, true]) {
        await AppSettings.personalIncognito.setItem(incognito);
        final room = _room('whatsapp');
        final client = room.client;
        PersonalPrivacy.bind(client);
        addTearDown(() => PersonalPrivacy.forget(client));
        for (final type in [
          PollEventContent.startType,
          PollEventContent.responseType,
          PollEventContent.endType,
        ]) {
          await expectLater(
            Future<void>.sync(
              () => client.authorizeOutgoingEvent!(room, type, {}),
            ),
            throwsA(isA<PersonalCapabilityUnavailable>()),
          );
          var transmitted = false;
          await expectLater(
            client.wrapOutgoingRequest!(
              room,
              type,
              {},
              'fixture-transaction',
              () async {
                transmitted = true;
                return r'$accepted';
              },
            ),
            throwsA(isA<PersonalCapabilityUnavailable>()),
          );
          expect(transmitted, isFalse);
        }
        for (final content in [
          _pollContent(),
          {'m.new_content': _pollContent()},
          _interactive(),
        ]) {
          await expectLater(
            Future<void>.sync(
              () => client.authorizeOutgoingEvent!(
                room,
                EventTypes.Message,
                content,
              ),
            ),
            throwsA(isA<PersonalCapabilityUnavailable>()),
          );
        }
      }
      await AppSettings.personalIncognito.setItem(true);
    },
  );

  test(
    'native Matrix poll authorization and ordinary WhatsApp text remain intact',
    () async {
      for (final network in ['matrix', 'whatsapp']) {
        final room = _room(network);
        PersonalPrivacy.bind(room.client);
        addTearDown(() => PersonalPrivacy.forget(room.client));
        await room.client.authorizeOutgoingEvent!(room, EventTypes.Message, {
          'msgtype': MessageTypes.Text,
          'body': 'A fictional message',
        });
        if (network == 'matrix') {
          for (final type in [
            PollEventContent.startType,
            PollEventContent.responseType,
            PollEventContent.endType,
          ]) {
            await room.client.authorizeOutgoingEvent!(room, type, {});
          }
        }
      }
    },
  );

  testWidgets('a legacy WhatsApp PollWidget has no voting or end control', (
    tester,
  ) async {
    final room = _room('whatsapp');
    final event = Event(
      room: room,
      eventId: r'$poll',
      type: PollEventContent.startType,
      senderId: room.client.userID!,
      originServerTs: DateTime.utc(2026),
      content: _pollContent(),
    );
    final timeline = Timeline(
      room: room,
      chunk: TimelineChunk(events: [event]),
    );
    addTearDown(timeline.cancelSubscriptions);
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(
          body: PollWidget(
            event: event,
            timeline: timeline,
            textColor: Colors.white,
            linkColor: Colors.white,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Which day?'), findsOneWidget);
    expect(find.byType(CheckboxListTile), findsNWidgets(2));
    for (final tile in tester.widgetList<CheckboxListTile>(
      find.byType(CheckboxListTile),
    )) {
      expect(tile.onChanged, isNull);
    }
    expect(find.text('End poll'), findsNothing);
  });

  testWidgets('directly opened WhatsApp create sheet stays disabled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(body: StartPollBottomSheet(room: _room('whatsapp'))),
      ),
    );
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Which day?');
    await tester.enterText(fields.at(1), 'Monday');
    await tester.enterText(fields.at(2), 'Tuesday');
    await tester.pump();
    expect(
      tester
          .widget<NotionButton>(find.byKey(const ValueKey('poll-create')))
          .onPressed,
      isNull,
    );
  });

  test('Copy link and profile Links include exact valid CTA targets', () {
    final room = _room('whatsapp');
    final content = _interactive();
    final event = room.message(
      r'$interactive',
      content['body'] as String,
      content: content,
    );
    expect(messageFirstLink(event), 'https://example.invalid/post_(a)');
    expect(sharedLinks(event), [
      'https://example.invalid/post_(a)',
      'https://example.invalid/more',
    ]);
    final bodyFirst = _interactive(
      body: 'Legacy https://example.invalid/stale',
    );
    (bodyFirst[WhatsAppInteractiveContent.contentKey] as Map)['body'] =
        'Read https://example.invalid/body';
    expect(
      messageFirstLink(
        room.message(
          r'$withbody',
          bodyFirst['body'] as String,
          content: bodyFirst,
        ),
      ),
      'https://example.invalid/body',
    );
  });

  for (final url in [
    'https://example.invalid/file?sig=abc!',
    'https://example.invalid/file?sig=abc.',
    'https://example.invalid/file?sig=abc?',
    'https://example.invalid/file?',
    'https://example.invalid/file?download=1&sig=abc!',
  ]) {
    test('copy and profile preserve signed CTA punctuation: $url', () {
      final room = _room('whatsapp');
      final content = _interactive(body: 'Legacy button: $url');
      content['formatted_body'] = '<p>Legacy button: $url</p>';
      final clean = content[WhatsAppInteractiveContent.contentKey] as Map;
      clean['actions'] = [
        {'kind': 'url', 'label': 'View post', 'url': url},
      ];
      final event = room.message(
        r'$fallback-url',
        content['body'] as String,
        content: content,
      );
      expect(messageFirstLink(event), url);
      expect(sharedLinks(event), [url]);

      // Even when clean prose repeats the action with sentence
      // punctuation, no truncated alternate URL is manufactured.
      clean['body'] = 'Read $url.';
      final repeated = room.message(
        r'$clean-url',
        content['body'] as String,
        content: content,
      );
      expect(messageFirstLink(repeated), url);
      expect(sharedLinks(repeated), [url]);
    });
  }

  test('clean prose links keep priority over actions and legacy fallback', () {
    final room = _room('whatsapp');
    final content = _interactive(body: 'Legacy https://example.invalid/stale');
    final clean = content[WhatsAppInteractiveContent.contentKey] as Map;
    clean['body'] = 'Read https://example.invalid/clean';
    final event = room.message(
      r'$clean-prose',
      content['body'] as String,
      content: content,
    );
    expect(messageFirstLink(event), 'https://example.invalid/clean');
    expect(sharedLinks(event), [
      'https://example.invalid/clean',
      'https://example.invalid/post_(a)',
      'https://example.invalid/more',
    ]);
  });

  test('clean formatted links replace legacy formatted button fallback', () {
    final room = _room('whatsapp');
    final content = _interactive(body: 'Legacy https://example.invalid/stale');
    content['formatted_body'] =
        '<a href="https://example.invalid/stale">Fallback</a>';
    final clean = content[WhatsAppInteractiveContent.contentKey] as Map;
    clean['formatted_body'] =
        '<a href="https://example.invalid/clean">Article</a>';
    final event = room.message(
      r'$clean-formatted',
      content['body'] as String,
      content: content,
    );
    expect(messageFirstLink(event), 'https://example.invalid/clean');
    expect(sharedLinks(event), [
      'https://example.invalid/clean',
      'https://example.invalid/post_(a)',
      'https://example.invalid/more',
    ]);
  });

  test('forward strips source payload and keeps each URL as ordinary text', () {
    final original = _interactive();
    final forwarded = forwardableContent(original);
    expect(
      forwarded.containsKey(WhatsAppInteractiveContent.contentKey),
      isFalse,
    );
    expect(forwarded.containsKey('formatted_body'), isFalse);
    expect(forwarded.containsKey('format'), isFalse);
    expect(
      forwarded['body'],
      'A fictional announcement\n\nView post: https://example.invalid/post_(a)\n\nMore: https://example.invalid/more',
    );
    expect(original.containsKey(WhatsAppInteractiveContent.contentKey), isTrue);
    expect(
      () => WhatsAppActionPolicy.authorizeOutgoing(
        _room('whatsapp'),
        EventTypes.Message,
        forwarded,
      ),
      returnsNormally,
    );
    final invalid = _interactive();
    (invalid[WhatsAppInteractiveContent.contentKey] as Map)['schema_version'] =
        2;
    expect(
      forwardableContent(
        invalid,
      ).containsKey(WhatsAppInteractiveContent.contentKey),
      isFalse,
    );
    expect(forwardableContent(invalid)['body'], 'Legacy fallback');
  });

  test('forward keeps a CTA that is only a prefix of another prose URL', () {
    final content = _interactive();
    final clean = content[WhatsAppInteractiveContent.contentKey] as Map;
    clean['body'] = 'Read https://example.invalid/poster';
    clean['actions'] = [
      {
        'kind': 'url',
        'label': 'View post',
        'url': 'https://example.invalid/post',
      },
      {
        'kind': 'url',
        'label': 'Same post',
        'url': 'https://example.invalid/post',
      },
    ];
    expect(
      forwardableContent(content)['body'],
      'Read https://example.invalid/poster\n\nView post: https://example.invalid/post',
    );
  });

  test('forwarding CTA preserves encrypted and ordinary media descriptors', () {
    for (final media in <Map<String, dynamic>>[
      {
        'file': {
          'url': 'mxc://example.invalid/encrypted-fixture',
          'v': 'v2',
          'iv': 'fictional-iv',
          'hashes': {'sha256': 'fictional-hash'},
          'key': {'kty': 'oct', 'alg': 'A256CTR', 'k': 'fictional-key'},
        },
      },
      {'url': 'mxc://example.invalid/ordinary-fixture'},
    ]) {
      final content = {
        ..._interactive(),
        'msgtype': MessageTypes.Image,
        'filename': 'fictional.png',
        'info': {'mimetype': 'image/png', 'w': 32, 'h': 32, 'size': 123},
        ...media,
      };
      final forwarded = forwardableContent(content);
      for (final key in ['msgtype', 'filename', 'info', ...media.keys]) {
        expect(forwarded[key], content[key]);
      }
      expect(forwarded[WhatsAppInteractiveContent.contentKey], isNull);
      expect(forwarded['body'], contains('https://example.invalid/post_(a)'));
      expect(content[WhatsAppInteractiveContent.contentKey], isA<Map>());
    }
  });
}
