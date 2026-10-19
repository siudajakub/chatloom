// SPDX-License-Identifier: AGPL-3.0-or-later

/// Detects bridge ghost users that represent the owner's own remote account
/// (e.g. messages sent from the native Telegram app without double puppeting
/// arrive as `@telegram_<own id>:<bridge server>` with the own Telegram name).
///
/// Pure Dart, no Matrix SDK dependency. Adapters convert loaded room state
/// into [BridgeRoomSnapshot]s; the app adapter is
/// `lib/personal/own_sender.dart` (`OwnSenderResolver.of(client)`), the
/// worker builds snapshots in `worker/lib/src/matrix_transport.dart`.
///
/// Stable API:
/// * [BridgeInfoSnapshot.fromContent] parses one `m.bridge` /
///   `uk.half-shot.bridge` / `com.beeper.bridge` state content together with
///   its provenance (state event sender, whether the bridge bot is joined).
/// * [BridgeRoomSnapshot] is one room: whether the owner joined it, its bridge
///   declarations, the native `m.direct` partner and (for DM-shaped rooms
///   only) joined members.
/// * [OwnRemoteIdentity.resolve] builds the identity; [OwnRemoteIdentity.isOwn]
///   answers "was this sent by the account owner (incl. own ghost)?" for a
///   given room; [OwnRemoteIdentity.isStronglyOwn] answers it only on
///   account/receiver evidence and is the only check that may suppress a
///   notification or a mention.
///
/// Trust: a bridge declaration counts only in a room the owner has joined,
/// when the state event was sent by the declared `bridgebot` itself and that
/// bot is a joined member of the room. Anything else (a room member with state
/// power declaring a bridge, a stale declaration of a bot that left, invites)
/// is ignored, so nobody can mark a real contact's ghost as "own".
///
/// Layers (a display name alone never identifies anybody):
/// 1. Strong: a bridgev2 `channel['fi.mau.receiver']` is the login id of the
///    owner's remote account. Its ghost is `<prefix>_<receiver>` on the
///    bridge bot's server, prefix = protocol id or bot localpart without
///    `bot`. Receivers are collected from all trusted rooms (DM portals carry
///    them, group portals often do not), so the ghost is recognised
///    everywhere.
/// 2. Structural, scoped to the DMs it came from: in a bridged DM whose
///    partner is identified (native `m.direct` and/or a ghost matching
///    `channel.id`, both must agree), exactly one further ghost of that bridge
///    is the owner's own ghost (e.g. a WhatsApp LID ghost). Guards: never a
///    partner anywhere, never the partner's display name, and it needs
///    corroboration — either its display name equals a layer-1 own ghost's
///    name on that server, or it is the extra ghost in at least two different
///    DMs.
/// 3. Tie-break only, scoped to its DM: a DM with an unidentified partner and
///    two ghosts, of which exactly one carries a confirmed own display name.
/// Layers 2 and 3 are weak: they label previews ("You: …") in their rooms but
/// never suppress notifications or mentions.
/// The Matrix account itself (`senderId == accountUserId`) is always own.
library;

const ownIdentityBridgeStateTypes = [
  'm.bridge',
  'uk.half-shot.bridge',
  'com.beeper.bridge',
];

String? _text(Object? value) =>
    value is String && value.trim().isNotEmpty ? value.trim() : null;

/// `@local:server` → (local, server); null for anything else.
(String, String)? splitMatrixId(String id) {
  if (!id.startsWith('@')) return null;
  final colon = id.indexOf(':');
  if (colon <= 1 || colon == id.length - 1) return null;
  return (id.substring(1, colon), id.substring(colon + 1));
}

final _localpartSafe = RegExp(r'^[a-z0-9._=\-/]+$');

/// One bridge declaration of a room.
class BridgeInfoSnapshot {
  final String bridgebot;
  final String? protocolId;

  /// bridgev2 portal receiver = login id of the owner's remote account.
  final String? receiver;

  /// Remote chat id (for DMs usually the partner's remote user id/JID).
  final String? channelId;

  /// `com.beeper.room_type.v2`, else legacy `com.beeper.room_type`.
  final String? roomType;

  /// Sender of the state event carrying this declaration.
  final String? senderId;

