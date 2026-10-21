// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/push_rule_check.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

const _owner = '@synthetic-owner:example.invalid';
const _peer = '@synthetic-peer:example.invalid';

class _UnusedDatabase implements DatabaseApi {
  // The evaluator looks up the account's display name.
  @override
  Future<User?> getUser(String userId, Room room) async => null;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Client extends Client {
  _Client() : super('push rule check', database: _UnusedDatabase());
  @override
  String? get userID => _owner;
}

Map<String, Object?> _rule(
  String id, {
  bool enabled = true,
  List<Object?> actions = const ['notify'],
  List<Map<String, Object?>> conditions = const [],
}) => {
  'rule_id': id,
  'default': true,
  'enabled': enabled,
  'actions': actions,
  'conditions': conditions,
};

Map<String, Object?> _type(String type) => {
  'kind': 'event_match',
  'key': 'type',
  'pattern': type,
};

const _twoMembers = {'kind': 'room_member_count', 'is': '2'};

/// The spec's default rules that matter here; [messages] toggles
/// `.m.rule.message` (Beeper-style "direct chats and mentions only").
Map<String, Object?> _rules({
  bool master = false,
  bool messages = true,
  List<Map<String, Object?>> extraOverride = const [],
}) => {
  'override': [
    _rule('.m.rule.master', enabled: master, actions: const []),
    _rule(
      '.m.rule.suppress_notices',
      actions: const [],
      conditions: const [
        {
          'kind': 'event_match',
          'key': 'content.msgtype',
          'pattern': 'm.notice',
        },
      ],
    ),
    ...extraOverride,
  ],
  'underride': [
    _rule(
      '.m.rule.room_one_to_one',
      actions: const [
        'notify',
        {'set_tweak': 'sound', 'value': 'default'},
      ],
      conditions: [_twoMembers, _type('m.room.message')],
    ),
    _rule(
      '.m.rule.encrypted_room_one_to_one',
      conditions: [_twoMembers, _type('m.room.encrypted')],
    ),
    _rule(
      '.m.rule.message',
      enabled: messages,
      conditions: [_type('m.room.message')],
    ),
    _rule('.m.rule.encrypted', conditions: [_type('m.room.encrypted')]),
  ],
};

void _setRules(Client client, Map<String, Object?> global) =>
    client.accountData['m.push_rules'] = BasicEvent(
      type: 'm.push_rules',
      content: {'global': global},
    );

Event _message(Room room, {String msgtype = MessageTypes.Text}) => Event(
  type: EventTypes.Message,
  content: {'msgtype': msgtype, 'body': 'synthetic text'},
  senderId: _peer,
  eventId: r'$synthetic-event',
  originServerTs: DateTime.utc(2026, 10, 21),
  room: room,
);

Room _room(Client client, int joined) => Room(
  id: '!synthetic-room:example.invalid',
  client: client,
  summary: RoomSummary.fromJson({'m.joined_member_count': joined}),
);

void main() {
  test('a two-person chat matches room_one_to_one by the server\'s member '
      'count, although no member events are loaded on the phone', () {
    final client = _Client();
    _setRules(client, _rules(messages: false));
    final dm = _room(client, 2);
    final event = _message(dm);
    // The SDK counts members held in memory (none in the push isolate) and
    // silenced this direct message although the server pushed it.
    expect(dm.getParticipants([Membership.join]), isEmpty);
    expect(
      PushruleEvaluator.fromRuleset(
        client.globalPushRules!,
      ).match(event).notify,
      isFalse,
    );
    expect(personalPushRuleVerdict(client, event), PushRuleVerdict.notify);
    // A real group with ".m.rule.message" off stays silent.
    expect(
      personalPushRuleVerdict(client, _message(_room(client, 5))),
      PushRuleVerdict.silenced,
    );
  });

  test('default rules notify for messages, silence notices and honour Do '
      'Not Disturb', () {
    final client = _Client();
    _setRules(client, _rules());
    final group = _room(client, 7);
    expect(personalPushRuleVerdict(client, _message(group)).allows, isTrue);
    expect(
      personalPushRuleVerdict(
        client,
        _message(group, msgtype: MessageTypes.Notice),
      ),
      PushRuleVerdict.silenced,
    );
    _setRules(client, _rules(master: true));
    expect(
      personalPushRuleVerdict(client, _message(group)),
      PushRuleVerdict.silenced,
    );
  });

  test('without synced rules the server\'s decision stands', () {
    final client = _Client();
    expect(client.globalPushRules, isNull);
    final verdict = personalPushRuleVerdict(client, _message(_room(client, 3)));
    expect(verdict, PushRuleVerdict.notLoaded);
    expect(verdict.allows, isTrue);
    _setRules(client, const {});
    expect(
      personalPushRuleVerdict(client, _message(_room(client, 3))),
      PushRuleVerdict.notLoaded,
    );
  });

  test('rules the phone cannot evaluate defer to the server, except Do Not '
      'Disturb', () {
    final client = _Client();
    final custom = _rule(
      'com.example.custom',
      conditions: const [
        {'kind': 'com.example.unknown_condition', 'key': 'x'},
      ],
    );
    _setRules(client, _rules(messages: false, extraOverride: [custom]));
    final group = _room(client, 4);
    expect(
      personalPushRuleVerdict(client, _message(group)),
      PushRuleVerdict.unevaluable,
    );
    expect(personalPushRuleVerdict(client, _message(group)).allows, isTrue);
    _setRules(
      client,
      _rules(master: true, messages: false, extraOverride: [custom]),
    );
    expect(
      personalPushRuleVerdict(client, _message(group)),
      PushRuleVerdict.silenced,
    );
  });

  test('member count conditions follow the spec operators', () {
    expect(memberCountMatches('2', 2), isTrue);
    expect(memberCountMatches('==2', 3), isFalse);
    expect(memberCountMatches('>2', 3), isTrue);
    expect(memberCountMatches('<2', 1), isTrue);
    expect(memberCountMatches('>=10', 10), isTrue);
    expect(memberCountMatches('<=10', 11), isFalse);
    expect(memberCountMatches('two', 2), isNull);
    expect(memberCountMatches(null, 2), isNull);
    final resolved = resolveMemberCount(PushRuleSet.fromJson(_rules()), 3);
    final oneToOne = resolved.underride!.firstWhere(
      (rule) => rule.ruleId == '.m.rule.room_one_to_one',
    );
    expect(oneToOne.enabled, isFalse);
    expect(
      oneToOne.conditions!.any((c) => c.kind == 'room_member_count'),
      isFalse,
    );
    final message = resolved.underride!.firstWhere(
      (rule) => rule.ruleId == '.m.rule.message',
    );
    expect(message.enabled, isTrue);
  });

  test('the account summary names only default rules and their effect', () {
    final client = _Client();
    expect(AccountPushRulesSummary.of(client).loaded, isFalse);
    _setRules(client, _rules(messages: false));
    final summary = AccountPushRulesSummary.of(client);
    expect(summary.loaded, isTrue);
    expect(summary.doNotDisturb, isFalse);
    expect(summary.oneToOne, AccountRuleState.notify);
    expect(summary.groups, AccountRuleState.off);
    expect(summary.groupsSilent, isTrue);
    expect(summary.encryptedGroups, AccountRuleState.notify);
    expect(summary.unknownConditions, isFalse);
    for (final state in AccountRuleState.values) {
      expect(accountRuleStateLabel(state), isNotEmpty);
    }
  });
}
