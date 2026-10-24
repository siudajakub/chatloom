// SPDX-License-Identifier: AGPL-3.0-or-later
// FX-08: @ mention and # room autocomplete. Fictional offline fixtures.
import 'package:chatloom/config/setting_keys.dart';
import 'package:chatloom/pages/chat/input_bar.dart';
import 'package:chatloom/personal/mention_suggestions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:matrix/matrix.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../notion/conversation_test_support.dart';

ConversationRoom _room({bool bridged = true}) {
  final client = ConversationClient();
  final room = ConversationRoom(client, '!fixture:example.invalid');
  room
    // The fixture's bridge info, with its bot.
    ..state('m.bridge', {
      'bridgebot': '@whatsappbot:example.invalid',
      'protocol': {'id': 'whatsapp'},
    }, key: 'fixture')
    ..state(EventTypes.RoomMember, {
      'membership': 'join',
      'displayname': 'Łukasz Żółw',
    }, key: '@whatsapp_4800000001:example.invalid')
    ..state(EventTypes.RoomMember, {
      'membership': 'join',
      'displayname': 'Żaneta Kowalska',
    }, key: '@whatsapp_4800000002:example.invalid')
    ..state(EventTypes.RoomMember, {
      'membership': 'join',
      'displayname': 'WhatsApp bridge bot',
    }, key: '@whatsappbot:example.invalid')
    ..state(EventTypes.RoomMember, {
      'membership': 'leave',
      'displayname': 'Zoë Former',
    }, key: '@whatsapp_4800000003:example.invalid');
  if (!bridged) room.states.remove('m.bridge');
  final joined = room.getParticipants([Membership.join]).length;
  room.summary = RoomSummary.fromJson({
    'm.joined_member_count': joined,
    'm.invited_member_count': 0,
  });
  return room;
}

List<String?> _names(Room room, String query, {String? privateName}) => [
  for (final c in mentionSuggestions(room, query, privateName: privateName))
    c.user.displayName,
];

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await AppSettings.init(loadWebConfigFile: false);
  });

  group('mentionRank', () {
    test('folds diacritics and case on word starts', () {
      expect(mentionRank('Łu', ['Łukasz Żółw']), 0);
      expect(mentionRank('lu', ['Łukasz Żółw']), 0);
      expect(mentionRank('zol', ['Łukasz Żółw']), 1);
      expect(mentionRank('ŻÓŁ', ['Łukasz Żółw']), 1);
      expect(mentionRank('kasz', ['Łukasz Żółw']), isNull);
      expect(mentionRank('zoe', ['Zoë']), 0);
      expect(mentionRank('', ['Anyone']), 0);
      expect(mentionRank('x', [null, '  ']), isNull);
    });
  });

  group('patterns', () {
    test('@ and # open on any script, not inside words', () {
      expect(mentionQueryPattern.firstMatch('hi @Łu')?[1], 'Łu');
      expect(mentionQueryPattern.firstMatch('@Żan')?[1], 'Żan');
      expect(mentionQueryPattern.firstMatch('hi @')?[1], '');
      expect(mentionQueryPattern.firstMatch('mail a@b'), isNull);
      expect(roomQueryPattern.firstMatch('see #ogólny')?[1], 'ogólny');
      expect(roomQueryPattern.firstMatch('see #'), isNull);
      expect(
        'hi @Łu'.replaceAllMapped(mentionTokenPattern, (m) => '${m[1]}@x '),
        'hi @x ',
      );
    });
  });

  group('mentionSuggestions', () {
    test('lists the people of the chat, not the own account or bots', () {
      final room = _room();
      expect(_names(room, ''), ['Anna', 'Łukasz Żółw', 'Żaneta Kowalska']);
      expect(_names(room, 'Ł'), ['Łukasz Żółw']);
      expect(_names(room, 'z'), ['Żaneta Kowalska', 'Łukasz Żółw']);
      expect(_names(room, 'kow'), ['Żaneta Kowalska']);
      expect(_names(room, 'whatsapp'), isEmpty, reason: 'bot and puppet IDs');
      expect(_names(room, '48'), isEmpty);
    });

    test('the direct chat partner matches on the private nickname', () {
      final room = _room();
      expect(_names(room, 'sis', privateName: 'Sister'), ['Anna']);
      expect(_names(room, 'sis'), isEmpty);
    });

    test('native Matrix rooms also match on localparts', () {
      final room = _room(bridged: false);
      expect(_names(room, 'anna'), ['Anna']);
      expect(_names(room, 'whatsapp_48'), hasLength(2));
    });
  });

  group('room suggestions', () {
    test('never in bridged chats, never without an alias', () {
      final bridged = _room();
      expect(roomSuggestionsAllowed(bridged), isFalse);
      final native = _room(bridged: false);
      expect(roomSuggestionsAllowed(native), isTrue);
      final client = native.client;
      final aliased = ConversationRoom(client, '!aliased:example.invalid')
        ..state(EventTypes.RoomName, {'name': 'Ogólny'})
        ..state(EventTypes.RoomCanonicalAlias, {
          'alias': '#general:example.invalid',
        });
      aliased.states.remove('m.bridge');
      ConversationRoom(client, '!noalias:example.invalid')
        ..state(EventTypes.RoomName, {'name': 'Ogólny prywatny'})
        ..states.remove('m.bridge');
      final rooms = roomSuggestions(client, 'ogol');
      expect(rooms.map((r) => r.id), ['!aliased:example.invalid']);
      expect(roomSuggestions(client, 'gen').single.canonicalAlias, isNotEmpty);
    });
  });

  test('InputBar offers Polish names and inserts a mention', () {
    final room = _room();
    final controller = TextEditingController(text: 'cześć @Żan');
    final bar = InputBar(
      room: room,
      controller: controller,
      decoration: const InputDecoration(),
      suggestionEmojis: const [],
    );
    const text = TextEditingValue(
      text: 'cześć @Żan',
      selection: TextSelection.collapsed(offset: 10),
    );
    final suggestions = bar.getSuggestions(text);
    expect(suggestions.map((s) => s['displayname']), ['Żaneta Kowalska']);
    controller.selection = text.selection;
    final inserted = bar.insertSuggestion(suggestions.single);
    expect(inserted, startsWith('cześć @'));
    expect(inserted, isNot(contains('@Żan ')));
    // `#` is not offered in a bridged chat.
    expect(
      bar.getSuggestions(
        const TextEditingValue(
          text: 'see #gen',
          selection: TextSelection.collapsed(offset: 8),
        ),
      ),
      isEmpty,
    );
  });
}