  /// Whether [bridgebot] is a joined member of the room (loaded state).
  final bool bridgebotJoined;
  const BridgeInfoSnapshot({
    required this.bridgebot,
    this.protocolId,
    this.receiver,
    this.channelId,
    this.roomType,
    this.senderId,
    this.bridgebotJoined = false,
  });

  /// [senderId] is the state event's sender; [isJoined] answers whether a
  /// user (asked for the declared bridge bot only) is a joined member of the
  /// room. Without both the declaration is parsed but never [trusted].
  static BridgeInfoSnapshot? fromContent(
    Object? content, {
    String? senderId,
    bool Function(String userId)? isJoined,
  }) {
    if (content is! Map) return null;
    final bot = _text(content['bridgebot']);
    if (bot == null || splitMatrixId(bot) == null) return null;
    final protocol = content['protocol'];
    final channel = content['channel'];
    return BridgeInfoSnapshot(
      bridgebot: bot,
      protocolId: protocol is Map ? _text(protocol['id'])?.toLowerCase() : null,
      receiver: channel is Map ? _text(channel['fi.mau.receiver']) : null,
      channelId: channel is Map ? _text(channel['id']) : null,
      roomType:
          _text(content['com.beeper.room_type.v2']) ??
          _text(content['com.beeper.room_type']),
      senderId: senderId,
      bridgebotJoined: isJoined?.call(bot) ?? false,
    );
  }

  /// Sent by the declared bridge bot itself, which is joined to the room.
  bool get trusted => senderId == bridgebot && bridgebotJoined;

  String get server => splitMatrixId(bridgebot)!.$2;

  /// Ghost localpart prefixes of this bridge, e.g. `telegram` for
  /// `@telegrambot` / protocol `telegram`, `whatsapp` for `whatsappgo`.
  Set<String> get ghostPrefixes {
    final result = <String>{};
    void add(String? value) {
      final v = value?.toLowerCase();
      if (v == null || v.isEmpty) return;
      result.add(v);
      if (v.endsWith('go') && v.length > 2) {
        result.add(v.substring(0, v.length - 2));
      }
    }

    add(protocolId);
    final local = splitMatrixId(bridgebot)!.$1.toLowerCase();
    if (local.endsWith('bot') && local.length > 3) {
      var prefix = local.substring(0, local.length - 3);
      while (prefix.endsWith('_') || prefix.endsWith('-')) {
        prefix = prefix.substring(0, prefix.length - 1);
      }
      add(prefix);
    }
    return result;
  }

  /// Ghost ids of the owner derived from [receiver]; empty if unknown.
  Set<String> get receiverGhostIds {
    final r = receiver?.toLowerCase();
    if (r == null || !_localpartSafe.hasMatch(r)) return const {};
    return {for (final prefix in ghostPrefixes) '@${prefix}_$r:$server'};
  }

  /// Ghost localpart suffix of the remote chat id, e.g. `48111` for
  /// `48111@s.whatsapp.net`, `lid-77` for `77@lid`, a Telegram/Signal id as is.
  String? get channelGhostToken {
    final id = channelId?.toLowerCase();
    if (id == null) return null;
    final at = id.indexOf('@');
    final token = at < 0
        ? id
        : id.endsWith('@lid')
        ? 'lid-${id.substring(0, at)}'
        : id.substring(0, at);
    return token.isNotEmpty && _localpartSafe.hasMatch(token) ? token : null;
  }
}

/// One room as seen by the identity resolver.
class BridgeRoomSnapshot {
  final String roomId;
  final List<BridgeInfoSnapshot> bridges;

  /// The owner's membership in this room is `join`. Other rooms (invites,
  /// left rooms) never contribute evidence.
  final bool ownerJoined;

  /// Native `m.direct` partner of the room, if any.
  final String? directPartnerId;

  /// Joined members (id → display name). Only needed for DM-shaped rooms;
  /// adapters may leave it empty for groups.
  final Map<String, String?> joinedMembers;
  const BridgeRoomSnapshot({
    required this.roomId,
    required this.bridges,
    this.ownerJoined = false,
    this.directPartnerId,
    this.joinedMembers = const {},
  });

