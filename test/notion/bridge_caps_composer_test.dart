// SPDX-License-Identifier: AGPL-3.0-or-later
// BR-02/03/09, FX-12, UI-07: what the composer, the poll sheet and the chat
// details offer follows each network's declaration. Fictional offline
// fixtures only (shapes of the bridges' `GetCapabilities`).
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/l10n/l10n.dart';
import 'package:chatloom/pages/chat/chat_input_row.dart';
import 'package:chatloom/pages/chat/conversation_message_actions.dart';
import 'package:chatloom/pages/chat/start_poll_bottom_sheet.dart';
import 'package:chatloom/personal/capabilities.dart';
import 'package:chatloom/ui/notion/notion.dart';
import 'package:chatloom/ui/notion/notion_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'conversation_test_support.dart';

Map<String, Object?> _files(Iterable<String> types) => {
  for (final type in types)
    type: {
      'mime_types': {'*/*': 2},
    },
};

final _whatsapp = <String, Object?>{
  'id': 'fixture.whatsapp+group',
  'file': _files(['m.image', 'm.video', 'm.file', 'm.audio']),
  'state': {
    'm.room.name': {'level': 2},
    'm.room.avatar': {'level': 2},
    'm.room.topic': {'level': 2},
  },
  'member_actions': {'invite': 2, 'kick': 2, 'leave': 2},
  'max_text_length': 65536,
  'location_message': 2,
  'poll': 2,
  'poll_end': 0,
  'poll_hidden_votes': 0,
  'poll_duplicate_options': 0,
  'poll_max_options': 12,
  'poll_option_max_length': 100,
  'reply': 2,
  'edit': 2,
  'delete': 2,
  'reaction': 2,
  'reaction_count': 1,
};

final _telegramDm = <String, Object?>{
  'id': 'fixture.telegram+dm',
  'file': _files(['m.image', 'm.video', 'm.file']),
  'state': {
    'com.beeper.disappearing_timer': {'level': 2},
  },
  'max_text_length': 4096,
  'location_message': 2,
  'reply': 2,
  'reaction': 2,
  'reaction_count': 1,
};

final _messengerGroup = <String, Object?>{
  'id': 'fixture.meta+group',
  'file': _files(['m.image', 'm.video', 'm.file']),
  'state': {
    'm.room.name': {'level': 2},
    'm.room.avatar': {'level': 2},
  },
  'member_actions': {'invite': 2, 'kick': 2},
  'max_text_length': 20000,
  'reply': 2,
  'reaction': 2,
};

final _slackDm = <String, Object?>{
  'id': 'fixture.slack+dm',
  'file': _files(['m.image', 'm.file']),
  'location_message': -2,
  'thread': 2,
  'reaction': 2,
};

