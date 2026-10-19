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

  /// Bumped on every trust change so cached availability can be refreshed.
  static int get trustRevision => _trustRevision;
  static int _trustRevision = 0;
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
    if ((_trusted[client] ??= <String>{}).add(_trustKey(client, identity))) {
      _trustRevision++;
    }
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
    _trustRevision++;
  }

  /// Explains why [of]/[preflight] would refuse this room, in the same order.
  /// Reports event presence and booleans only, never state contents or IDs.
  /// Never authorizes anything: callers must still use [of] and [preflight].
  ///
  /// [requireUploadLimit] treats a missing runtime upload measurement as a
  /// failure (use right after [preflight]); otherwise it is assumed measurable.
  static RoundGateReport diagnose(
    Room room, {
    String? stateKey,
    bool silent = false,
    bool requireUploadLimit = false,
  }) {
    final account = room.client.userID;
    if (account == null || room.membership != Membership.join) {
      return const RoundGateReport(RoundGateCode.notJoined);
    }
    final bridges = room.states['m.bridge'] ?? <String, StrippedStateEvent>{};
    final keys = [
      for (final key in bridges.keys)
        if (stateKey == null || key == stateKey) key,
    ];
    if (keys.isEmpty) return const RoundGateReport(RoundGateCode.noBridgeInfo);
    final failures = <RoundGateReport>[];
    final valid = <(String, String, String)>[];
    for (final key in keys) {
      final info = bridges[key]!;
      final checks = <String, bool>{};
      RoundGateReport fail(RoundGateCode code) =>
          RoundGateReport(code, checks: checks, bridgeSources: keys.length);
      final bot = info.content['bridgebot'];
      final protocol = info.content['protocol'];
      checks['bridgeInfo'] = bot is String && bot.startsWith('@');
      if (bot is! String || !bot.startsWith('@')) {
        failures.add(fail(RoundGateCode.noBridgeInfo));
        continue;
      }
      checks['telegram'] = protocol is Map && protocol['id'] == 'telegram';
      if (!checks['telegram']!) {
        failures.add(fail(RoundGateCode.notTelegram));
        continue;
      }
      final legacy = room.getState('uk.half-shot.bridge', key);
      final features = room.getState(bridgeFeaturesEventType, key);
      final media = room.getState(telegramMediaCapabilitiesEventType, key);
      checks['legacyBridgeInfo'] = legacy != null;
      checks['roomFeatures'] = features != null;
      checks['roundExtension'] = media != null;
      if (legacy == null) {
        failures.add(fail(RoundGateCode.missingLegacyBridgeInfo));
        continue;
      }
      if (features == null) {
        failures.add(fail(RoundGateCode.missingRoomFeatures));
        continue;
      }
      if (media == null) {
        failures.add(fail(RoundGateCode.bridgeLacksRoundSupport));
        continue;
      }
      final login = media.content['account_id'];
      checks['extensionVersion'] =
          media.content['version'] == 1 && login is String && login.isNotEmpty;
      if (!checks['extensionVersion']!) {
        failures.add(fail(RoundGateCode.extensionVersion));
        continue;
      }
      checks['ownAccount'] = media.content['matrix_user_id'] == account;
      if (!checks['ownAccount']!) {
        failures.add(fail(RoundGateCode.foreignOwner));
        continue;
      }
      checks['sameRoom'] =
          media.content['room_id'] == room.id &&
          media.content['bridge_state_key'] == key;
      if (!checks['sameRoom']!) {
        failures.add(fail(RoundGateCode.roomMismatch));
        continue;
      }
      final legacyProtocol = legacy.content['protocol'];
      checks['sameSender'] =
          info.content['creator'] == bot &&
          legacy.content['bridgebot'] == bot &&
          legacyProtocol is Map &&
          legacyProtocol['id'] == 'telegram' &&
          ![
            info,
            legacy,
            features,
            media,
          ].any((e) => e.senderId != bot || e.stateKey != key);
      if (!checks['sameSender']!) {
        failures.add(fail(RoundGateCode.senderMismatch));
        continue;
      }
      checks['botJoined'] =
          room.getState(EventTypes.RoomMember, bot)?.content['membership'] ==
          'join';
      if (!checks['botJoined']!) {
        failures.add(fail(RoundGateCode.botNotJoined));
        continue;
      }
      final channel = info.content['channel'];
      final receiver = channel is Map ? channel['fi.mau.receiver'] : null;
      checks['sameLogin'] =
          receiver == null || receiver == '' || receiver == login;
      if (!checks['sameLogin']!) {
        failures.add(fail(RoundGateCode.receiverMismatch));
        continue;
      }
      valid.add((key, bot, login as String));
    }
    if (valid.length > 1) {
      return RoundGateReport(
        RoundGateCode.ambiguousBridges,
        bridgeSources: keys.length,
      );
    }
    if (valid.isEmpty) {
      // Per-source codes are declared in check order: report the source that
      // got furthest.
      return failures.reduce((a, b) => b.code.index > a.code.index ? b : a);
    }
    final (key, bot, login) = valid.single;
    final checks = <String, bool>{
      'bridgeInfo': true,
      'telegram': true,
      'legacyBridgeInfo': true,
      'roomFeatures': true,
      'roundExtension': true,
      'extensionVersion': true,
      'ownAccount': true,
      'sameRoom': true,
      'sameSender': true,
      'botJoined': true,
      'sameLogin': true,
    };
    RoundGateReport report(RoundGateCode code) =>
        RoundGateReport(code, checks: checks, bridgeSources: keys.length);
    final identity = RoundBridgeIdentity(
      accountId: login,
      roomId: room.id,
      stateKey: key,
      senderId: bot,
    );
    RoundCapabilityEvent wrap(StrippedStateEvent event) => RoundCapabilityEvent(
      accountId: login,
      roomId: room.id,
      stateKey: key,
      senderId: event.senderId,
      content: event.content,
    );
    final mediaEvent = wrap(
      room.getState(telegramMediaCapabilitiesEventType, key)!,
    );
    final featuresEvent = wrap(room.getState(bridgeFeaturesEventType, key)!);
    final content = mediaEvent.content;
    checks['roundAllowed'] =
        content['round_video'] != false &&
        content['round_video_permission'] != 'denied';
    if (!checks['roundAllowed']!) return report(RoundGateCode.roundDenied);
    checks['roundDeclared'] =
        content['round_video'] == true &&
        content['round_video_permission'] == 'allowed' &&
        BridgeRoomCapabilities.fromState(
          featuresEvent.content,
        ).evidence(BridgeFeature.roundVideo).result.allowed;
    if (!checks['roundDeclared']!) {
      return report(RoundGateCode.roundNotDeclared);
    }
    final measured = _uploadLimits[room.client];
    checks['uploadLimitKnown'] = measured != null && measured > 0;
    if (requireUploadLimit && !checks['uploadLimitKnown']!) {
      return report(RoundGateCode.uploadLimitUnknown);
    }
    final caps = RoundBridgeCapabilities.fromEvents(
      identity: identity,
      featuresEvent: featuresEvent,
      mediaEvent: mediaEvent,
      // Without a measurement, check the rest of the profile with a stand-in;
      // the real limit is always re-measured by [preflight] before capture.
      runtimeUploadLimitBytes: checks['uploadLimitKnown']! ? measured : 1,
    );
    checks['profileComplete'] = caps.result.allowed && caps.profile != null;
    if (!checks['profileComplete']!) {
      return report(RoundGateCode.profileIncomplete);
    }
    checks['roomEncrypted'] = room.encrypted;
    if (!room.encrypted) return report(RoundGateCode.notEncrypted);
    checks['fileEncryption'] =
        room.client.encryptionEnabled && room.client.fileEncryptionEnabled;
    if (!checks['fileEncryption']!) {
      return report(RoundGateCode.fileEncryptionOff);
    }
    if (silent) {
      checks['silentSend'] = caps.extension.operation('silent_send').allowed;
      if (!checks['silentSend']!) {
        return report(RoundGateCode.silentUnsupported);
      }
    }
    checks['trusted'] =
        _trusted[room.client]?.contains(_trustKey(room.client, identity)) ==
        true;
    if (!checks['trusted']!) return report(RoundGateCode.needsTrust);
    return report(RoundGateCode.available);
  }
}

