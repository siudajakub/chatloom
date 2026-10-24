// SPDX-License-Identifier: AGPL-3.0-or-later
// Wave 7 push-rules lane (BP-07): ChatLoom mirrors chats muted for good and
// ignored chats into account push rules it owns. Fictional offline fixtures
// and a fake homeserver only; no account calls.
import 'package:chatloom/personal/push_rule_check.dart';
import 'package:chatloom/personal/push_rule_mirror.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';
import 'package:personal_core/personal_core.dart';

import '../notion/conversation_test_support.dart';

const _a = '!a:example.invalid';
const _b = '!b:example.invalid';
const _c = '!c:example.invalid';

Map<String, Object?> _ownRule(
  String room, {
  bool enabled = true,
  List<Object?> actions = const [],
  String? pattern,
}) => {
  'rule_id': chatLoomMuteRuleId(room),
  'default': false,
  'enabled': enabled,
  'actions': actions,
  'conditions': [
    {'kind': 'event_match', 'key': 'room_id', 'pattern': pattern ?? room},
  ],
};

/// The room's own Beeper/Element mute (rule id = room id), not ChatLoom's.
Map<String, Object?> _nativeMute(String room) => {
  'rule_id': room,
  'default': false,
  'enabled': true,
  'actions': const [],
  'conditions': [
    {'kind': 'event_match', 'key': 'room_id', 'pattern': room},
  ],
};

Map<String, Object?> _defaults({
  List<Map<String, Object?>> override = const [],
}) => {
  'override': [
    {
      'rule_id': '.m.rule.master',
      'default': true,
      'enabled': false,
      'actions': const [],
      'conditions': const [],
    },
    ...override,
  ],
  'underride': [
    {
      'rule_id': '.m.rule.message',
      'default': true,
      'enabled': true,
      'actions': const ['notify'],
      'conditions': const [
        {'kind': 'event_match', 'key': 'type', 'pattern': 'm.room.message'},
      ],
    },
  ],
};

PushRuleSet _set(Map<String, Object?> global) => PushRuleSet.fromJson(global);

/// A homeserver that keeps the account's rules in memory and records calls.
class _FakeServer implements PushRuleMirrorBackend {
  Map<String, Object?> global;

  /// Whether a write shows in [rules] at once (false: sync lags behind).
  bool syncs = true;
  Object? failure;
  final calls = <String>[];
  _FakeServer(this.global);

  List<Map<String, Object?>> get _override =>
      (global['override'] as List).cast<Map<String, Object?>>();

  @override
  PushRuleSet? get rules => _set(global);

  void _check(String ruleId) {
    // The mirror never names another rule.
    expect(isChatLoomMuteRuleId(ruleId), isTrue);
    final error = failure;
    if (error != null) throw error;
  }

  @override
  Future<void> put(String ruleId, String roomId) async {
    calls.add('put $roomId');
    _check(ruleId);
    if (!syncs) return;
    final list = _override.where((r) => r['rule_id'] != ruleId).toList();
    global = {
      ...global,
      'override': [_ownRule(roomId), ...list],
    };
  }

  @override
  Future<void> enable(String ruleId) async {
    calls.add('enable ${chatLoomMuteRuleRoom(ruleId)}');
    _check(ruleId);
    if (!syncs) return;
    global = {
      ...global,
      'override': [
        for (final r in _override)
          r['rule_id'] == ruleId ? {...r, 'enabled': true} : r,
      ],
    };
  }

  @override
  Future<void> delete(String ruleId) async {
    calls.add('delete ${chatLoomMuteRuleRoom(ruleId)}');
    _check(ruleId);
    if (!syncs) return;
    global = {
      ...global,
      'override': _override.where((r) => r['rule_id'] != ruleId).toList(),
    };
  }
}

