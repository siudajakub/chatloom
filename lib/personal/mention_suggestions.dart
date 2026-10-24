// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:chatloom/personal/bridge_contact_search.dart' show searchFold;
import 'package:chatloom/personal/bridged_room.dart';
import 'package:matrix/matrix.dart';

/// Characters of a mention or room query: letters (any script, Polish
/// diacritics included), combining marks, digits, `_`, `.` and `-`. Dart's
/// `\w` is ASCII only, so `@Ł` never opened suggestions before (FX-08).
const _queryChars = r'[\p{L}\p{M}\p{N}_.\-]';

/// `@query` right before the cursor; an empty query lists the people of the
/// chat (Telegram shows them as soon as `@` is typed).
final mentionQueryPattern = RegExp(
  '(?:\\s|^)@($_queryChars*)\$',
  unicode: true,
);

/// The `@query` token to replace when a person is picked.
final mentionTokenPattern = RegExp('(\\s|^)(@$_queryChars*)\$', unicode: true);

/// `#query` right before the cursor (at least one character).
final roomQueryPattern = RegExp('(?:\\s|^)#($_queryChars+)\$', unicode: true);

/// The `#query` token to replace when a room is picked.
final roomTokenPattern = RegExp('(\\s|^)(#$_queryChars+)\$', unicode: true);

final _wordBreak = RegExp(r'[\s\-_.,;:()\[\]/+@&|·"!?]+');

/// How well [query] matches [names], Telegram style: case and diacritics
/// are ignored ("lukasz" and "Łuk" find "Łukasz"), and a query must start a
/// word of a name ("kow" finds "Jan Kowalski", "alski" does not).
/// 0 when a whole name starts with it, 1 when a later word does, null when
/// nothing matches. An empty query matches every name with rank 0.
int? mentionRank(String query, Iterable<String?> names) {
  final folded = searchFold(query.trim());
  int? best;
  for (final name in names) {
    if (name == null || name.trim().isEmpty) continue;
    final value = searchFold(name.trim());
    if (folded.isEmpty || value.startsWith(folded)) return 0;
    if (value
        .split(_wordBreak)
        .any((w) => w.isNotEmpty && w.startsWith(folded))) {
      best = 1;
    }
  }
  return best;
}

/// Bridge bots of [room] (the `bridgebot` of its bridge info): never people
/// to mention.
Set<String> bridgeBotIds(Room room) => {
  for (final type in bridgeInfoStateTypes)
    for (final state
        in room.states[type]?.values ?? const <StrippedStateEvent>[])
      if (state.content['bridgebot'] case final String bot) bot,
};

/// One person [mentionSuggestions] offers.
typedef MentionCandidate = ({User user, int rank});

/// The people of [room] matching [query], best first: joined and invited
/// members except the own account and bridge bots. Names are the room
/// display name and, for the other person of a direct chat, [privateName]
/// (the private nickname or merged person name the inbox shows). A bridged
/// chat never matches on Matrix localparts (puppet IDs carry phone numbers
/// and network IDs); a native Matrix room also matches on them.
List<MentionCandidate> mentionSuggestions(
  Room room,
  String query, {
  String? privateName,
  int limit = 30,
}) {
  if (limit <= 0) return const [];
  _loadMembersOnce(room);
  final own = room.client.userID;
  final bots = bridgeBotIds(room);
  final bridged = isBridgedRoom(room);
  final partner = room.directChatMatrixID;
  final found = <MentionCandidate>[];
  for (final user in room.getParticipants(const [
    Membership.join,
    Membership.invite,
  ])) {
    if (user.id == own || bots.contains(user.id)) continue;
    final rank = mentionRank(query, [
      user.displayName,
      if (user.id == partner) privateName,
      if (!bridged) user.id.localpart,
    ]);
    if (rank != null) found.add((user: user, rank: rank));
  }
  // Stable: rank, then name, so the list does not jump while typing.
  found.sort((a, b) {
    final byRank = a.rank.compareTo(b.rank);
    if (byRank != 0) return byRank;
    return searchFold(
      a.user.calcDisplayname(),
    ).compareTo(searchFold(b.user.calcDisplayname()));
  });
  return found.length > limit ? found.sublist(0, limit) : found;
}

/// Rooms whose members were requested this session (lazy loading leaves
/// a group's member list partial until someone asks).
final _requested = <String>{};

void _loadMembersOnce(Room room) {
  if (room.participantListComplete || !_requested.add(room.id)) return;
  if (_requested.length > 256) _requested.clear();
  // The next keystroke sees the loaded members; a failure only leaves the
  // partial list, as before.
  unawaited(
    room
        .requestParticipants(const [Membership.join, Membership.invite])
        .then<void>((_) {}, onError: (Object _) {}),
  );
}

/// Whether `#` offers rooms in [room]: never in a bridged chat (the
/// network cannot open a Matrix room link) (FX-08).
bool roomSuggestionsAllowed(Room room) => !isBridgedRoom(room);

/// The joined rooms `#query` offers: native Matrix rooms with a canonical
/// alias (so a raw room ID is never inserted), not tombstoned, not bridged,
/// matching the alias or the name on a word start.
List<Room> roomSuggestions(Client client, String query, {int limit = 30}) {
  if (limit <= 0) return const [];
  final found = <(Room, int)>[];
  for (final r in client.rooms) {
    if (r.membership != Membership.join) continue;
    if (r.getState(EventTypes.RoomTombstone) != null) continue;
    if (r.canonicalAlias.isEmpty || isBridgedRoom(r)) continue;
    final aliases = [
      r.canonicalAlias.localpart,
      ...?r
          .getState(EventTypes.RoomCanonicalAlias)
          ?.content
          .tryGetList<String>('alt_aliases')
          ?.map((alias) => alias.localpart),
    ];
    final rank = mentionRank(query, [r.name, ...aliases]);
    if (rank != null) found.add((r, rank));
    if (found.length >= limit) break;
  }
  found.sort((a, b) => a.$2.compareTo(b.$2));
  return [for (final (room, _) in found) room];
}
