// SPDX-License-Identifier: AGPL-3.0-or-later
import 'dart:convert';

import 'package:matrix/matrix.dart';
import 'package:personal_core/bridge_capabilities.dart';
import 'package:personal_core/personal_core.dart';

/// Authenticated state binds the fork, its login owner and the exact portal.
/// A single room-features event or a network label never establishes trust.
class TelegramRoomBinding {
  final RoundBridgeIdentity identity;
  final RoundCapabilityEvent features, media;
  final bool _anchored;
  const TelegramRoomBinding._(
    this.identity,
    this.features,
    this.media,
    this._anchored,
  );
  static final _uploadLimits = <Client, int>{};
  static final _trusted = <Client, Set<String>>{};
  static String _trustKey(Client client, RoundBridgeIdentity identity) =>
      jsonEncode([
        client.userID,
        client.deviceID,
        identity.stateKey,
        identity.accountId,
        identity.senderId,
      ]);

  /// Only encrypted local configuration or an explicit user trust decision.
  static void installTrustedIdentity(
    Client client,
    RoundBridgeIdentity identity,
  ) {
    if (!identity.valid) return;
    (_trusted[client] ??= <String>{}).add(_trustKey(client, identity));
  }

  static TelegramRoomBinding? of(Room room, {String? stateKey}) {
    return _resolve(room, stateKey: stateKey, requireTrusted: true);
  }

  /// For displaying a concrete trust decision; never authorizes an operation.
  static TelegramRoomBinding? unverifiedCandidate(
    Room room, {
    String? stateKey,
  }) => _resolve(room, stateKey: stateKey, requireTrusted: false);
  static TelegramRoomBinding? _resolve(
    Room room, {
    String? stateKey,
    required bool requireTrusted,
  }) {
    final account = room.client.userID;
    if (account == null || room.membership != Membership.join) return null;
    final candidates = <TelegramRoomBinding>[];
    for (final entry
        in (room.states['m.bridge'] ?? <String, StrippedStateEvent>{})
            .entries) {
      final key = entry.key;
      if (stateKey != null && key != stateKey) continue;
      final info = entry.value;
      final legacy = room.getState('uk.half-shot.bridge', key);
      final features = room.getState(bridgeFeaturesEventType, key);
      final media = room.getState(telegramMediaCapabilitiesEventType, key);
      final bot = info.content['bridgebot'];
      final protocol = info.content['protocol'];
      final login = media?.content['account_id'];
      if (bot is! String ||
          !bot.startsWith('@') ||
          protocol is! Map ||
          protocol['id'] != 'telegram' ||
          login is! String ||
          login.isEmpty ||
          legacy == null ||
          features == null ||
          media == null ||
          media.content['matrix_user_id'] != account ||
          media.content['version'] != 1 ||
          media.content['room_id'] != room.id ||
          media.content['bridge_state_key'] != key ||
          info.content['creator'] != bot ||
          legacy.content['bridgebot'] != bot ||
          legacy.content['protocol'] is! Map ||
          (legacy.content['protocol'] as Map)['id'] != 'telegram' ||
          [
            info,
            legacy,
            features,
            media,
          ].any((e) => e.senderId != bot || e.stateKey != key) ||
          room.getState(EventTypes.RoomMember, bot)?.content['membership'] !=
              'join') {
        continue;
      }
      final channel = info.content['channel'];
      final receiver = channel is Map ? channel['fi.mau.receiver'] : null;
      if (receiver != null && receiver != '' && receiver != login) continue;
      final identity = RoundBridgeIdentity(
        accountId: login,
        roomId: room.id,
        stateKey: key,
        senderId: bot,
      );
      if (requireTrusted &&
          _trusted[room.client]?.contains(_trustKey(room.client, identity)) !=
              true)
        continue;
      RoundCapabilityEvent wrap(StrippedStateEvent event) =>
          RoundCapabilityEvent(
            accountId: login,
            roomId: room.id,
            stateKey: key,
            senderId: event.senderId,
            content: event.content,
          );
      candidates.add(
        TelegramRoomBinding._(
          identity,
          wrap(features),
          wrap(media),
          requireTrusted,
        ),
      );
    }
    return candidates.length == 1 ? candidates.single : null;
  }

  RoundBridgeCapabilities capabilities(
    Room room,
  ) => RoundBridgeCapabilities.fromEvents(
    identity: identity,
    featuresEvent:
        _anchored &&
            _trusted[room.client]?.contains(_trustKey(room.client, identity)) ==
                true
        ? features
        : null,
    mediaEvent:
        _anchored &&
            _trusted[room.client]?.contains(_trustKey(room.client, identity)) ==
                true
        ? media
        : null,
    runtimeUploadLimitBytes: _uploadLimits[room.client],
  );

  static Future<RoundBridgeCapabilities?> preflight(Room room) async {
    final binding = of(room);
    if (binding == null) return null;
    try {
      final limit = (await room.client.getConfig(
        cacheLifetime: Duration.zero,
        throwOnUpdateFailure: true,
      )).mUploadSize;
      if (limit == null || limit <= 0) {
        _uploadLimits.remove(room.client);
      } else {
        _uploadLimits[room.client] = limit;
      }
    } catch (_) {
      _uploadLimits.remove(room.client);
    }
    return of(room)?.capabilities(room);
  }

  static void forget(Client client) {
    _uploadLimits.remove(client);
    _trusted.remove(client);
  }
}
