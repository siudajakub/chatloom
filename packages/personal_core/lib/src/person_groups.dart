// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'contracts.dart';

/// What the device currently knows about one source chat of a person.
enum PersonMemberState {
  /// Joined and a confirmed one-to-one chat: it can be shown and sent to.
  active,

  /// Missing, left, deleted or only invited: kept in the person, but not
  /// shown, counted or sent to until it is joined again.
  inactive,

  /// Joined but not a one-to-one chat (it became a network group, or its
  /// bridge declares another kind). Such a person is never shown merged, so
  /// its composer can never send into a group.
  unsafe,
}

/// The state of one member within its person after overlaps are resolved.
enum PersonSourceStatus { active, inactive, elsewhere, unsafe }

/// Saved persons resolved against the chats that exist right now.
///
/// A person stays merged while at least one of its chats is active, so one
/// left, deleted or recreated portal never splits it up. A chat listed by
/// two persons (two devices merged before the worker confirmed, or an
/// absorbed person whose removal failed) belongs to exactly one of them,
/// chosen the same way on every device: the person with more chats, then
/// the smaller id. The other person keeps its remaining chats.
class PersonGroupResolution {
  /// Persons that are shown merged, in saved order.
  final List<PersonGroup> valid;

  /// Persons dropped because a joined chat is not a one-to-one chat.
  final List<PersonGroup> unsafe;

  /// Persons whose active chats all belong to other persons (for example
  /// an absorbed person whose removal is still pending).
  final List<PersonGroup> covered;

  final Map<String, PersonGroup> _owners;
  final Map<String, PersonMemberState> _states;

  PersonGroupResolution._(
    this.valid,
    this.unsafe,
    this.covered,
    this._owners,
    this._states,
  );

  /// The person that shows the chat [roomId], if any.
  PersonGroup? ownerOf(String roomId) => _owners[roomId];

  /// Every chat with its owning person.
  Map<String, PersonGroup> get owners => Map.unmodifiable(_owners);

  PersonSourceStatus statusOf(PersonGroup group, ConversationRef member) =>
      switch (_states[member.key]) {
        PersonMemberState.active =>
          _owners[member.roomId]?.id == group.id
              ? PersonSourceStatus.active
              : PersonSourceStatus.elsewhere,
        PersonMemberState.unsafe => PersonSourceStatus.unsafe,
        _ => PersonSourceStatus.inactive,
      };

  /// Other persons that show chats [group] lists as well.
  List<PersonGroup> overlapsOf(PersonGroup group) {
    final result = <PersonGroup>[];
    for (final member in group.members) {
      final owner = _owners[member.roomId];
      if (owner != null &&
          owner.id != group.id &&
          !result.any((known) => known.id == owner.id)) {
        result.add(owner);
      }
    }
    return result;
  }
}

/// Resolves [groups] with the current [stateOf] of each member (see
/// [PersonGroupResolution]). Pure and deterministic.
PersonGroupResolution resolvePersonGroups(
  Iterable<PersonGroup> groups,
  PersonMemberState Function(ConversationRef member) stateOf,
) {
  final all = groups.toList(growable: false);
  final states = <String, PersonMemberState>{};
  for (final group in all) {
    for (final member in group.members) {
      states.putIfAbsent(member.key, () => stateOf(member));
    }
  }
  final unsafe = <PersonGroup>[];
  final candidates = <PersonGroup>[];
  for (final group in all) {
    if (group.members.any(
      (member) => states[member.key] == PersonMemberState.unsafe,
    )) {
      unsafe.add(group);
    } else {
      candidates.add(group);
    }
  }
  final order = [...candidates]
    ..sort((a, b) {
      final bySize = b.members.length.compareTo(a.members.length);
      return bySize != 0 ? bySize : a.id.compareTo(b.id);
    });
  final owners = <String, PersonGroup>{};
  for (final group in order) {
    for (final member in group.members) {
      if (states[member.key] == PersonMemberState.active) {
        owners.putIfAbsent(member.roomId, () => group);
      }
    }
  }
  final valid = <PersonGroup>[];
  final covered = <PersonGroup>[];
  for (final group in candidates) {
    final owns = group.members.any(
      (member) => owners[member.roomId]?.id == group.id,
    );
    if (owns) {
      valid.add(group);
    } else if (group.members.any(
      (member) => states[member.key] == PersonMemberState.active,
    )) {
      covered.add(group);
    }
  }
  return PersonGroupResolution._(
    List.unmodifiable(valid),
    List.unmodifiable(unsafe),
    List.unmodifiable(covered),
    owners,
    states,
  );
}

