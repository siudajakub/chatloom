// SPDX-License-Identifier: AGPL-3.0-or-later
import 'package:chatloom/personal/bridge_contact_search.dart' show SearchHandle;
import 'package:chatloom/personal/ui/contact_sheet.dart'
    show ContactIdentifierKind, contactIdentifiers, isBridgeBotMember;
import 'package:matrix/matrix.dart';

/// Network usernames and phone numbers of the people of one-to-one chats,
/// for the search (Telegram and Instagram find a chat by `@username`).
///
/// Where they come from: bridgev2 puts the network's identifiers of a ghost
/// into its profile (`com.beeper.bridge.identifiers`, e.g.
/// `instagram:<name>`, `telegram:<name>`, `tel:+…`), which Beeper copies
/// into the ghost's member event in every room. Only the member state on
/// this device is read; nothing is fetched while typing.
///
/// Privacy: only the other person of a one-to-one chat is read. Members of
/// groups are never indexed, so a group is not found by a member's
/// username and a group member's username never shows up in the results.
class ChatHandleIndex {
  final _cache = <String, _Entry>{};

  /// How many rooms had to be read again (for tests).
  int computations = 0;

  /// The handles of the other person of [room] (none for groups, bridge
  /// bots and chats without a known person). [network] names the network
  /// (the row's label); it is asked only when the member state changed.
  /// Cached per room until the person's member state changes.
  List<SearchHandle> handlesOf(
    Room room, {
    required String Function(Room room) network,
  }) {
    final peer = directPeerOf(room);
    if (peer == null) {
      _cache.remove(room.id);
      return const [];
    }
    final member = room.getState(EventTypes.RoomMember, peer);
    final cached = _cache[room.id];
    if (cached != null &&
        cached.peer == peer &&
        identical(cached.member, member)) {
      return cached.handles;
    }
    computations++;
    final List<SearchHandle> handles;
    if (member == null || isBridgeBotMember(room, peer)) {
      handles = const [];
    } else {
      final label = network(room);
      handles = List.unmodifiable([
        for (final identifier in contactIdentifiers(room, peer))
          SearchHandle(
            display: identifier.value,
            network: label,
            phone: identifier.kind == ContactIdentifierKind.phone,
          ),
      ]);
    }
    _cache[room.id] = _Entry(peer, member, handles);
    return handles;
  }

  /// Reads from this device's store the member state of the other person
  /// of every one-to-one chat in [rooms] that is not in memory yet (the SDK
  /// loads members lazily). Never asks the server. True when any was
  /// found.
  static Future<bool> loadMissingPeers(
    Iterable<Room> rooms, {
    int batch = 8,
  }) async {
    final missing = [
      for (final room in rooms)
        if (directPeerOf(room) case final peer?
            when room.getState(EventTypes.RoomMember, peer) == null)
          (room, peer),
    ];
    var found = false;
    for (var i = 0; i < missing.length; i += batch) {
      final loaded = await Future.wait(
        missing.skip(i).take(batch).map((entry) async {
          final (room, peer) = entry;
          try {
            // The store only, as the SDK's timeline does for its senders.
            final user = await room.client.database.getUser(peer, room);
            if (user == null ||
                room.getState(EventTypes.RoomMember, peer) != null) {
              return false;
            }
            room.setState(user);
            return true;
          } catch (_) {
            // No store (tests) or a closed one: the chat is found by name.
            return false;
          }
        }),
      );
      if (loaded.contains(true)) found = true;
    }
    return found;
  }
}

/// The other person of a joined one-to-one [room], or null.
String? directPeerOf(Room room) {
  if (room.membership != Membership.join || !room.isDirectChatForDisplay) {
    return null;
  }
  final peer = room.directChatMatrixIDForDisplay;
  if (peer == null || peer == room.client.userID) return null;
  return peer;
}

class _Entry {
  const _Entry(this.peer, this.member, this.handles);
  final String peer;
  final Object? member;
  final List<SearchHandle> handles;
}