PushRuleMirror _mirror(
  _FakeServer server,
  PushRuleMirrorTarget? Function() target, {
  DateTime Function()? now,
  int maxStepsPerPass = 25,
}) => PushRuleMirror(
  backend: server,
  target: target,
  spacing: Duration.zero,
  passGap: const Duration(hours: 1),
  debounce: const Duration(hours: 1),
  maxStepsPerPass: maxStepsPerPass,
  now: now,
);

void main() {
  group('ownership', () {
    test('only prefixed override rules are ChatLoom\'s', () {
      expect(chatLoomMuteRuleRoom(chatLoomMuteRuleId(_a)), _a);
      expect(chatLoomMuteRuleRoom(_a), isNull);
      expect(chatLoomMuteRuleRoom('.m.rule.master'), isNull);
      expect(chatLoomMuteRuleRoom(chatLoomMuteRulePrefix), isNull);
      final rules = _set(_defaults(override: [_ownRule(_a), _nativeMute(_b)]));
      final ids = withoutChatLoomRules(
        rules,
      ).override!.map((r) => r.ruleId).toList();
      expect(ids, ['.m.rule.master', _b]);
    });

    test('a plan never touches the room\'s own mute or other rules', () {
      final rules = _set(_defaults(override: [_nativeMute(_a)]));
      // Silence wanted for A (which already has a native mute): ChatLoom
      // adds its own rule and leaves the native one alone.
      final steps = planPushRuleMirror(rules, (silence: {_a}, known: {_a}));
      expect(steps, [(op: PushRuleMirrorOp.put, roomId: _a)]);
      // Not wanted any more: the native mute is not ChatLoom's to delete.
      expect(planPushRuleMirror(rules, (silence: {}, known: {_a})), isEmpty);
    });
  });

  group('plan', () {
    test('creates, repairs, enables and removes only what differs', () {
      final rules = _set(
        _defaults(
          override: [
            _ownRule(_a),
            _ownRule(_b, enabled: false),
            _ownRule(_c, actions: const ['notify']),
            _ownRule('!gone:example.invalid'),
            _ownRule('!unknown:example.invalid'),
          ],
        ),
      );
      final steps = planPushRuleMirror(rules, (
        silence: {_a, _b, _c, '!new:example.invalid'},
        known: {_a, _b, _c, '!new:example.invalid', '!gone:example.invalid'},
      ));
      expect(
        steps,
        unorderedEquals([
          (op: PushRuleMirrorOp.enable, roomId: _b),
          (op: PushRuleMirrorOp.put, roomId: _c),
          (op: PushRuleMirrorOp.put, roomId: '!new:example.invalid'),
          (op: PushRuleMirrorOp.delete, roomId: '!gone:example.invalid'),
        ]),
      );
    });

    test('a rule for another room id is repaired', () {
      final rules = _set(_defaults(override: [_ownRule(_a, pattern: _b)]));
      expect(planPushRuleMirror(rules, (silence: {_a}, known: {_a})), [
        (op: PushRuleMirrorOp.put, roomId: _a),
      ]);
    });
  });

  group('reconcile', () {
    test('writes once and is idempotent afterwards', () async {
      final server = _FakeServer(_defaults());
      var target = (silence: {_a, _b}, known: {_a, _b, _c});
      final mirror = _mirror(server, () => target);
      addTearDown(mirror.dispose);
      expect(await mirror.reconcile(), 2);
      expect(server.calls, unorderedEquals(['put $_a', 'put $_b']));
      expect(await mirror.reconcile(), 0);
      expect(chatLoomSilencedRooms(_clientWith(server.global)), {_a, _b});

      // Unmute B: its rule goes, A stays.
      target = (silence: {_a}, known: {_a, _b, _c});
      expect(await mirror.reconcile(), 1);
      expect(server.calls.last, 'delete $_b');
      expect(await mirror.reconcile(), 0);
    });

    test('a write sync has not shown yet is not sent again', () async {
      final server = _FakeServer(_defaults())..syncs = false;
      final mirror = _mirror(server, () => (silence: {_a}, known: {_a}));
      addTearDown(mirror.dispose);
      expect(await mirror.reconcile(), 1);
      expect(await mirror.reconcile(), 0);
      expect(server.calls, ['put $_a']);
    });

    test('nothing runs before private state or rules are known', () async {
      final server = _FakeServer(_defaults(override: [_ownRule(_a)]));
      final mirror = _mirror(server, () => null);
      addTearDown(mirror.dispose);
      expect(await mirror.reconcile(), 0);
      expect(server.calls, isEmpty);
    });

    test('errors back off exponentially and honour retry_after', () async {
      var now = DateTime.utc(2026, 10, 24, 12);
      final server = _FakeServer(_defaults())
        ..failure = MatrixException.fromJson({
          'errcode': 'M_UNKNOWN',
          'error': 'synthetic',
        });
      final mirror = _mirror(
        server,
        () => (silence: {_a, _b}, known: {_a, _b}),
        now: () => now,
      );
      addTearDown(mirror.dispose);
      expect(await mirror.reconcile(), 1);
      expect(mirror.failures, 1);
      expect(mirror.backoffUntil, now.add(const Duration(seconds: 30)));
      // During the backoff no request goes out.
      expect(await mirror.reconcile(), 0);
      expect(server.calls, hasLength(1));
      now = now.add(const Duration(seconds: 31));
      expect(await mirror.reconcile(), 1);
      expect(mirror.backoffUntil, now.add(const Duration(minutes: 1)));
      server.failure = MatrixException.fromJson({
        'errcode': 'M_LIMIT_EXCEEDED',
        'error': 'synthetic',
        'retry_after_ms': 600000,
      });
      now = now.add(const Duration(minutes: 2));
      await mirror.reconcile();
      expect(mirror.backoffUntil, now.add(const Duration(minutes: 10)));
      server.failure = null;
      now = now.add(const Duration(minutes: 11));
      expect(await mirror.reconcile(), 2);
      expect(mirror.failures, 0);
      expect(mirror.backoffUntil, isNull);
    });

    test('a pass sends a bounded number of requests', () async {
      final server = _FakeServer(_defaults());
      final rooms = {for (var i = 0; i < 7; i++) '!r$i:example.invalid'};
      final mirror = _mirror(
        server,
        () => (silence: rooms, known: rooms),
        maxStepsPerPass: 3,
      );
      addTearDown(mirror.dispose);
      expect(await mirror.reconcile(), 3);
      expect(await mirror.reconcile(), 3);
      expect(await mirror.reconcile(), 1);
      expect(await mirror.reconcile(), 0);
    });

    test('a rule already deleted elsewhere counts as removed', () async {
      final server = _FakeServer(_defaults(override: [_ownRule(_a)]))
        ..failure = MatrixException.fromJson({
          'errcode': 'M_NOT_FOUND',
          'error': 'synthetic',
        });
      final mirror = _mirror(server, () => (silence: {}, known: {_a}));
      addTearDown(mirror.dispose);
      expect(await mirror.reconcile(), 1);
      expect(mirror.failures, 0);
    });
  });

  group('what is silenced', () {
    ConversationMetadata meta({
      bool muted = false,
      DateTime? until,
      PersonalNotificationMode? mode,
    }) => ConversationMetadata(
      entityId: 'fixture',
      muted: muted,
      mutedUntil: until,
      notificationMode: mode,
    );
    final now = DateTime.utc(2026, 10, 24, 12);

    test('ignored, "Muted" mode and mute with no end; never a timed mute', () {
      bool wanted({
        bool ignored = false,
        ConversationMetadata? entity,
        ConversationMetadata? source,
      }) => chatLoomSilenceWanted(
        ignored: ignored,
        entity: entity ?? meta(),
        source: source ?? meta(),
        now: now,
      );
      expect(wanted(), isFalse);
      expect(wanted(ignored: true), isTrue);
      expect(
        wanted(entity: meta(mode: PersonalNotificationMode.muted)),
        isTrue,
      );
      expect(
        wanted(source: meta(mode: PersonalNotificationMode.muted)),
        isTrue,
      );
      expect(
        wanted(entity: meta(mode: PersonalNotificationMode.mentionsOnly)),
        isFalse,
      );
      expect(wanted(entity: meta(muted: true)), isTrue);
      expect(wanted(source: meta(muted: true)), isTrue);
      expect(
        wanted(
          entity: meta(muted: true, until: now.add(const Duration(hours: 8))),
        ),
        isFalse,
      );
    });

    test('a merged person applies to each source room', () {
      final client = ConversationClient();
      final whatsapp = ConversationRoom(client, _a);
      final telegram = ConversationRoom(client, _b, network: 'telegram');
      final other = ConversationRoom(client, _c);
      final personal = ConversationPersonal(client);
      addTearDown(personal.dispose);
      final person = PersonGroup(
        id: 'fictional-person',
        name: 'Fictional person',
        members: [personal.ref(whatsapp), personal.ref(telegram)],
        defaultRoomId: whatsapp.id,
      );
      personal.values['person:${person.id}'] = person
          .toJson()
          .cast<String, dynamic>();
      personal.values['org:person:${person.id}'] = ConversationMetadata(
        entityId: 'person:${person.id}',
        muted: true,
      ).toJson();
      var target = chatLoomPushRuleTarget(personal);
      expect(target.silence, {_a, _b});
      expect(target.known, {_a, _b, _c});

      // A timed mute stays local.
      personal.values['org:person:${person.id}'] = ConversationMetadata(
        entityId: 'person:${person.id}',
        muted: true,
        mutedUntil: DateTime.now().add(const Duration(hours: 1)),
      ).toJson();
      expect(chatLoomPushRuleTarget(personal).silence, isEmpty);

      // An ignored single chat.
      personal.values['org:$_c'] = ConversationMetadata(
        entityId: _c,
        ignored: true,
      ).toJson();
      target = chatLoomPushRuleTarget(personal);
      expect(target.silence, {_c});
      expect(other.id, _c);
    });
  });

  group('existing push checks', () {
    test('ChatLoom\'s rules are not the account\'s: verdict and summary', () {
      final client = ConversationClient();
      final room = ConversationRoom(client, _a);
      client.accountData['m.push_rules'] = BasicEvent(
        type: 'm.push_rules',
        content: {
          'global': _defaults(override: [_ownRule(_a)]),
        },
      );
      final event = Event(
        type: EventTypes.Message,
        content: {'msgtype': MessageTypes.Text, 'body': 'synthetic'},
        senderId: '@anna:example.invalid',
        eventId: r'$synthetic',
        originServerTs: DateTime.utc(2026, 10, 24),
        room: room,
      );
      // The local mute decides this chat, not a "push rules" veto.
      expect(personalPushRuleVerdict(client, event), PushRuleVerdict.notify);
      final summary = AccountPushRulesSummary.of(client);
      expect(summary.loaded, isTrue);
      expect(summary.groups, AccountRuleState.notify);
      expect(summary.unknownConditions, isFalse);
      expect(summary.chatLoomMutedChats, 1);
      expect(chatLoomSilencedRooms(client), {_a});
    });

    test('a silenced chat with new messages stays unread without a count', () {
      final client = ConversationClient();
      final room = ConversationRoom(client, _a);
      room.lastEvent = room.message(r'$m1', 'synthetic');
      expect(room.notificationCount, 0);
      expect(personalRoomUnread(room), isFalse);
      client.accountData['m.push_rules'] = BasicEvent(
        type: 'm.push_rules',
        content: {
          'global': _defaults(override: [_ownRule(_a)]),
        },
      );
      expect(personalRoomUnread(room), room.hasNewMessages);
      expect(room.hasNewMessages, isTrue);
    });
  });
}

Client _clientWith(Map<String, Object?> global) {
  final client = ConversationClient();
  client.accountData['m.push_rules'] = BasicEvent(
    type: 'm.push_rules',
    content: {'global': global},
  );
  return client;
}
