// SPDX-License-Identifier: AGPL-3.0-or-later

/// The phone's second look at the account's push rules, made the way the
/// homeserver makes the first one.
///
/// A push only arrives because the homeserver's rules said "notify". The phone
/// evaluates the rules again because an encrypted message can only be matched
/// against its text after decryption (the spec's intended use). Two things made
/// that second look silence messages the server had rightly pushed:
///
/// * The SDK evaluator counts the member events held in memory. In the push
///   isolate a room comes from the database with lazily loaded members, so a
///   two-person chat often counted one member and `.m.rule.room_one_to_one`
///   ("== 2") never matched on the phone, although it did on the server.
///   Here member counts come from the room summary the server sent.
/// * Rules with a condition kind the SDK does not know are skipped, and a
///   push rule set that was never synced evaluates to "no rule matched". In
///   both cases the phone cannot evaluate faithfully, so it defers to the
///   server, which already decided to notify. Do Not Disturb (the master
///   rule) is always honoured.
library;

import 'package:matrix/matrix.dart';

enum PushRuleVerdict {
  /// The account's rules let this event notify.
  notify,

  /// A rule the phone fully understands silences this event.
  silenced,

  /// No push rules are known on this device; the server's decision stands.
  notLoaded,

  /// The rules use a condition the phone cannot evaluate; the server's
  /// decision stands.
  unevaluable;

  /// Whether a notification may be shown.
  bool get allows => this != PushRuleVerdict.silenced;
}

const _knownConditions = {
  'event_match',
  'event_property_is',
  'event_property_contains',
  'contains_display_name',
  'room_member_count',
  'sender_notification_permission',
};

const masterRuleId = '.m.rule.master';

bool _masterOn(PushRuleSet rules) => (rules.override ?? const <PushRule>[]).any(
  (rule) => rule.ruleId == masterRuleId && rule.enabled,
);

bool _hasUnknownConditions(PushRuleSet rules) =>
    [...?rules.override, ...?rules.underride].any(
      (rule) =>
          rule.enabled &&
          (rule.conditions ?? const <PushCondition>[]).any(
            (condition) => !_knownConditions.contains(condition.kind),
          ),
    );

/// Parses a `room_member_count` `is` value: an integer optionally prefixed by
/// `==`, `<`, `>`, `<=` or `>=`. Null when malformed.
bool? memberCountMatches(String? spec, int count) {
  if (spec == null) return null;
  final match = RegExp(r'^(==|<=|>=|<|>)?(\d+)$').firstMatch(spec.trim());
  if (match == null) return null;
  final value = int.parse(match.group(2)!);
  return switch (match.group(1)) {
    '<' => count < value,
    '>' => count > value,
    '<=' => count <= value,
    '>=' => count >= value,
    _ => count == value,
  };
}

/// [rules] with every `room_member_count` condition decided for [count]: a
/// rule whose count holds keeps its other conditions, one whose count fails
/// (or is malformed) is disabled. The SDK evaluator then never counts members.
PushRuleSet resolveMemberCount(PushRuleSet rules, int count) {
  List<PushRule>? resolve(List<PushRule>? list) => list?.map((rule) {
    final conditions = rule.conditions;
    if (conditions == null ||
        !conditions.any((c) => c.kind == 'room_member_count')) {
      return rule;
    }
    var holds = true;
    final rest = <PushCondition>[];
    for (final condition in conditions) {
      if (condition.kind != 'room_member_count') {
        rest.add(condition);
      } else if (memberCountMatches(condition.is$, count) != true) {
        holds = false;
      }
    }
    return PushRule(
      actions: rule.actions,
      conditions: rest,
      default$: rule.default$,
      enabled: rule.enabled && holds,
      pattern: rule.pattern,
      ruleId: rule.ruleId,
    );
  }).toList();

  return PushRuleSet(
    content: rules.content,
    override: resolve(rules.override),
    room: rules.room,
    sender: rules.sender,
    underride: resolve(rules.underride),
  );
}

