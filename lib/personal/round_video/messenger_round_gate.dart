// SPDX-License-Identifier: AGPL-3.0-or-later
// Pure Dart (no Flutter), like telegram_room_binding.dart.
import 'package:matrix/matrix.dart';
import 'package:personal_core/bridge_capabilities.dart';
import 'package:personal_core/personal_core.dart';

import 'telegram_room_binding.dart';

/// `m.bridge` protocol ids of the Messenger mode of mautrix-meta: bridgev2
/// publishes its Beeper bridge type (`facebookgo`) there, older bridges the
/// network id (`facebook`). Instagram (`instagram`/`instagramgo`, same
/// codebase) is deliberately not accepted.
const messengerProtocolIds = {'facebook', 'facebookgo'};

/// Networks ([PersonalClient.networkOf]) whose chats may offer round video.
const roundChatNetworks = {'telegram', ...messengerProtocolIds};

/// Messenger has no native round type: a round is sent as an ordinary
/// square `m.video` through the stock bridge, marked for ChatLoom only
/// ([roundVideoDisplayMarker]). There is no fork capability state, so the
/// gate relies on the bridge's own declarations:
///
/// * exactly one `m.bridge` in the room, `protocol.id == 'facebook'`, with a
///   matching `uk.half-shot.bridge`, both sent by the declared bot, which is
///   joined;
/// * the portal is the user's own: no other Matrix user (outside the
///   bridge's server) is joined, so the bridge cannot relay through a
///   different login;
/// * `com.beeper.room_features` from the same bot allows `m.video` as
///   `video/mp4`, within the measured server upload limit;
/// * an encrypted room with file encryption on (same as Telegram);
/// * no silent send (Messenger has no such option).
class MessengerRoundBinding {
  final RoundBridgeIdentity identity;
  final Map<String, dynamic> features;
  const MessengerRoundBinding._(this.identity, this.features);

  /// Current capabilities from room state and the last measured upload
  /// limit. Without a measurement nothing is allowed.
  RoundRouteCapabilities capabilities(Room room) {
    final limit = MessengerRoundGate._uploadLimits[room.client];
    final evidence = BridgeRoomCapabilities.fromState(
      features,
    ).evidence(BridgeFeature.video, media: MessengerRoundGate._probe);
    if (!evidence.result.allowed || limit == null || limit <= 0) {
      return const RoundRouteCapabilities(allowed: false);
    }
    int min(int a, int? b) => b != null && b > 0 && b < a ? b : a;
    final limits = evidence.limits;
    final side = min(min(640, limits['max_width']), limits['max_height']);
    final duration = limits['max_duration'];
    return RoundRouteCapabilities(
      allowed: true,
      profile: RoundEncodingProfile(
        maxSizeBytes: min(limit, limits['max_size']),
        maxSide: side,
        recommendedSide: side < 384 ? side : 384,
        maxDurationMs: min(60000, duration == null ? null : duration * 1000),
      ),
    );
  }
}

/// What a route allows right now: the encoding profile is null until the
/// server's upload limit was measured.
class RoundRouteCapabilities {
  final bool allowed;
  final RoundEncodingProfile? profile;
  final bool silentAllowed;
  const RoundRouteCapabilities({
    required this.allowed,
    this.profile,
    this.silentAllowed = false,
  });
}

class MessengerRoundGate {
  MessengerRoundGate._();

  static final _uploadLimits = Expando<int>('messengerRoundUploadLimit');
  static final _unreachable = Expando<bool>('messengerRoundUnreachable');

  /// Stand-in measurement: checks the MIME type and support level of the
  /// declaration; the real file is checked against the limits before send.
  static const _probe = BridgeMediaRequest(
    mimeType: 'video/mp4',
    sizeBytes: 1,
    width: 1,
    height: 1,
    durationSeconds: 1,
  );

  static bool uploadLimitUnreachable(Client client) =>
      _unreachable[client] ?? false;

  /// Whether any bridge of [room] declares the Messenger protocol (labels
  /// only; never authorizes).
  static bool isMessengerRoom(Room room) =>
      (room.states['m.bridge'] ?? const <String, StrippedStateEvent>{}).values
          .any((info) {
            final protocol = info.content['protocol'];
            return protocol is Map &&
                messengerProtocolIds.contains(protocol['id']);
          });

  /// The bound Messenger bridge of [room], when every identity and
  /// declaration check passes (encryption and upload limit not included).
  static MessengerRoundBinding? of(Room room, {String? stateKey}) =>
      _evaluate(room, stateKey: stateKey).$2;

  /// Measures the server's upload limit, then returns the current
  /// capabilities (null when the room is not a bound Messenger chat).
  static Future<RoundRouteCapabilities?> preflight(Room room) async {
    if (of(room) == null) return null;
    try {
      final limit = (await room.client.getConfig(
        cacheLifetime: Duration.zero,
        throwOnUpdateFailure: true,
      )).mUploadSize;
      _uploadLimits[room.client] = limit != null && limit > 0 ? limit : null;
      _unreachable[room.client] = null;
    } catch (_) {
      _uploadLimits[room.client] = null;
      _unreachable[room.client] = true;
    }
    return of(room)?.capabilities(room);
  }

  static void forget(Client client) {
    _uploadLimits[client] = null;
    _unreachable[client] = null;
  }