/// How a person's next message picks its network.
enum PersonRouting {
  /// Where they last wrote (own messages count for 30 minutes), otherwise
  /// the default chat.
  automatic,

  /// Always the default chat, unless a message is a reply or the network
  /// is chosen for one message.
  fixed,
}

/// Private store key of a person's preferences. Kept apart from the
/// `person:<id>` group itself: builds that predate these preferences
/// rewrite that JSON without fields they do not know.
String personPreferencesKey(String groupId) => 'person-prefs:$groupId';

/// Private preferences of a merged person (synced, end-to-end encrypted).
class PersonPreferences {
  final PersonRouting routing;

  /// The chat whose current network name is the person's name (when no
  /// private nickname is set).
  final String? nameRoomId;

  const PersonPreferences({
    this.routing = PersonRouting.automatic,
    this.nameRoomId,
  });

  PersonPreferences copyWith({
    PersonRouting? routing,
    String? Function()? nameRoomId,
  }) => PersonPreferences(
    routing: routing ?? this.routing,
    nameRoomId: nameRoomId == null ? this.nameRoomId : nameRoomId(),
  );

  /// Unknown fields of [previous] (written by newer builds) are kept.
  Map<String, dynamic> toJson([Map<String, dynamic>? previous]) => {
    ...?previous,
    'routing': routing.name,
    'nameRoomId': nameRoomId,
  };

  factory PersonPreferences.fromJson(Map<String, dynamic>? json) {
    final routing = json?['routing'];
    final name = json?['nameRoomId'];
    return PersonPreferences(
      routing: routing == PersonRouting.fixed.name
          ? PersonRouting.fixed
          : PersonRouting.automatic,
      nameRoomId: name is String && name.isNotEmpty ? name : null,
    );
  }

  @override
  String toString() => 'PersonPreferences(${routing.name}, redacted)';
}

/// One chat or merged person that a merge suggestion may pair.
class MergeSuggestionCandidate {
  /// Inbox entity: a room id or `person:<group id>`.
  final String entityId;
  final Set<String> networks;

  /// Folded names (lower case, accents removed) of the entity and each of
  /// its chats.
  final Set<String> names;

  /// Phone numbers the bridges expose for the other person, digits only.
  final Set<String> phones;
  final DateTime? lastActivity;

  MergeSuggestionCandidate({
    required this.entityId,
    required Iterable<String> networks,
    Iterable<String> names = const [],
    Iterable<String> phones = const [],
    this.lastActivity,
  }) : networks = Set.unmodifiable(networks),
       names = Set.unmodifiable(names),
       phones = Set.unmodifiable(phones);

  @override
  String toString() => 'MergeSuggestionCandidate(redacted)';
}

enum MergeSuggestionReason { name, phone }

class MergeSuggestion {
  final MergeSuggestionCandidate first;
  final MergeSuggestionCandidate second;
  final MergeSuggestionReason reason;
  const MergeSuggestion(this.first, this.second, this.reason);

  /// Stable private key of this pair, used to remember a dismissal.
  String get dismissKey => mergeSuggestionDismissKey(
    first.entityId,
    second.entityId,
  );

  @override
  String toString() => 'MergeSuggestion(${reason.name}, redacted)';
}