/// The joined member count the homeserver uses for `room_member_count`: the
/// sync summary, or the loaded members when the summary is missing.
int roomMemberCount(Room room) {
  final summary = room.summary.mJoinedMemberCount;
  if (summary != null && summary > 0) return summary;
  return room.getParticipants(const [Membership.join]).length;
}

/// Evaluates the account's global push rules for [event] (see the library
/// comment for why this is not `client.pushruleEvaluator`).
PushRuleVerdict personalPushRuleVerdict(Client client, Event event) {
  final PushRuleSet? rules;
  try {
    rules = client.globalPushRules;
  } catch (_) {
    return PushRuleVerdict.notLoaded;
  }
  if (rules == null ||
      [
        ...?rules.override,
        ...?rules.underride,
        ...?rules.content,
        ...?rules.room,
        ...?rules.sender,
      ].isEmpty) {
    return PushRuleVerdict.notLoaded;
  }
  if (_masterOn(rules)) return PushRuleVerdict.silenced;
  final bool notify;
  try {
    notify = PushruleEvaluator.fromRuleset(
      resolveMemberCount(rules, roomMemberCount(event.room)),
    ).match(event).notify;
  } catch (_) {
    return PushRuleVerdict.unevaluable;
  }
  if (notify) return PushRuleVerdict.notify;
  return _hasUnknownConditions(rules)
      ? PushRuleVerdict.unevaluable
      : PushRuleVerdict.silenced;
}

/// What one default rule of the account does, for diagnostics.
enum AccountRuleState { notify, silent, off, missing }

/// Content-free summary of the account's default notification rules: only
/// spec rule ids and their effect, never room or sender rules.
class AccountPushRulesSummary {
  final bool loaded;
  final bool doNotDisturb;
  final AccountRuleState oneToOne;
  final AccountRuleState groups;
  final AccountRuleState encryptedOneToOne;
  final AccountRuleState encryptedGroups;
  final bool unknownConditions;
  const AccountPushRulesSummary({
    required this.loaded,
    this.doNotDisturb = false,
    this.oneToOne = AccountRuleState.missing,
    this.groups = AccountRuleState.missing,
    this.encryptedOneToOne = AccountRuleState.missing,
    this.encryptedGroups = AccountRuleState.missing,
    this.unknownConditions = false,
  });

  static const notLoaded = AccountPushRulesSummary(loaded: false);

  factory AccountPushRulesSummary.of(Client client) {
    final PushRuleSet? rules;
    try {
      rules = client.globalPushRules;
    } catch (_) {
      return notLoaded;
    }
    if (rules == null) return notLoaded;
    AccountRuleState state(String id) {
      final rule = [
        ...?rules!.override,
        ...?rules.underride,
      ].where((rule) => rule.ruleId == id).firstOrNull;
      if (rule == null) return AccountRuleState.missing;
      if (!rule.enabled) return AccountRuleState.off;
      return EvaluatedPushRuleAction.fromActions(rule.actions).notify
          ? AccountRuleState.notify
          : AccountRuleState.silent;
    }

    return AccountPushRulesSummary(
      loaded: true,
      doNotDisturb: _masterOn(rules),
      oneToOne: state('.m.rule.room_one_to_one'),
      groups: state('.m.rule.message'),
      encryptedOneToOne: state('.m.rule.encrypted_room_one_to_one'),
      encryptedGroups: state('.m.rule.encrypted'),
      unknownConditions: _hasUnknownConditions(rules),
    );
  }

  /// Whether ordinary messages in group chats stay silent (rule off or
  /// without "notify"). Direct chats follow [oneToOne].
  bool get groupsSilent =>
      groups == AccountRuleState.off || groups == AccountRuleState.silent;
}

String accountRuleStateLabel(AccountRuleState state) => switch (state) {
  AccountRuleState.notify => 'Notify',
  AccountRuleState.silent => 'Silent',
  AccountRuleState.off => 'Off (silent)',
  AccountRuleState.missing => 'Not set',
};
