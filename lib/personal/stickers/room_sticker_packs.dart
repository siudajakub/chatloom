// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';

import 'sticker_library.dart';
import 'sticker_models.dart';
import 'sticker_pack_import.dart';

/// A link to a Matrix room that holds MSC2545 image packs (Element, Cinny,
/// FluffyChat and maunium-stickerpicker pack rooms):
/// `https://matrix.to/#/#packs:example.org`, `…/#/!id:example.org?via=…`,
/// `matrix:r/packs:example.org`, `matrix:roomid/id:example.org` or a bare
/// `#alias:server` / `!id:server`.
@immutable
class RoomPackLink {
  const RoomPackLink._(this.target, this.via);

  /// A room alias (`#…`) or room ID (`!…`).
  final String target;

  /// Servers to join through (`via=`), for a room ID.
  final List<String> via;

  bool get isAlias => target.startsWith('#');

  static final _identifier = RegExp(r'^[#!][^\s:/]+:[A-Za-z0-9.\-\[\]:]+$');

  static RoomPackLink? parse(String? raw) {
    final text = raw?.trim();
    if (text == null || text.isEmpty) return null;
    final lower = text.toLowerCase();
    String? target;
    var query = '';
    if (lower.startsWith('https://matrix.to/#/') ||
        lower.startsWith('http://matrix.to/#/') ||
        lower.startsWith('matrix.to/#/')) {
      final fragment = text.substring(text.indexOf('#/') + 2);
      final queryAt = fragment.indexOf('?');
      final path = queryAt < 0 ? fragment : fragment.substring(0, queryAt);
      query = queryAt < 0 ? '' : fragment.substring(queryAt + 1);
      // `…/#/!room/$event`: the room part only.
      target = _decode(path.split('/').first);
    } else if (lower.startsWith('matrix:')) {
      final rest = text.substring('matrix:'.length);
      final queryAt = rest.indexOf('?');
      final path = queryAt < 0 ? rest : rest.substring(0, queryAt);
      query = queryAt < 0 ? '' : rest.substring(queryAt + 1);
      final parts = path.split('/');
      if (parts.length < 2) return null;
      final id = _decode(parts[1]);
      target = switch (parts[0]) {
        'r' => '#$id',
        'roomid' => '!$id',
        _ => null,
      };
    } else if (text.startsWith('#') || text.startsWith('!')) {
      final queryAt = text.indexOf('?');
      target = queryAt < 0 ? text : text.substring(0, queryAt);
      query = queryAt < 0 ? '' : text.substring(queryAt + 1);
    }
    if (target == null || !_identifier.hasMatch(target)) return null;
    final via = <String>[];
    if (query.isNotEmpty) {
      for (final pair in query.split('&')) {
        final eq = pair.indexOf('=');
        if (eq < 0 || pair.substring(0, eq) != 'via') continue;
        final server = _decode(pair.substring(eq + 1));
        if (server.isNotEmpty && !via.contains(server)) via.add(server);
      }
    }
    return RoomPackLink._(target, List.unmodifiable(via));
  }