/// Private store key that remembers a dismissed suggestion of [a] and [b]
/// (order does not matter). An opaque digest, no identifiers in the key.
String mergeSuggestionDismissKey(String a, String b) {
  final bytes = utf8.encode(([a, b]..sort()).join('\u0000'));
  // Two 32-bit FNV-1a passes (forwards and backwards): stable across
  // platforms without a hashing dependency. A collision only hides one
  // suggestion.
  int fnv(Iterable<int> units) {
    var hash = 0x811c9dc5;
    for (final unit in units) {
      hash ^= unit;
      // hash * 16777619 (2^24 + 403) in 32 bits.
      hash = (((hash << 24) & 0xFFFFFFFF) + hash * 403) & 0xFFFFFFFF;
    }
    return hash;
  }

  String hex(int value) => value.toRadixString(16).padLeft(8, '0');
  return 'merge-dismissed:${hex(fnv(bytes))}${hex(fnv(bytes.reversed))}';
}

/// The comparable form of a name: words only, single spaces. Names shorter
/// than three letters never match.
String? mergeNameKey(String folded) {
  final words = folded
      .split(RegExp(r'[^\p{L}\p{N}]+', unicode: true))
      .where((word) => word.isNotEmpty)
      .toList();
  final key = words.join(' ');
  return key.replaceAll(' ', '').length < 3 ? null : key;
}

/// First and last word of a name with at least two words.
String? _firstLast(String key) {
  final words = key.split(' ');
  return words.length < 2 ? null : '${words.first} ${words.last}';
}

/// Pairs of [candidates] on different networks that look like one person:
/// the same name (whole name, or first and last word) or the same phone
/// number. Local only and never applied automatically; pairs whose
/// [mergeSuggestionDismissKey] is in [dismissed] are left out. Newest
/// activity first, at most [limit].
List<MergeSuggestion> mergeSuggestions(
  Iterable<MergeSuggestionCandidate> candidates, {
  Set<String> dismissed = const {},
  int limit = 20,
}) {
  final list = candidates.toList(growable: false);
  final buckets = <String, List<int>>{};
  void add(String key, int index) {
    final bucket = buckets.putIfAbsent(key, () => []);
    if (!bucket.contains(index)) bucket.add(index);
  }

  for (var i = 0; i < list.length; i++) {
    for (final name in list[i].names) {
      final key = mergeNameKey(name);
      if (key == null) continue;
      add('n:$key', i);
      final short = _firstLast(key);
      if (short != null) add('n:$short', i);
    }
    for (final phone in list[i].phones) {
      if (phone.length >= 7) add('p:$phone', i);
    }
  }
  final seen = <String>{};
  final result = <MergeSuggestion>[];
  for (final entry in buckets.entries) {
    final bucket = entry.value;
    // A very common name is not a signal.
    if (bucket.length > 6) continue;
    final reason = entry.key.startsWith('p:')
        ? MergeSuggestionReason.phone
        : MergeSuggestionReason.name;
    for (var a = 0; a < bucket.length; a++) {
      for (var b = a + 1; b < bucket.length; b++) {
        final first = list[bucket[a]], second = list[bucket[b]];
        if (first.entityId == second.entityId ||
            first.networks.any(second.networks.contains)) {
          continue;
        }
        final key = mergeSuggestionDismissKey(first.entityId, second.entityId);
        if (dismissed.contains(key)) continue;
        if (!seen.add(key)) {
          // A phone match is the stronger reason for the same pair.
          if (reason == MergeSuggestionReason.phone) {
            final index = result.indexWhere((s) => s.dismissKey == key);
            if (index >= 0) {
              result[index] = MergeSuggestion(first, second, reason);
            }
          }
          continue;
        }
        result.add(MergeSuggestion(first, second, reason));
      }
    }
  }
  DateTime? latest(MergeSuggestion s) {
    final a = s.first.lastActivity, b = s.second.lastActivity;
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  result.sort((x, y) {
    final a = latest(x), b = latest(y);
    if (a == null || b == null) {
      return a == b ? x.dismissKey.compareTo(y.dismissKey) : (a == null ? 1 : -1);
    }
    final byTime = b.compareTo(a);
    return byTime != 0 ? byTime : x.dismissKey.compareTo(y.dismissKey);
  });
  return result.length > limit ? result.sublist(0, limit) : result;
}
