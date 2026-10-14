// SPDX-License-Identifier: AGPL-3.0-or-later
import 'contracts.dart';

const roundMessageMarker = 'fi.mau.telegram.round_message';
const roundVideoCapabilityKey = 'pl.personal.chat.telegram.round_video';
const telegramMediaCapabilitiesEventType =
    'pl.personal.chat.telegram.media_capabilities';
const telegramMediaPlayedEventType = 'pl.personal.chat.telegram.media_played';
const telegramMediaForwardEventType = 'pl.personal.chat.telegram.media_forward';
const telegramMediaStateEventType = 'pl.personal.chat.telegram.media_state';
const telegramSendOptionsKey = 'pl.personal.chat.telegram.send_options';

/// A capture's destination is fixed before permissions or camera access.
class RoundSendTarget {
  final String accountId, deviceId, roomId, network;
  final String? replyEventId, threadEventId, readUpToEventId;
  final String? bridgeAccountId, bridgeStateKey, bridgeSenderId;
  final bool silent;
  const RoundSendTarget({
    required this.accountId,
    required this.deviceId,
    required this.roomId,
    required this.network,
    this.replyEventId,
    this.threadEventId,
    this.readUpToEventId,
    this.bridgeAccountId,
    this.bridgeStateKey,
    this.bridgeSenderId,
    this.silent = false,
  });
  Map<String, dynamic> toJson() => {
    'accountId': accountId,
    'deviceId': deviceId,
    'roomId': roomId,
    'network': network,
    'replyEventId': replyEventId,
    'threadEventId': threadEventId,
    'readUpToEventId': readUpToEventId,
    'bridgeAccountId': bridgeAccountId,
    'bridgeStateKey': bridgeStateKey,
    'bridgeSenderId': bridgeSenderId,
    'silent': silent,
  };
  factory RoundSendTarget.fromJson(Map<String, dynamic> j) => RoundSendTarget(
    accountId: j['accountId'] as String,
    deviceId: j['deviceId'] as String,
    roomId: j['roomId'] as String,
    network: j['network'] as String,
    replyEventId: j['replyEventId'] as String?,
    threadEventId: j['threadEventId'] as String?,
    readUpToEventId: j['readUpToEventId'] as String?,
    bridgeAccountId: j['bridgeAccountId'] as String?,
    bridgeStateKey: j['bridgeStateKey'] as String?,
    bridgeSenderId: j['bridgeSenderId'] as String?,
    silent: _silentFromJson(j),
  );
  static bool _silentFromJson(Map<String, dynamic> json) {
    if (!json.containsKey('silent')) return false;
    final value = json['silent'];
    if (value is! bool)
      throw const FormatException('Invalid round silent option');
    return value;
  }

  bool get valid =>
      accountId.isNotEmpty &&
      deviceId.isNotEmpty &&
      roomId.isNotEmpty &&
      network == 'telegram';
  @override
  String toString() => 'RoundSendTarget(redacted)';
}

class RoundEncodingProfile {
  final int maxDurationMs, maxSide, maxSizeBytes;
  final int recommendedSide, videoBitrate, audioBitrate;
  const RoundEncodingProfile({
    required this.maxSizeBytes,
    this.maxDurationMs = 60000,
    this.maxSide = 640,
    this.recommendedSide = 384,
    this.videoBitrate = 1000000,
    this.audioBitrate = 64000,
  });
  bool get valid =>
      maxDurationMs > 0 &&
      maxDurationMs <= 60000 &&
      maxSide > 0 &&
      maxSide <= 640 &&
      maxSizeBytes > 0 &&
      recommendedSide > 0 &&
      recommendedSide <= maxSide &&
      videoBitrate > 0 &&
      audioBitrate > 0;
}