  /// This room reduced to its trusted declarations; null when the owner is
  /// not joined or no declaration is trusted.
  BridgeRoomSnapshot? get trustedView {
    if (!ownerJoined) return null;
    final trusted = bridges.where((b) => b.trusted).toList(growable: false);
    if (trusted.isEmpty) return null;
    if (trusted.length == bridges.length) return this;
    return BridgeRoomSnapshot(
      roomId: roomId,
      bridges: trusted,
      ownerJoined: true,
      directPartnerId: directPartnerId,
      joinedMembers: joinedMembers,
    );
  }

  /// Explicit group declarations never count as DM-shaped.
  bool get dmShaped {
    if (bridges.isEmpty) return false;
    final types = bridges.map((b) => b.roomType).whereType<String>().toSet();
    if (types.any((t) => t != 'dm')) return false;
    return types.contains('dm') || directPartnerId != null;
  }
}

enum OwnIdentityEvidence {
  account(strong: true),
  receiver(strong: true),
  dmStructure(strong: false),
  displaynameTieBreak(strong: false);

  const OwnIdentityEvidence({required this.strong});

  /// Account or receiver-derived (layer 1). Only strong evidence may
  /// suppress a notification or a mention; weak evidence only labels
  /// previews.
  final bool strong;
}

class OwnRemoteIdentity {
  final String? accountUserId;

  /// Layer 1, valid in every room.
  final Map<String, OwnIdentityEvidence> _strong;

  /// Layers 2/3, valid only in the listed rooms.
  final Map<String, ({OwnIdentityEvidence evidence, Set<String> rooms})>
  _scoped;
  const OwnRemoteIdentity._(this.accountUserId, this._strong, this._scoped);
  const OwnRemoteIdentity.accountOnly(this.accountUserId)
    : _strong = const {},
      _scoped = const {};

  /// Own ghost ids (excluding the account itself), incl. room-scoped ones.
  Set<String> get ownGhostIds => {..._strong.keys, ..._scoped.keys};

  /// Own ghost ids proved by layer 1 (receiver), valid in every room.
  Set<String> get strongGhostIds => _strong.keys.toSet();

  /// Any evidence, scoped: layer-2/3 ghosts count only in [roomId]'s rooms,
  /// and never without a [roomId]. Use for previews and "outgoing" labels.
  bool isOwn(String senderId, {String? roomId}) =>
      evidenceFor(senderId, roomId: roomId) != null;

  /// Account or layer-1 evidence only; the only check that may suppress a
  /// notification or a mention.
  bool isStronglyOwn(String senderId) => evidenceFor(senderId)?.strong ?? false;

  OwnIdentityEvidence? evidenceFor(String senderId, {String? roomId}) {
    if (accountUserId != null && senderId == accountUserId) {
      return OwnIdentityEvidence.account;
    }
    final strong = _strong[senderId];
    if (strong != null) return strong;
    final scoped = _scoped[senderId];
    return scoped != null && roomId != null && scoped.rooms.contains(roomId)
        ? scoped.evidence
        : null;
  }