/// Ordered like [TelegramRoomBinding.diagnose]. Only [available], [needsTrust]
/// and [uploadLimitUnknown] can still lead to a recording.
enum RoundGateCode {
  available,
  needsTrust,
  notJoined,
  noBridgeInfo,
  notTelegram,
  missingLegacyBridgeInfo,
  missingRoomFeatures,
  bridgeLacksRoundSupport,
  extensionVersion,
  foreignOwner,
  roomMismatch,
  senderMismatch,
  botNotJoined,
  receiverMismatch,
  ambiguousBridges,
  roundDenied,
  roundNotDeclared,
  uploadLimitUnknown,
  profileIncomplete,
  notEncrypted,
  fileEncryptionOff,
  silentUnsupported;

  /// True when recording cannot succeed until the room or bridge changes.
  bool get terminal => !{
    RoundGateCode.available,
    RoundGateCode.needsTrust,
    RoundGateCode.uploadLimitUnknown,
  }.contains(this);
  static RoundGateCode? tryParse(String name) {
    for (final code in values) {
      if (code.name == name) return code;
    }
    return null;
  }
}

/// Diagnostic snapshot: a code plus named boolean checks. No event contents,
/// user IDs, logins or state keys are kept, so it is safe to log or display.
class RoundGateReport {
  final RoundGateCode code;
  final Map<String, bool> checks;
  final int bridgeSources;
  const RoundGateReport(
    this.code, {
    this.checks = const {},
    this.bridgeSources = 0,
  });
  bool get terminal => code.terminal;
  @override
  String toString() =>
      'RoundGateReport(${code.name}, sources: $bridgeSources, '
      '${checks.entries.map((e) => '${e.key}=${e.value}').join(', ')})';
}