/// Incoming metadata may be incomplete. Outgoing metadata must be measured.
class RoundVideoDescriptor {
  final int? sizeBytes, width, height, durationMs;
  final String mimeType;
  final String? videoCodec, audioCodec;
  final bool cornersSanitized;
  const RoundVideoDescriptor({
    this.sizeBytes,
    this.width,
    this.height,
    this.durationMs,
    this.mimeType = 'video/mp4',
    this.videoCodec,
    this.audioCodec,
    this.cornersSanitized = false,
  });
  static RoundVideoDescriptor? fromContent(
    Map<String, dynamic> content, {
    bool redacted = false,
  }) {
    final info = content['info'];
    if (redacted ||
        content['msgtype'] != 'm.video' ||
        info is! Map ||
        info[roundMessageMarker] is! bool ||
        info[roundMessageMarker] != true) {
      return null;
    }
    int? positive(Object? v) => v is int && v >= 0 ? v : null;
    return RoundVideoDescriptor(
      sizeBytes: positive(info['size']),
      width: positive(info['w']),
      height: positive(info['h']),
      durationMs: positive(info['duration']),
      mimeType: info['mimetype'] is String ? info['mimetype'] as String : '',
    );
  }

  String? outgoingError(RoundEncodingProfile profile) {
    if (!profile.valid) return 'invalidEncodingProfile';
    if (mimeType != 'video/mp4' ||
        videoCodec != 'h264' ||
        audioCodec != 'aac') {
      return 'invalidRoundFormat';
    }
    if (!cornersSanitized) return 'unsanitizedCorners';
    if (width == null ||
        height == null ||
        width! <= 0 ||
        width != height ||
        width! > profile.maxSide)
      return 'invalidRoundDimensions';
    if (durationMs == null ||
        durationMs! <= 0 ||
        durationMs! > profile.maxDurationMs)
      return 'invalidRoundDuration';
    if (sizeBytes == null ||
        sizeBytes! <= 0 ||
        sizeBytes! > profile.maxSizeBytes)
      return 'roundSizeLimit';
    return null;
  }

  Map<String, dynamic> toJson() => {
    'sizeBytes': sizeBytes,
    'width': width,
    'height': height,
    'durationMs': durationMs,
    'mimeType': mimeType,
    'videoCodec': videoCodec,
    'audioCodec': audioCodec,
    'cornersSanitized': cornersSanitized,
  };
  factory RoundVideoDescriptor.fromJson(Map<String, dynamic> j) =>
      RoundVideoDescriptor(
        sizeBytes: j['sizeBytes'] as int?,
        width: j['width'] as int?,
        height: j['height'] as int?,
        durationMs: j['durationMs'] as int?,
        mimeType: j['mimeType'] as String,
        videoCodec: j['videoCodec'] as String?,
        audioCodec: j['audioCodec'] as String?,
        cornersSanitized: j['cornersSanitized'] == true,
      );
  Map<String, dynamic> get matrixInfo => {
    'mimetype': mimeType,
    'size': sizeBytes,
    'w': width,
    'h': height,
    'duration': durationMs,
    roundMessageMarker: true,
  };
  @override
  String toString() => 'RoundVideoDescriptor(redacted)';
}