  /// [displaynameOf] may look a user's display name up across all loaded
  /// rooms; it is only asked for layer-1 own ghosts (a handful of ids).
  factory OwnRemoteIdentity.resolve({
    required String? accountUserId,
    required Iterable<BridgeRoomSnapshot> rooms,
    String? Function(String userId)? displaynameOf,
  }) {
    final snapshots = [for (final room in rooms) ?room.trustedView];
    final ghosts = <String, OwnIdentityEvidence>{};
    final scoped =
        <String, ({OwnIdentityEvidence evidence, Set<String> rooms})>{};
    void addScoped(String id, OwnIdentityEvidence evidence, String roomId) {
      final existing = scoped[id];
      if (existing == null) {
        scoped[id] = (evidence: evidence, rooms: {roomId});
      } else {
        existing.rooms.add(roomId);
      }
    }

    final bots = <String>{
      for (final room in snapshots)
        for (final bridge in room.bridges) bridge.bridgebot,
    };

    // Layer 1: receivers → ghost ids.
    for (final room in snapshots) {
      for (final bridge in room.bridges) {
        for (final id in bridge.receiverGhostIds) {
          if (id != accountUserId && !bots.contains(id)) {
            ghosts[id] = OwnIdentityEvidence.receiver;
          }
        }
      }
    }

    // Own display names per bridge server, from layer-1 ghosts only.
    final ownNames = <String, Set<String>>{};
    void addName(String id, String? name) {
      final n = _text(name);
      final server = splitMatrixId(id)?.$2;
      if (n == null || server == null) return;
      (ownNames[server] ??= {}).add(n);
    }

    for (final room in snapshots) {
      room.joinedMembers.forEach((id, name) {
        if (ghosts.containsKey(id)) addName(id, name);
      });
    }
    if (displaynameOf != null) {
      for (final id in ghosts.keys.toList()) {
        addName(id, displaynameOf(id));
      }
    }

    // Layer 2/3: DM structure.
    final partners = <String>{};
    final dms =
        <
          ({
            BridgeRoomSnapshot room,
            String server,
            String? partner,
            Set<String> others,
          })
        >[];
    for (final room in snapshots) {
      if (!room.dmShaped) continue;
      final servers = room.bridges.map((b) => b.server).toSet();
      if (servers.length != 1) continue;
      final server = servers.single;
      final roomGhosts = room.joinedMembers.keys
          .where(
            (id) =>
                id != accountUserId &&
                !bots.contains(id) &&
                splitMatrixId(id)?.$2 == server,
          )
          .toSet();
      final direct = room.directPartnerId;
      final byDirect = direct != null && roomGhosts.contains(direct)
          ? direct
          : null;
      final tokens = room.bridges
          .map((b) => b.channelGhostToken)
          .whereType<String>()
          .toSet();
      final byChannel = roomGhosts.where((id) {
        final local = splitMatrixId(id)!.$1.toLowerCase();
        return tokens.any((t) => local.endsWith('_$t'));
      }).toSet();
      String? partner;
      if (byDirect != null) {
        // The native mapping and the remote channel id must not disagree.
        if (byChannel.isNotEmpty && !byChannel.contains(byDirect)) continue;
        partner = byDirect;
      } else if (byChannel.length == 1) {
        partner = byChannel.single;
      } else if (byChannel.length > 1) {
        continue;
      }
      if (partner != null) partners.add(partner);
      // Channel-token matches are the partner (or its alias), never the owner
      // unless already proved by the receiver (Telegram "Saved messages").
      final others = roomGhosts
          .difference(byChannel)
          .where((id) => id != partner)
          .toSet();
      if (others.isEmpty || roomGhosts.length > 3) continue;
      dms.add((room: room, server: server, partner: partner, others: others));
    }

    final extraCounts = <String, Set<String>>{};
    for (final dm in dms) {
      if (dm.partner == null || dm.others.length != 1) continue;
      (extraCounts[dm.others.single] ??= {}).add(dm.room.roomId);
    }
    for (final dm in dms) {
      final names = ownNames[dm.server] ?? const <String>{};
      String? nameOf(String id) => _text(dm.room.joinedMembers[id]);
      if (dm.partner != null && dm.others.length == 1) {
        final candidate = dm.others.single;
        if (ghosts.containsKey(candidate) || partners.contains(candidate)) {
          continue;
        }
        final name = nameOf(candidate);
        if (name != null && name == nameOf(dm.partner!)) continue;
        final namedOwn = name != null && names.contains(name);
        if (names.isNotEmpty && name != null && !namedOwn) continue;
        final recurring = (extraCounts[candidate]?.length ?? 0) >= 2;
        if (namedOwn || recurring) {
          addScoped(candidate, OwnIdentityEvidence.dmStructure, dm.room.roomId);
        }
      } else if (dm.partner == null && dm.others.length == 2) {
        if (names.isEmpty) continue;
        final named = dm.others
            .where((id) => names.contains(nameOf(id)))
            .toList();
        if (named.length != 1) continue;
        final candidate = named.single;
        if (partners.contains(candidate) || ghosts.containsKey(candidate)) {
          continue;
        }
        addScoped(
          candidate,
          OwnIdentityEvidence.displaynameTieBreak,
          dm.room.roomId,
        );
      }
    }
    return OwnRemoteIdentity._(
      accountUserId,
      Map.unmodifiable(ghosts),
      Map.unmodifiable({
        for (final entry in scoped.entries)
          entry.key: (
            evidence: entry.value.evidence,
            rooms: Set<String>.unmodifiable(entry.value.rooms),
          ),
      }),
    );
  }

  @override
  String toString() =>
      'OwnRemoteIdentity(${_strong.length}+${_scoped.length} ghosts, '
      'redacted)';
}