  /// Why a Messenger round would be refused, in check order. Reports only
  /// codes and booleans, never state contents or IDs.
  static RoundGateReport diagnose(
    Room room, {
    String? stateKey,
    bool silent = false,
    bool requireUploadLimit = false,
  }) {
    final (report, binding) = _evaluate(room, stateKey: stateKey);
    if (binding == null) return report;
    final checks = Map<String, bool>.of(report.checks);
    RoundGateReport fail(RoundGateCode code) => RoundGateReport(
      code,
      checks: checks,
      bridgeSources: report.bridgeSources,
    );
    final measured = _uploadLimits[room.client];
    checks['uploadLimitKnown'] = measured != null && measured > 0;
    if (requireUploadLimit && !checks['uploadLimitKnown']!) {
      return fail(RoundGateCode.uploadLimitUnknown);
    }
    checks['roomEncrypted'] = room.encrypted;
    if (!room.encrypted) return fail(RoundGateCode.notEncrypted);
    checks['fileEncryption'] =
        room.client.encryptionEnabled && room.client.fileEncryptionEnabled;
    if (!checks['fileEncryption']!) {
      return fail(RoundGateCode.fileEncryptionOff);
    }
    if (silent) {
      checks['silentSend'] = false;
      return fail(RoundGateCode.silentUnsupported);
    }
    return fail(RoundGateCode.available);
  }

  static (RoundGateReport, MessengerRoundBinding?) _evaluate(
    Room room, {
    String? stateKey,
  }) {
    final account = room.client.userID;
    if (account == null || room.membership != Membership.join) {
      return (const RoundGateReport(RoundGateCode.notJoined), null);
    }
    final bridges = room.states['m.bridge'] ?? <String, StrippedStateEvent>{};
    final keys = [
      for (final key in bridges.keys)
        if (stateKey == null || key == stateKey) key,
    ];
    if (keys.isEmpty) {
      return (const RoundGateReport(RoundGateCode.noBridgeInfo), null);
    }
    final checks = <String, bool>{};
    RoundGateReport fail(RoundGateCode code) =>
        RoundGateReport(code, checks: checks, bridgeSources: keys.length);
    bool isMessenger(StrippedStateEvent info) {
      final protocol = info.content['protocol'];
      return protocol is Map && messengerProtocolIds.contains(protocol['id']);
    }

    checks['messenger'] = keys.any((key) => isMessenger(bridges[key]!));
    if (!checks['messenger']!) {
      return (fail(RoundGateCode.unsupportedNetwork), null);
    }
    checks['singleBridge'] = keys.length == 1;
    if (keys.length != 1) return (fail(RoundGateCode.ambiguousBridges), null);
    final key = keys.single;
    final info = bridges[key]!;
    final bot = info.content['bridgebot'];
    final botServer = bot is String ? _server(bot) : null;
    checks['bridgeInfo'] = botServer != null;
    if (bot is! String || botServer == null) {
      return (fail(RoundGateCode.noBridgeInfo), null);
    }
    final legacy = room.getState('uk.half-shot.bridge', key);
    checks['legacyBridgeInfo'] = legacy != null;
    if (legacy == null) {
      return (fail(RoundGateCode.missingLegacyBridgeInfo), null);
    }
    final features = room.getState(bridgeFeaturesEventType, key);
    checks['roomFeatures'] = features != null;
    if (features == null) {
      return (fail(RoundGateCode.missingRoomFeatures), null);
    }
    final legacyProtocol = legacy.content['protocol'];
    checks['sameSender'] =
        info.content['creator'] == bot &&
        legacy.content['bridgebot'] == bot &&
        legacyProtocol is Map &&
        legacyProtocol['id'] == (info.content['protocol'] as Map)['id'] &&
        ![
          info,
          legacy,
          features,
        ].any((e) => e.senderId != bot || e.stateKey != key);
    if (!checks['sameSender']!) {
      return (fail(RoundGateCode.senderMismatch), null);
    }
    checks['botJoined'] =
        room.getState(EventTypes.RoomMember, bot)?.content['membership'] ==
        'join';
    if (!checks['botJoined']!) {
      return (fail(RoundGateCode.botNotJoined), null);
    }
    // Own login: the portal holds the account, the bridge bot and the
    // bridge's own users only. Another Matrix user could make the bridge
    // relay through a login that is not the account's.
    final members =
        room.states[EventTypes.RoomMember] ??
        const <String, StrippedStateEvent>{};
    checks['ownAccount'] = !members.entries.any(
      (entry) =>
          entry.key != account &&
          entry.value.content['membership'] == 'join' &&
          _server(entry.key) != botServer,
    );
    if (!checks['ownAccount']!) {
      return (fail(RoundGateCode.foreignOwner), null);
    }
    final channel = info.content['channel'];
    final receiver = channel is Map ? channel['fi.mau.receiver'] : null;
    final legacyChannel = legacy.content['channel'];
    final legacyReceiver = legacyChannel is Map
        ? legacyChannel['fi.mau.receiver']
        : null;
    checks['sameLogin'] =
        (receiver == null || receiver is String) &&
        (legacyChannel == null || legacyReceiver == receiver);
    if (!checks['sameLogin']!) {
      return (fail(RoundGateCode.receiverMismatch), null);
    }
    checks['videoAllowed'] = BridgeRoomCapabilities.fromState(
      features.content,
    ).evidence(BridgeFeature.video, media: _probe).result.allowed;
    if (!checks['videoAllowed']!) {
      return (fail(RoundGateCode.videoNotAllowed), null);
    }
    return (
      fail(RoundGateCode.available),
      MessengerRoundBinding._(
        RoundBridgeIdentity(
          accountId: receiver is String ? receiver : '',
          roomId: room.id,
          stateKey: key,
          senderId: bot,
        ),
        Map<String, dynamic>.from(features.content),
      ),
    );
  }

  static String? _server(String userId) {
    if (!userId.startsWith('@')) return null;
    final colon = userId.indexOf(':');
    return colon <= 1 || colon == userId.length - 1
        ? null
        : userId.substring(colon + 1);
  }
}