ConversationRoom _room(String id, Map<String, Object?>? features) {
  final room = ConversationRoom(ConversationClient(), '!$id:example.invalid');
  if (features == null) {
    room.states.remove(bridgeFeaturesEventType);
  } else {
    room.state(bridgeFeaturesEventType, features, key: 'fixture');
  }
  return room;
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  test('the attach menu offers what each network takes', () {
    final native = composerAttachOffers(_room('native', null));
    expect(native, (
      media: true,
      file: true,
      photo: true,
      video: true,
      location: true,
      poll: true,
    ));
    final whatsapp = composerAttachOffers(_room('wa', _whatsapp));
    expect(whatsapp.poll && whatsapp.location && whatsapp.file, isTrue);
    final telegram = composerAttachOffers(_room('tg', _telegramDm));
    expect(telegram.poll, isFalse, reason: 'Telegram has no bridged polls');
    expect(telegram.location, isTrue);
    final messenger = composerAttachOffers(_room('fb', _messengerGroup));
    expect(messenger.poll, isFalse);
    expect(messenger.location, isFalse, reason: 'location is commented out');
    final slack = composerAttachOffers(_room('slack', _slackDm));
    expect(slack.location, isFalse);
    expect(slack.video, isFalse);
    expect(slack.media, isTrue, reason: 'images still go');
  });

  test('an omitted level refuses threads and replies only when declared', () {
    final whatsapp = _room('wa-thread', _whatsapp);
    expect(ConversationMessageActions.canThread(whatsapp), isFalse);
    expect(ConversationMessageActions.canThread(_room('n', null)), isTrue);
    final slack = _room('slack-thread', _slackDm);
    expect(ConversationMessageActions.canThread(slack), isTrue);
    final reply = slack.message(r'$slack', 'Fictional');
    expect(ConversationMessageActions.canReply(reply), isFalse);
    expect(
      RoomCapabilities.forFeature(
        BridgeFeature.poll,
        _room('tg-p', _telegramDm),
      ).reason,
      "Polls aren't supported on this network.",
    );
  });

  test('room state and member actions follow the declaration', () {
    final telegram = _room('tg-state', _telegramDm);
    expect(
      RoomCapabilities.stateAllowed(telegram, EventTypes.RoomName),
      isFalse,
    );
    expect(
      RoomCapabilities.stateAllowed(telegram, EventTypes.RoomAvatar),
      isFalse,
    );
    expect(RoomCapabilities.memberActionAllowed(telegram, 'invite'), isFalse);
    final messenger = _room('fb-state', _messengerGroup);
    expect(
      RoomCapabilities.stateAllowed(messenger, EventTypes.RoomName),
      isTrue,
    );
    expect(
      RoomCapabilities.stateAllowed(messenger, EventTypes.RoomTopic),
      isFalse,
    );
    expect(RoomCapabilities.memberActionAllowed(messenger, 'kick'), isTrue);
    expect(RoomCapabilities.memberActionAllowed(messenger, 'ban'), isFalse);
    final native = _room('native-state', null);
    expect(RoomCapabilities.stateAllowed(native, EventTypes.RoomName), isTrue);
    expect(RoomCapabilities.memberActionAllowed(native, 'kick'), isTrue);
    expect(RoomCapabilities.maxTextLength(telegram), 4096);
    expect(RoomCapabilities.maxTextLength(native), isNull);
  });

  test('poll limits come from the declaration', () {
    final whatsapp = pollLimitsOf(_room('wa-poll', _whatsapp));
    expect(whatsapp, (
      maxOptions: 12,
      optionLength: 100,
      hiddenVotes: false,
      duplicates: false,
    ));
    final native = pollLimitsOf(_room('native-poll', null));
    expect(native, (
      maxOptions: StartPollBottomSheet.maxOptions,
      optionLength: StartPollBottomSheet.optionLength,
      hiddenVotes: true,
      duplicates: true,
    ));
  });

  testWidgets('the poll sheet stops at the network limit', (tester) async {
    final room = _room('wa-sheet', {
      ..._whatsapp,
      'poll_max_options': 3,
      'poll_option_max_length': 5,
    });
    await tester.pumpWidget(
      MaterialApp(
        theme: NotionTheme.build(Brightness.dark),
        localizationsDelegates: L10n.localizationsDelegates,
        supportedLocales: L10n.supportedLocales,
        home: Scaffold(body: StartPollBottomSheet(room: room)),
      ),
    );
    await tester.pump();
    // Localizations load before the first full frame.
    await tester.pump(const Duration(milliseconds: 100));
    // A NotionSheet body, never a Scaffold/AppBar page.
    expect(find.byType(AppBar), findsNothing);
    final add = find.byKey(const ValueKey('poll-add-option'));
    await tester.tap(add);
    await tester.pump();
    expect(find.text('Up to 3 options'), findsOneWidget);
    expect(tester.widget<NotionButton>(add).onPressed, isNull);
    // Votes are always visible on this network: no switch for it.
    expect(find.text('Answers visible'), findsNothing);
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), 'Fictional question');
    await tester.enterText(fields.at(1), 'Longer than five');
    expect(tester.widget<TextField>(fields.at(1)).controller!.text, 'Longe');
    await tester.enterText(fields.at(2), 'Same');
    await tester.enterText(fields.at(3), 'same');
    await tester.pump();
    expect(find.textContaining('must be different'), findsOneWidget);
    final create = find.byKey(const ValueKey('poll-create'));
    expect(tester.widget<NotionButton>(create).onPressed, isNull);
    await tester.enterText(fields.at(3), 'Other');
    await tester.pump();
    expect(tester.widget<NotionButton>(create).onPressed, isNotNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
