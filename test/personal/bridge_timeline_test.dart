// SPDX-License-Identifier: AGPL-3.0-or-later

import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/events/state_message.dart';
import 'package:chatloom/personal/bridge_notices.dart';
import 'package:chatloom/personal/bridge_timeline.dart';
import 'package:chatloom/personal/message_preview.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:chatloom/utils/matrix_sdk_extensions/filtered_timeline_extension.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _owner = '@owner:example.invalid';
const _bot = '@service:example.invalid';
const _contact = '@remote_1:example.invalid';

class _Database implements DatabaseApi {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unexpected database access');
}

class _Client extends Client {
  _Client() : super('offline bridge timeline', database: _Database());
  @override
  String get userID => _owner;
}

Event _event(
  Room room,
  String type,
  Map<String, dynamic> content, {
  String? key = '',
  String sender = _bot,
  Map<String, dynamic>? previous,
}) => Event(
  room: room,
  type: type,
  content: content,
  senderId: sender,
  eventId: '\$fixture-${content.hashCode}',
  stateKey: key,
  unsigned: previous == null ? null : {'prev_content': previous},
  originServerTs: DateTime.utc(2026, 11, 3),
);

Room _room(String network) {
  final room = Room(id: '!fixture:example.invalid', client: _Client());
  if (network != 'matrix') {
    room.setState(
      _event(room, 'm.bridge', {
        'bridgebot': _bot,
        'protocol': {'id': network},
      }, key: 'portal'),
    );
  }
  return room;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  for (final network in ['whatsapp', 'instagram', 'telegram', 'slack']) {
    test(
      '$network hides bridge provisioning but keeps messages and safety',
      () {
        final room = _room(network);
        final hidden = [
          _event(room, 'm.bridge', {'bridgebot': _bot}),
          _event(room, 'com.beeper.room_features', {'id': 'fixture'}),
          _event(room, EventTypes.RoomPowerLevels, {
            'users': {_bot: 100},
          }),
          _event(room, EventTypes.RoomMember, {
            'membership': 'invite',
            'fi.mau.will_auto_accept': true,
          }, key: _contact),
          _event(
            room,
            EventTypes.RoomMember,
            {'membership': 'join', 'displayname': 'Fixture Person'},
            key: _contact,
            sender: _contact,
            previous: {
              'membership': 'invite',
              'com.beeper.exclude_from_timeline': true,
            },
          ),
          _event(
            room,
            EventTypes.RoomMember,
            {'membership': 'join', 'displayname': 'New name'},
            key: _contact,
            previous: {'membership': 'join', 'displayname': 'Old name'},
          ),
          _event(room, EventTypes.RoomAvatar, {
            'url': 'mxc://example.invalid/photo',
            'fi.mau.implicit_name': true,
          }),
        ];
        expect(hidden.where((e) => e.isVisibleInGui), isEmpty);
        final kept = [
          _event(room, EventTypes.Message, {
            'body': 'Fictional text',
            'msgtype': 'm.text',
            'com.beeper.exclude_from_timeline': true,
          }, key: null),
          _event(room, EventTypes.Encryption, {
            'algorithm': 'm.megolm.v1.aes-sha2',
            'com.beeper.exclude_from_timeline': true,
          }),
          _event(room, EventTypes.RoomTombstone, {
            'body': 'Chat moved',
            'replacement_room': '!new:example.invalid',
          }),
          _event(
            room,
            EventTypes.RoomMember,
            {'membership': 'leave', 'displayname': 'Fixture Person'},
            key: _contact,
            previous: {'membership': 'join'},
          ),
          _event(room, EventTypes.RoomMember, {
            'membership': 'invite',
          }, key: _owner),
        ];
        expect(kept.every((e) => e.isVisibleInGui), isTrue);
        expect([...hidden, ...kept].filterByVisibleInGui(), kept);
      },
    );
  }

  test('remote join uses final display name and never a bot or unknown id', () {
    final room = _room('whatsapp');
    final join = _event(
      room,
      EventTypes.RoomMember,
      {'membership': 'join', 'displayname': 'Fixture Person'},
      key: _contact,
      sender: _contact,
      previous: {'membership': 'invite'},
    );
    expect(join.isVisibleInGui, isTrue);
    expect(bridgeStateText(join), 'Fixture Person joined the chat');
    expect(personalPreviewLabel(join), 'Fixture Person joined the chat');
    final unknown = _event(
      room,
      EventTypes.RoomMember,
      {'membership': 'leave'},
      key: _contact,
      previous: {'membership': 'join'},
    );
    expect(bridgeStateText(unknown), 'Someone was removed from the chat');
  });

  test('real permission changes remain visible with readable copy', () {
    final room = _room('whatsapp');
    final changed = _event(
      room,
      EventTypes.RoomPowerLevels,
      {'events_default': 50},
      previous: {'events_default': 0},
    );
    expect(changed.isVisibleInGui, isTrue);
    expect(personalEventPreview(changed), 'Chat permissions updated');
  });

  test('native Matrix membership and permissions retain SDK behavior', () {
    final room = _room('matrix');
    final event = _event(room, EventTypes.RoomMember, {
      'membership': 'invite',
      'fi.mau.will_auto_accept': true,
    }, key: _contact);
    expect(event.isVisibleInGui, isTrue);
    expect(bridgeStateText(event), isNull);
  });

  test('remote promotions survive while bot power housekeeping is hidden', () {
    final room = _room('whatsapp');
    final promotion = _event(
      room,
      EventTypes.RoomPowerLevels,
      {
        'users': {_bot: 100, _contact: 50},
      },
      previous: {
        'users': {_bot: 100, _contact: 0},
      },
    );
    expect(promotion.isVisibleInGui, isTrue);
    final botChange = _event(
      room,
      EventTypes.RoomPowerLevels,
      {
        'users': {_bot: 100, _contact: 0},
      },
      previous: {
        'users': {_bot: 50},
      },
    );
    expect(botChange.isVisibleInGui, isFalse);
    final settingsChange = _event(
      room,
      EventTypes.RoomPowerLevels,
      {'state_default': 0},
      previous: {
        'users': {_bot: 100},
      },
    );
    expect(settingsChange.isVisibleInGui, isTrue);
    final equivalentDefault = _event(
      room,
      EventTypes.RoomPowerLevels,
      {'state_default': 50},
      previous: {
        'users': {_bot: 100},
      },
    );
    expect(equivalentDefault.isVisibleInGui, isFalse);
  });

  test('history notices use service copy, no sender prefix or identifiers', () {
    final room = _room('whatsapp');
    for (final extra in [
      <String, dynamic>{},
      {
        'com.beeper.action_message': {'type': 'message_history_notice'},
      },
    ]) {
      final event = _event(
        room,
        EventTypes.Message,
        {
          'msgtype': 'm.notice',
          'body':
              'Fixture Person sent message history to Unknown user (7 messages), starting Oct 4, 2026 at 8:32 PM.',
          ...extra,
        },
        key: null,
        sender: _contact,
      );
      expect(
        bridgeServiceNotice(event)?.text,
        'Earlier messages were shared in WhatsApp.',
      );
      expect(
        personalEventPreview(event),
        'Earlier messages were shared in WhatsApp.',
      );
    }
    final ordinary = _event(
      room,
      EventTypes.Message,
      {'msgtype': 'm.notice', 'body': 'I sent message history yesterday.'},
      key: null,
      sender: _contact,
    );
    expect(bridgeServiceNotice(ordinary), isNull);
    final ownHistory = _event(
      room,
      EventTypes.Message,
      {
        'msgtype': 'm.notice',
        'body': 'Fictional history notice',
        'com.beeper.action_message': {'type': 'message_history_notice'},
      },
      key: null,
      sender: _owner,
    );
    expect(
      personalEventPreview(ownHistory),
      'Earlier messages were shared in WhatsApp.',
    );
    final ownText = _event(
      room,
      EventTypes.Message,
      {'msgtype': 'm.notice', 'body': 'Fixture Person sent message history.'},
      key: null,
      sender: _owner,
    );
    expect(bridgeServiceNotice(ownText), isNull);
  });

  test('bridge calls retain the type and any reported outcome', () {
    final telegram = _room('telegram');
    const outcomes = {
      'Call missed': BridgeCallOutcome.missed,
      'Call rejected': BridgeCallOutcome.rejected,
      'Call disconnected': BridgeCallOutcome.disconnected,
      'Video call ended (1 hour, 2 minutes and 3 seconds)':
          BridgeCallOutcome.ended,
    };
    for (final MapEntry(key: body, value: outcome) in outcomes.entries) {
      final event = _event(
        telegram,
        EventTypes.Message,
        {'msgtype': MessageTypes.Notice, 'body': body},
        key: null,
        sender: _owner,
      );
      final call = bridgeCallNotice(event)!;
      final video = body.startsWith('Video');
      expect(call.kind, video ? BridgeCallKind.video : BridgeCallKind.voice);
      expect(call.outcome, outcome);
      expect(
        call.duration,
        video ? const Duration(hours: 1, minutes: 2, seconds: 3) : null,
      );
      expect(personalEventPreview(event), body);
    }
    final instagram = _event(
      _room('instagram'),
      EventTypes.Message,
      {
        'msgtype': MessageTypes.Notice,
        'body': 'Video call ended\n1 minute',
        'com.beeper.action_message': {'type': 'call', 'call_type': 'video'},
      },
      key: null,
      sender: _contact,
    );
    expect(bridgeServiceNotice(instagram)?.icon, Icons.videocam_outlined);
    expect(bridgeServiceNotice(instagram)?.text, 'Video call ended 1 minute');
    expect(bridgeCallNotice(instagram)?.duration, const Duration(minutes: 1));
    final messenger = _event(
      _room('messenger'),
      EventTypes.Message,
      {
        'msgtype': MessageTypes.Text,
        'body': 'Missed audio call',
        'com.beeper.action_message': {'type': 'call', 'call_type': 'voice'},
      },
      key: null,
      sender: _contact,
    );
    expect(bridgeServiceNotice(messenger)?.text, 'Missed audio call');
    expect(bridgeCallNotice(messenger)?.outcome, BridgeCallOutcome.missed);
    final slack = _room('slack');
    final huddle = _event(slack, EventTypes.Message, {
      'msgtype': MessageTypes.Notice,
      'body': 'Huddle ended',
    }, key: null);
    expect(bridgeServiceNotice(huddle)?.isCall, isTrue);
    final start = _event(slack, EventTypes.Message, {
      'msgtype': MessageTypes.Notice,
      'body':
          'Huddle started\n\nJoin via the Slack app: https://example.invalid',
      'format': 'org.matrix.custom.html',
      'formatted_body': 'Huddle started with a link',
    }, key: null);
    expect(bridgeServiceNotice(start), isNull);
  });

  test('structured call details retain the facts supplied by the bridge', () {
    final whatsapp = _room('whatsapp');
    final event = _event(
      whatsapp,
      EventTypes.Message,
      {
        'msgtype': MessageTypes.Text,
        'body': 'Localized label from the network',
        'com.beeper.action_message': {'type': 'call'},
        'com.chatloom.call': {
          'call_type': 'video',
          'status': 'answered',
          'direction': 'outgoing',
          'duration_seconds': 127,
        },
      },
      key: null,
      sender: _owner,
    );
    final call = bridgeCallNotice(event)!;
    expect(call.network, 'WhatsApp');
    expect(call.kind, BridgeCallKind.video);
    expect(call.outcome, BridgeCallOutcome.answered);
    expect(call.direction, BridgeCallDirection.outgoing);
    expect(call.duration, const Duration(minutes: 2, seconds: 7));

    final unknown = _event(_room('instagram'), EventTypes.Message, {
      'msgtype': MessageTypes.Notice,
      'body': 'Localized label from the network',
      'com.beeper.action_message': {'type': 'call', 'call_type': 'video'},
      'com.chatloom.call': {'duration_seconds': -1, 'status': 'unexpected'},
    }, key: null);
    final unreported = bridgeCallNotice(unknown)!;
    expect(unreported.kind, BridgeCallKind.video);
    expect(unreported.outcome, BridgeCallOutcome.unknown);
    expect(unreported.direction, isNull);
    expect(unreported.duration, isNull);
  });

  test(
    'tagged Messenger history reports clock durations and explicit zero',
    () {
      final messenger = _room('messenger');
      for (final (body, duration) in [
        ('Video call (0:00)', Duration.zero),
        (
          'Video call (1:02:03)',
          const Duration(hours: 1, minutes: 2, seconds: 3),
        ),
      ]) {
        final event = _event(messenger, EventTypes.Message, {
          'msgtype': MessageTypes.Text,
          'body': body,
          'com.beeper.action_message': {'type': 'call', 'call_type': 'video'},
        }, key: null);
        final call = bridgeCallNotice(event)!;
        expect(call.outcome, BridgeCallOutcome.ended);
        expect(call.duration, duration);
      }
    },
  );

  test(
    'ordinary text, native Matrix and deleted calls keep their own paths',
    () {
      final telegram = _room('telegram');
      final body = {'body': 'Call missed', 'msgtype': MessageTypes.Text};
      expect(
        bridgeServiceNotice(
          _event(telegram, EventTypes.Message, body, key: null),
        ),
        isNull,
      );
      final tagged = {
        ...body,
        'com.beeper.action_message': {'type': 'call'},
      };
      expect(
        bridgeServiceNotice(
          _event(_room('matrix'), EventTypes.Message, tagged, key: null),
        ),
        isNull,
      );
      final call = _event(telegram, EventTypes.Message, tagged, key: null);
      call.setRedactionEvent(
        _event(telegram, EventTypes.Redaction, {}, key: null),
      );
      expect(bridgeServiceNotice(call), isNull);
    },
  );

  testWidgets('state row renders readable remote action and no technical row', (
    tester,
  ) async {
    final room = _room('whatsapp');
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        home: Scaffold(
          body: Column(
            children: [
              StateMessage(
                _event(
                  room,
                  EventTypes.RoomMember,
                  {'membership': 'join', 'displayname': 'Fixture Person'},
                  key: _contact,
                  sender: _contact,
                  previous: {'membership': 'invite'},
                ),
              ),
              StateMessage(
                _event(room, EventTypes.RoomPowerLevels, {
                  'users': {_bot: 100},
                }),
              ),
            ],
          ),
        ),
      ),
    );
    expect(find.text('Fixture Person joined the chat'), findsOneWidget);
    expect(find.textContaining('bridge'), findsNothing);
    expect(find.textContaining('permissions'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