/// Guard before SDK download/decrypt, preload, thumbnail or cache access.
/// Limited media stays a placeholder until a proven lazy-consumption transport.
class RoundMediaPolicy {
  final bool isTimeLimited, protectedContent, malformed, transferAllowed;
  const RoundMediaPolicy({
    this.isTimeLimited = false,
    this.protectedContent = false,
    this.malformed = false,
    this.transferAllowed = true,
  });
  bool get canPlay => transferAllowed && !isTimeLimited && !malformed;
  bool get canPersist => canPlay && !protectedContent;
  bool get canExport => canPersist;
  bool get canForward => canPersist;
  bool get canTranscribe => canPersist;
  String? get placeholderReason => malformed
      ? 'invalidProtectiveMetadata'
      : !transferAllowed || isTimeLimited
      ? 'limitedMediaUnavailable'
      : null;
  static RoundMediaPolicy fromContent(Map<String, dynamic> content) {
    var limited = false, protected = false, malformed = false, allowed = true;
    final maps = <Map>[content];
    if (content['info'] is Map) maps.add(content['info'] as Map);
    for (final root in List<Map>.from(maps)) {
      for (final key in [
        'pl.personal.chat.telegram.media_policy',
        'pl.personal.chat.telegram.media',
        'fi.mau.telegram.media',
      ]) {
        if (!root.containsKey(key)) continue;
        final value = root[key];
        if (value is! Map || value['version'] != 1)
          malformed = true;
        else {
          maps.add(value);
          if (key == 'pl.personal.chat.telegram.media_policy') {
            allowed &= value['transfer_allowed'] == true;
            if (value['transfer_allowed'] is! bool) malformed = true;
            if (value['protected_content'] == null) protected = true;
          }
        }
      }
    }
    for (final map in maps) {
      for (final key in [
        'view_once',
        'fi.mau.telegram.view_once',
        'com.beeper.view_once',
        'com.beeper.view_limited',
      ]) {
        if (!map.containsKey(key)) continue;
        if (map[key] is bool)
          limited |= map[key] == true;
        else {
          limited = true;
          malformed = true;
        }
      }
      for (final key in [
        'ttl_seconds',
        'ttl',
        'fi.mau.telegram.ttl',
        'fi.mau.telegram.ttl_seconds',
      ]) {
        if (!map.containsKey(key)) continue;
        final v = map[key];
        if (v == null && key == 'ttl_seconds') continue;
        if (v is int && v >= 0)
          limited |= v > 0;
        else {
          limited = true;
          malformed = true;
        }
      }
      if (map.containsKey('com.beeper.disappearing')) {
        final v = map['com.beeper.disappearing'];
        if (v is! Map || v['timer'] is! int || (v['timer'] as int) < 0) {
          limited = true;
          malformed = true;
        } else {
          limited |= (v['timer'] as int) > 0;
        }
      }
      for (final key in [
        'protected',
        'protected_content',
        'fi.mau.telegram.protected',
        'fi.mau.telegram.protected_content',
        'fi.mau.telegram.no_forward',
      ]) {
        if (!map.containsKey(key)) continue;
        if (map[key] == null && key == 'protected_content') {
          protected = true;
          continue;
        }
        if (map[key] is bool)
          protected |= map[key] == true;
        else {
          protected = true;
          malformed = true;
        }
      }
    }
    return RoundMediaPolicy(
      isTimeLimited: limited,
      protectedContent: protected,
      malformed: malformed,
      transferAllowed: allowed,
    );
  }
}

class RoundBridgeIdentity {
  final String accountId, roomId, stateKey, senderId;
  const RoundBridgeIdentity({
    required this.accountId,
    required this.roomId,
    required this.stateKey,
    required this.senderId,
  });
  bool get valid =>
      accountId.isNotEmpty && roomId.isNotEmpty && senderId.isNotEmpty;
  @override
  String toString() => 'RoundBridgeIdentity(redacted)';
}

/// Caller binds these fields to authenticated Matrix state, never content claims.
class RoundCapabilityEvent {
  final String accountId, roomId, stateKey, senderId;
  final Map<String, dynamic> content;
  RoundCapabilityEvent({
    required this.accountId,
    required this.roomId,
    required this.stateKey,
    required this.senderId,
    required Map<String, dynamic> content,
  }) : content = Map.unmodifiable(content);
  bool matches(RoundBridgeIdentity identity) =>
      identity.valid &&
      accountId == identity.accountId &&
      roomId == identity.roomId &&
      stateKey == identity.stateKey &&
      senderId == identity.senderId;
}

/// Extension operations must be positively declared by the same trusted source.
class TelegramMediaCapabilities {
  final Map<String, dynamic>? _content;
  final bool trusted;
  const TelegramMediaCapabilities._(this._content, this.trusted);
  factory TelegramMediaCapabilities.fromEvent({
    required RoundBridgeIdentity identity,
    RoundCapabilityEvent? event,
  }) {
    if (event == null ||
        !event.matches(identity) ||
        event.content['version'] != 1 ||
        event.content['account_id'] != identity.accountId ||
        event.content['room_id'] != identity.roomId ||
        event.content['bridge_state_key'] != identity.stateKey) {
      return const TelegramMediaCapabilities._(null, false);
    }
    return TelegramMediaCapabilities._(event.content, true);
  }
  CapabilityResult operation(String name) {
    final value = _content?[name];
    if (!trusted || value is! bool)
      return const CapabilityResult(
        CapabilityStatus.unverified,
        'Most nie potwierdził tej operacji.',
      );
    return CapabilityResult(
      value ? CapabilityStatus.available : CapabilityStatus.unavailable,
      value
          ? 'Most potwierdza tę operację.'
          : 'Most nie obsługuje tej operacji.',
    );
  }

  Map<String, dynamic>? get encodingDeclaration {
    final value = _content?['profile'];
    return value is Map ? Map<String, dynamic>.from(value) : null;
  }
}