  static String _decode(String value) {
    try {
      return Uri.decodeComponent(value);
    } catch (_) {
      return value;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is RoomPackLink && other.target == target;

  @override
  int get hashCode => target.hashCode;
}

/// The packs a room holds, loaded for a preview.
@immutable
class RoomPackPreview {
  const RoomPackPreview({
    required this.roomId,
    required this.packs,
    required this.joined,
    this.roomName,
  });

  final String roomId;
  final String? roomName;

  /// Pack contents by state key (split packs joined).
  final Map<String, ImagePackContent> packs;

  /// The account is a member: adding needs no join.
  final bool joined;

  /// The packs with at least one sticker, as library packs (not installed).
  List<StickerPack> get stickerPacks => [
    for (final entry in packs.entries)
      if (StickerPack.fromContent(
            entry.value,
            key: StickerPackRef.packKeyOf(roomId, entry.key),
            source: StickerPackSource.installed,
            fallbackTitle: roomName,
          )
          case final pack when pack.stickers.isNotEmpty)
        pack,
  ];

  StickerPackRef refOf(StickerPack pack) {
    final stateKey = pack.key.substring(roomId.length + 1);
    return StickerPackRef(
      roomId: roomId,
      stateKey: stateKey,
      title: pack.title,
    );
  }
}

/// Where room packs are read from and joined. Production uses
/// [MatrixRoomPackBackend]; tests use a fake.
abstract interface class RoomPackBackend {
  Future<String> resolveAlias(String alias);

  /// Packs of a joined room, or null when the account is not a member.
  Map<String, ImagePackContent>? joinedPacks(String roomId);
  String? roomName(String roomId);

  /// The room's state without joining (only a world-readable room, or one
  /// the server lets the account peek into). Throws when not allowed.
  Future<List<StrippedStateEvent>> peekState(String roomId);

  /// Joins and waits until the room's state arrived; returns the room ID.
  Future<String> join(String target, List<String> via);
}

class MatrixRoomPackBackend implements RoomPackBackend {
  MatrixRoomPackBackend(this.client);
  final Client client;

  static const joinTimeout = Duration(seconds: 30);

  @override
  Future<String> resolveAlias(String alias) async =>
      (await client.getRoomIdByAlias(alias)).roomId ??
      (throw const StickerImportException(
        'This room doesn’t exist.',
        retryable: false,
      ));

  @override
  Map<String, ImagePackContent>? joinedPacks(String roomId) {
    final room = client.getRoomById(roomId);
    if (room == null || room.membership != Membership.join) return null;
    return roomImagePacks(room);
  }

  @override
  String? roomName(String roomId) =>
      client.getRoomById(roomId)?.getLocalizedDisplayname();

  @override
  Future<List<StrippedStateEvent>> peekState(String roomId) async => [
    for (final event in await client.getRoomState(roomId))
      StrippedStateEvent(
        type: event.type,
        content: event.content,
        senderId: event.senderId,
        stateKey: event.stateKey,
      ),
  ];

  @override
  Future<String> join(String target, List<String> via) async {
    final roomId = await client.joinRoom(target, via: via.isEmpty ? null : via);
    if (client.getRoomById(roomId)?.membership != Membership.join) {
      await client.waitForRoomInSync(roomId, join: true).timeout(joinTimeout);
    }
    return roomId;
  }
}

/// Loads and adds the packs of a Matrix room (MSC2545). A preview reads the
/// state of a joined room, or peeks into a public one; adding a room the
/// account is not in joins it first (so the pack syncs to every device and
/// other Matrix apps), which its members can see.
class RoomPackLoader {
  RoomPackLoader(this.backend);

  factory RoomPackLoader.of(Client client) =>
      RoomPackLoader(MatrixRoomPackBackend(client));

  final RoomPackBackend backend;

  Future<String> _roomId(RoomPackLink link) async {
    if (!link.isAlias) return link.target;
    try {
      return await backend.resolveAlias(link.target);
    } on StickerImportException {
      rethrow;
    } on MatrixException catch (e) {
      throw StickerImportException(
        e.error == MatrixError.M_NOT_FOUND
            ? 'This room doesn’t exist.'
            : 'The room couldn’t be found. Try again.',
        retryable: e.error != MatrixError.M_NOT_FOUND,
      );
    } catch (_) {
      throw const StickerImportException(
        'You’re offline or your server didn’t answer. Try again.',
      );
    }
  }

  Future<RoomPackPreview> preview(RoomPackLink link) async {
    final roomId = await _roomId(link);
    final joined = backend.joinedPacks(roomId);
    if (joined != null) {
      return RoomPackPreview(
        roomId: roomId,
        roomName: backend.roomName(roomId),
        packs: joined,
        joined: true,
      );
    }
    List<StrippedStateEvent> state;
    try {
      state = await backend.peekState(roomId);
    } on MatrixException {
      // Not world-readable: the packs show once the room is joined.
      return RoomPackPreview(roomId: roomId, packs: const {}, joined: false);
    } catch (_) {
      throw const StickerImportException(
        'You’re offline or your server didn’t answer. Try again.',
      );
    }
    final byType = <String, Map<String, StrippedStateEvent>>{};
    String? name;
    for (final event in state) {
      if (event.type == EventTypes.RoomName) {
        final value = event.content['name'];
        if (value is String && value.trim().isNotEmpty) name = value.trim();
      }
      final key = event.stateKey;
      if (key == null || !imagePackStateTypes.contains(event.type)) continue;
      (byType[event.type] ??= {})[key] = event;
    }
    return RoomPackPreview(
      roomId: roomId,
      roomName: name,
      packs: {
        for (final type in imagePackStateTypes)
          ...combineImagePackStates(byType[type] ?? const {}),
      },
      joined: false,
    );
  }

  /// Joins the room of [link] (when needed) and returns the fresh preview.
  Future<RoomPackPreview> join(RoomPackLink link) async {
    try {
      final roomId = await backend.join(link.target, link.via);
      final packs = backend.joinedPacks(roomId) ?? const {};
      return RoomPackPreview(
        roomId: roomId,
        roomName: backend.roomName(roomId),
        packs: packs,
        joined: true,
      );
    } on TimeoutException {
      throw const StickerImportException(
        'Joining the room is taking long. Try again in a moment.',
      );
    } on MatrixException catch (e) {
      throw StickerImportException(
        e.error == MatrixError.M_FORBIDDEN
            ? 'You can’t join this room.'
            : 'The room couldn’t be joined. Try again.',
        retryable: e.error != MatrixError.M_FORBIDDEN,
      );
    } catch (_) {
      throw const StickerImportException(
        'You’re offline or your server didn’t answer. Try again.',
      );
    }
  }

  /// Adds [pack] of [preview] to the library (joining first when needed).
  /// Idempotent: an installed pack is left as it is.
  Future<void> add(
    RoomPackPreview preview,
    StickerPack pack, {
    required StickerLibrary library,
    RoomPackLink? link,
  }) async {
    if (library.packByKey(pack.key)?.source == StickerPackSource.installed) {
      return;
    }
    if (!preview.joined) {
      if (link == null) {
        throw const StickerImportException(
          'This room can’t be joined from here.',
          retryable: false,
        );
      }
      await join(link);
    }
    final stateKey = pack.key.substring(preview.roomId.length + 1);
    library.addPack(preview.refOf(pack), content: preview.packs[stateKey]);
  }
}

/// Sticker packs of rooms the account is in that the library doesn't show
/// yet (a group's pack, a pack room joined in another app). No request.
List<(StickerPackRef, StickerPack, ImagePackContent)> packsInJoinedRooms(
  Client client,
  StickerLibrary library,
) {
  final shown = {for (final pack in library.packs) pack.key};
  final out = <(StickerPackRef, StickerPack, ImagePackContent)>[];
  for (final room in client.rooms) {
    if (room.membership != Membership.join) continue;
    final packs = roomImagePacks(room);
    if (packs.isEmpty) continue;
    for (final entry in packs.entries) {
      final key = StickerPackRef.packKeyOf(room.id, entry.key);
      if (shown.contains(key)) continue;
      final pack = StickerPack.fromContent(
        entry.value,
        key: key,
        source: StickerPackSource.installed,
        fallbackTitle: room.getLocalizedDisplayname(),
      );
      if (pack.stickers.isEmpty) continue;
      // The bridge space's copy of a pack the library has (saved in the
      // account, or imported on another device).
      final url = pack.packUrl;
      if (url != null && library.isInstalled(url)) continue;
      out.add((
        StickerPackRef(roomId: room.id, stateKey: entry.key, title: pack.title),
        pack,
        entry.value,
      ));
    }
  }
  return out;
}
