// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:matrix/matrix.dart';

/// Poll votes (MSC3381 unstable and stable names). Never worth an alert.
const pollResponseTypes = {
  'org.matrix.msc3381.poll.response',
  'm.poll.response',
};

/// Poll closings. The SDK has no text for them ("Unknown event").
const pollEndTypes = {'org.matrix.msc3381.poll.end', 'm.poll.end'};

/// Whether [type] is a vote or a poll closing: bookkeeping that never shows
/// a notification (the poll itself renders in the timeline).
bool isPollBookkeeping(String type) =>
    pollResponseTypes.contains(type) || pollEndTypes.contains(type);

/// Id of the account push rule that keeps votes off the phone server-side.
const chatLoomPollRuleId = 'pl.personal.chat.mute_poll_votes';

/// Spec default rule that already does the same (actions none).
const specPollResponseRuleId = '.m.rule.poll_response';

/// `*` matches both [pollResponseTypes] (event_match globs the whole value).
const _pollRulePattern = '*poll.response';

enum PollRuleOp { none, put, enable }

/// What brings [rules] to "votes never push". Nothing when the spec rule or
/// ours is enabled and silent; otherwise the spec rule is enabled when it
/// exists disabled, else our own rule is written. A rule that notifies is
/// never edited (it is the account's own choice), ours is rewritten.
PollRuleOp planPollRule(PushRuleSet rules) {
  bool silent(PushRule r) =>
      r.enabled && !EvaluatedPushRuleAction.fromActions(r.actions).notify;
  final override = rules.override ?? const <PushRule>[];
  PushRule? own, spec;
  for (final r in override) {
    if (r.ruleId == chatLoomPollRuleId) own = r;
    if (r.ruleId == specPollResponseRuleId) spec = r;
  }
  if (spec != null && silent(spec)) return PollRuleOp.none;
  if (own != null && silent(own) && _ownShape(own)) return PollRuleOp.none;
  if (spec != null && !spec.enabled && spec.actions.isEmpty) {
    return PollRuleOp.enable;
  }
  return PollRuleOp.put;
}

bool _ownShape(PushRule r) {
  final c = r.conditions ?? const <PushCondition>[];
  return c.length == 1 &&
      c.single.kind == 'event_match' &&
      c.single.key == 'type' &&
      c.single.pattern == _pollRulePattern;
}

/// Applies [planPollRule]; idempotent (a second run after sync does nothing).
Future<PollRuleOp> ensurePollRule(Client client) async {
  final rules = client.globalPushRules;
  if (rules == null) return PollRuleOp.none;
  final op = planPollRule(rules);
  switch (op) {
    case PollRuleOp.none:
      break;
    case PollRuleOp.enable:
      await client.setPushRuleEnabled(
        PushRuleKind.override,
        specPollResponseRuleId,
        true,
      );
    case PollRuleOp.put:
      await client.setPushRule(
        PushRuleKind.override,
        chatLoomPollRuleId,
        const [],
        conditions: [
          PushCondition(
            kind: 'event_match',
            key: 'type',
            pattern: _pollRulePattern,
          ),
        ],
      );
  }
  return op;
}
