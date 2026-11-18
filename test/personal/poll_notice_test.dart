// SPDX-License-Identifier: AGPL-3.0-or-later
// Poll votes never notify; the account rule that enforces it is idempotent.
// Offline fixtures only.
import 'package:chatloom/personal/poll_notice.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:matrix/matrix.dart';

PushRuleSet _rules(List<Map<String, Object?>> override) =>
    PushRuleSet.fromJson({'override': override});

Map<String, Object?> _spec({bool enabled = true, List<Object?>? actions}) => {
  'rule_id': specPollResponseRuleId,
  'default': true,
  'enabled': enabled,
  'actions': actions ?? const [],
  'conditions': [
    {
      'kind': 'event_match',
      'key': 'type',
      'pattern': 'org.matrix.msc3381.poll.response',
    },
  ],
};

Map<String, Object?> _own({
  bool enabled = true,
  String pattern = '*poll.response',
}) => {
  'rule_id': chatLoomPollRuleId,
  'default': false,
  'enabled': enabled,
  'actions': const [],
  'conditions': [
    {'kind': 'event_match', 'key': 'type', 'pattern': pattern},
  ],
};

void main() {
  test('votes and closings are bookkeeping, messages are not', () {
    for (final t in [
      'org.matrix.msc3381.poll.response',
      'm.poll.response',
      'org.matrix.msc3381.poll.end',
      'm.poll.end',
    ]) {
      expect(isPollBookkeeping(t), isTrue, reason: t);
    }
    for (final t in ['m.room.message', 'org.matrix.msc3381.poll.start']) {
      expect(isPollBookkeeping(t), isFalse, reason: t);
    }
  });

  test('plan: nothing when a silent rule is active', () {
    expect(planPollRule(_rules([_spec()])), PollRuleOp.none);
    expect(planPollRule(_rules([_own()])), PollRuleOp.none);
  });

  test('plan: spec rule disabled is enabled, not duplicated', () {
    expect(planPollRule(_rules([_spec(enabled: false)])), PollRuleOp.enable);
  });

  test('plan: no rule (or a wrong own rule) writes ours', () {
    expect(planPollRule(_rules([])), PollRuleOp.put);
    expect(planPollRule(_rules([_own(enabled: false)])), PollRuleOp.put);
    expect(planPollRule(_rules([_own(pattern: 'x')])), PollRuleOp.put);
  });

  test('plan: a spec rule the account set to notify is left to us', () {
    expect(
      planPollRule(
        _rules([
          _spec(actions: ['notify']),
        ]),
      ),
      PollRuleOp.put,
    );
  });
}
